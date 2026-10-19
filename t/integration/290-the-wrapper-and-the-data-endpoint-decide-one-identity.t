#!/usr/bin/perl
# SM1181 S1 (T10, SM1082 C2): THE AUTH WRAPPER AND THE DATA ENDPOINT DECIDE WHO IS
# SIGNED IN BY ONE FUNCTION, AND DECIDE WHAT THEY DECIDED BEFORE IT.
#
# Two surfaces turn a request into an identity: lazysite-auth.pl (the wrapper,
# before it execs the page or the manager API) and lazysite-data.pl (which
# verifies for itself, SM410/SM1137). Each held its own copy of SM1130's rule - a
# trusted proxy's user wins, otherwise the session cookie - and the pool's front
# door (SM1181 S3) would have been a third. Lazysite::Auth::Session::request_session
# is the rule now, and both call it.
#
# THREE THINGS, for every request in the table below:
#
#   1. the identity the wrapper hands the surface it execs (read by the identity
#      reader in a stand-in surface, as the processor reads it) and the identity the
#      data endpoint hands what it calls (read the same way from the environment it
#      leaves) are the same value;
#   2. that value is what the BASE tree decided (claude/n668-plan-identity-in-process,
#      0a02d2a57): %BASE below was recorded there, with this file copied into an
#      export of that tree and run with LAZYSITE_PARITY_RECORD=1, before
#      request_session existed - so the move changed no answer;
#   3. each surface made its decision by ONE call to request_session, and acted on
#      the value it returned - a surface back on its own copy of the rule fails here
#      even while its answers still agree.
#
# A decision is { user, groups, source }: source `cookie`, `proxy`, or `anon` for no
# identity (a reader's `direct` answer is what the trust gates strip, so it is anon).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBI/DBD::SQLite not available (the data plugin needs them)';
}

my $root   = repo_root();
my $RECORD = $ENV{LAZYSITE_PARITY_RECORD} ? 1 : 0;

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $SECRET = 'c' x 64;
my $OFFICE = '198.51.100.4';    # inside the `office` list
my $OUT    = '203.0.113.9';     # outside it, and not a proxy
my $PROXY  = '10.1.2.3';        # in auth_proxy_trusted_from

my $d = site_tempdir();
my $t = $d =~ s{/site/[^/]+\z}{}r;
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nplugins:\n  - plugins/data.pl\n"
        . "auth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8\n"
        . "auth_header_user: X-Authentik-Username\nauth_header_groups: X-Authentik-Groups\n"
        . "auth_header_groups_separator: |\n" );
spit( "$d/lazysite/auth/.secret", "$SECRET\n" );
chmod 0600, "$d/lazysite/auth/.secret";
spit( "$d/lazysite/auth/users",  "alice:x\ndora:x\nrhea:x\n" );
spit( "$d/lazysite/auth/groups", "staff: alice, rhea\noffice-only: alice\n" );
spit( "$d/lazysite/auth/user-settings.json", encode_json( { dora => { disabled => 1 } } ) );
spit( "$d/lazysite/auth/revoked.json", encode_json( { not_before => { rhea => time() + 3600 } } ) );
spit( "$d/lazysite/auth/address-lists.json",
    encode_json( { office => { kind => 'allow', entries => [ { cidr => '198.51.100.0/24', note => 'HQ' } ] } } ) );
spit( "$d/lazysite/auth/groups-settings.json", encode_json( { 'office-only' => { addresses => ['office'] } } ) );

# A legacy three-field cookie (user:ts:groups), which verifies without a registry
# entry; the groups baked in are never read (SEC-2026-07 M5).
sub cookie_for {
    my ($user) = @_;
    my $payload = "$user:" . time() . ':baked';
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
}

# The stand-in surface the wrapper execs: it reads the identity as the processor
# does (the one reader, after the wrapper) and prints it.
my $stub = "$t/surface.pl";
spit( $stub, <<"PERL" );
use strict;
use warnings;
use lib '$root/lib';
use JSON::PP;
use Lazysite::Auth::Identity ();
my \$id = Lazysite::Auth::Identity::request_identity( lazysite_dir => "\$ENV{DOCUMENT_ROOT}/lazysite" );
print "Content-Type: application/json\\r\\n\\r\\n";
print JSON::PP->new->canonical->encode( \$id );
PERL

# Loaded first in each surface's process: if request_session exists, every call to
# it is recorded (the value it returned) in SPY_OUT. On the base tree it does not
# exist and nothing is recorded.
make_path("$t/spy");
spit( "$t/spy/SessionSpy.pm", <<"PERL" );
package SessionSpy;
use strict;
use warnings;
use lib '$root/lib';
use JSON::PP ();
require Lazysite::Auth::Session;
if ( defined &Lazysite::Auth::Session::request_session ) {
    no warnings 'redefine';
    my \$orig = \\&Lazysite::Auth::Session::request_session;
    *Lazysite::Auth::Session::request_session = sub {
        my \@r = \$orig->(\@_);
        open my \$fh, '>>', \$ENV{SPY_OUT} or die "spy: \$!";
        print {\$fh} JSON::PP->new->canonical->allow_nonref->encode( { value => \$r[0], why => \$r[1] } ), "\\n";
        close \$fh;
        return wantarray ? \@r : \$r[0];
    };
}
1;
PERL

# The data endpoint, run in a process of its own the way a CGI runs: its main()
# with the request's environment, then the identity read from what it leaves - the
# environment it says "the rest of the stack reads it from". generate_csrf_token is
# watched too: the ?csrf=1 answer is minted for the user the endpoint decided.
my $driver = "$t/data-driver.pl";
spit( $driver, <<"PERL" );
use strict;
use warnings;
use lib '$t/spy';
use SessionSpy;
use JSON::PP;
use Lazysite::Auth::Identity ();
my \$csrf_user = '';
{
    no warnings 'redefine';
    my \$orig = \\&Lazysite::Auth::Session::generate_csrf_token;
    *Lazysite::Auth::Session::generate_csrf_token = sub { \$csrf_user = \$_[0]; return \$orig->(\@_) };
}
do '$root/lazysite-data.pl';
die \$@ if \$@;
open my \$save, '>&', \\*STDOUT or die \$!;
close STDOUT;
my \$buf = '';
open STDOUT, '>', \\\$buf or die \$!;
main::main();
close STDOUT;
open STDOUT, '>&', \$save or die \$!;
my (\$st) = \$buf =~ /Status:\\s*(\\d+)/;
my \$id = Lazysite::Auth::Identity::request_identity( lazysite_dir => "\$ENV{DOCUMENT_ROOT}/lazysite" );
print JSON::PP->new->canonical->encode( { id => \$id, status => \$st // 0, csrf_user => \$csrf_user } );
PERL

sub decision {
    my ($id) = @_;
    return { user => '', groups => [], source => 'anon' }
        unless ref $id eq 'HASH' && length( $id->{user} // '' ) && ( $id->{source} // '' ) ne 'direct';
    return { user => $id->{user}, groups => [ @{ $id->{groups} || [] } ], source => $id->{source} };
}

sub request_env {
    my ($row) = @_;
    return (
        env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'GET',
        REMOTE_ADDR    => $row->{peer},
        ( defined $row->{cookie} ? ( HTTP_COOKIE => cookie_for( $row->{cookie} ) ) : () ),
        %{ $row->{headers} || {} },
    );
}

sub spied {
    my ($file) = @_;
    open my $fh, '<', $file or return [];
    my @v = map { decode_json($_) } grep { /\S/ } <$fh>;
    close $fh;
    unlink $file;
    return \@v;
}

sub via_wrapper {
    my ($row) = @_;
    my $spy = "$t/spy-wrapper.jsonl";
    unlink $spy;
    local %ENV = ( request_env($row), REDIRECT_URL => '/page', QUERY_STRING => '',
        LAZYSITE_PROCESSOR => $stub, SPY_OUT => $spy );
    my $out = qx(\Q$^X\E -I\Q$t/spy\E -MSessionSpy \Q$root/lazysite-auth.pl\E 2>/dev/null);
    my ($body) = $out =~ /\r?\n\r?\n(.*)\z/s;
    my $id = eval { decode_json( $body // '' ) };
    return { decision => decision($id), raw => $out, spy => spied($spy) };
}

sub via_data {
    my ($row) = @_;
    my $spy = "$t/spy-data.jsonl";
    unlink $spy;
    local %ENV = ( request_env($row), QUERY_STRING => 'csrf=1', SPY_OUT => $spy );
    my $out = qx(\Q$^X\E \Q$driver\E 2>/dev/null);
    my $r   = eval { decode_json($out) } || {};
    return { decision => decision( $r->{id} ), status => $r->{status} // 0,
        csrf_user => $r->{csrf_user} // '', raw => $out, spy => spied($spy) };
}

my %CAROL = ( HTTP_X_AUTHENTIK_USERNAME => 'carol', HTTP_X_AUTHENTIK_GROUPS => 'Staff|Other' );

my @ROWS = (
    { name => 'no cookie',                       peer => $OUT },
    { name => 'a valid member cookie',           peer => $OFFICE, cookie => 'alice' },
    { name => 'a disabled account',              peer => $OFFICE, cookie => 'dora' },
    { name => 'a removed account',               peer => $OFFICE, cookie => 'gone' },
    { name => 'a revoked session',               peer => $OFFICE, cookie => 'rhea' },
    { name => 'a session store that cannot be read', peer => $OFFICE, cookie => 'alice', broken => 'user-settings.json' },
    { name => 'a trusted proxy user, no cookie', peer => $PROXY, headers => \%CAROL },
    { name => 'a trusted proxy user and a cookie for someone else', peer => $PROXY, cookie => 'alice', headers => \%CAROL },
    { name => 'a trusted proxy peer naming nobody, and a cookie', peer => $PROXY, cookie => 'alice' },
    { name => 'a trusted proxy peer, a forged X-Remote-User, no cookie', peer => $PROXY,
        headers => { HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins' } },
    { name => 'an untrusted peer, a forged X-Remote-User, no cookie', peer => $OUT,
        headers => { HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins' } },
    { name => 'an untrusted peer, a forged X-Remote-User, and a member cookie', peer => $OFFICE, cookie => 'alice',
        headers => { HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins' } },
    { name => 'an untrusted peer sending the proxy\'s headers', peer => $OUT, headers => \%CAROL },
    { name => 'a group the address is refused for', peer => $OUT, cookie => 'alice' },
);

# Recorded on the base tree (0a02d2a57) with LAZYSITE_PARITY_RECORD=1; see the header.
my %ANON = ( user => '', groups => [], source => 'anon' );
my %BASE = (
    'no cookie'                => {%ANON},
    'a valid member cookie'    => { user => 'alice', groups => [ 'staff', 'office-only' ], source => 'cookie' },
    'a disabled account'       => {%ANON},
    'a removed account'        => {%ANON},
    'a revoked session'        => {%ANON},
    'a session store that cannot be read' => {%ANON},
    'a trusted proxy user, no cookie' => { user => 'carol', groups => [ 'staff', 'other' ], source => 'proxy' },
    'a trusted proxy user and a cookie for someone else' =>
        { user => 'carol', groups => [ 'staff', 'other' ], source => 'proxy' },
    'a trusted proxy peer naming nobody, and a cookie' => { user => 'alice', groups => ['staff'], source => 'cookie' },
    'a trusted proxy peer, a forged X-Remote-User, no cookie' => {%ANON},
    'an untrusted peer, a forged X-Remote-User, no cookie'    => {%ANON},
    'an untrusted peer, a forged X-Remote-User, and a member cookie' =>
        { user => 'alice', groups => [ 'staff', 'office-only' ], source => 'cookie' },
    'an untrusted peer sending the proxy\'s headers' => {%ANON},
    'a group the address is refused for' => { user => 'alice', groups => ['staff'], source => 'cookie' },
);

my %recorded;
for my $row (@ROWS) {
    my $broken = $row->{broken} && "$d/lazysite/auth/$row->{broken}";
    my $kept;
    if ($broken) {
        open my $fh, '<', $broken or die $!;
        $kept = do { local $/; <$fh> };
        close $fh;
        spit( $broken, '{ not json' );
    }
    my $w    = via_wrapper($row);
    my $data = via_data($row);
    spit( $broken, $kept ) if $broken;

    if ($RECORD) {
        $recorded{ $row->{name} } = $w->{decision};
        is_deeply( $data->{decision}, $w->{decision}, "$row->{name}: (recording) the two surfaces agree" );
        next;
    }

    subtest $row->{name} => sub {
        is_deeply( $w->{decision}, $data->{decision}, 'the wrapper and the data endpoint decide the same identity' )
            or diag( explain { wrapper => $w->{decision}, data => $data->{decision} } );
        is_deeply( $w->{decision}, $BASE{ $row->{name} }, 'and it is what the base tree decided' )
            or diag( explain { now => $w->{decision}, base => $BASE{ $row->{name} } } );
        is( $data->{csrf_user}, $data->{decision}{user},
            'the data endpoint\'s CSRF token is minted for the user it decided (none for nobody)' );
        is( $data->{status}, ( length $data->{decision}{user} ? 200 : 403 ), 'and it answered ?csrf=1 accordingly' );

        for my $s ( [ wrapper => $w ], [ 'data endpoint' => $data ] ) {
            my ( $who, $r ) = @$s;
            is( scalar @{ $r->{spy} }, 1, "the $who decided by one call to request_session" )
                or next;
            is_deeply( decision( $r->{spy}[0]{value} ), $r->{decision},
                "and the $who acted on the value request_session returned" );
        }
    };
}

if ($RECORD) {
    my $js = JSON::PP->new->canonical;
    diag( "    '$_' => " . $js->encode( $recorded{$_} ) . ',' ) for map { $_->{name} } @ROWS;
}

done_testing();

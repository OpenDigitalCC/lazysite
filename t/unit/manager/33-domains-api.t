#!/usr/bin/perl
# SM154 (P2): the domain-* control-API actions are manage_config-gated and
# POST-only. An operator (or a manage_config token/orchestrator) registers a
# domain; a content-only editor cannot; a GET is refused (CSRF).
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub post {
    my ( $d, $user, $groups, $qs, $obj ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user,       HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN  => csrf($user), body => encode_json( $obj // {} ) );
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Agency\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users', 'manage_config' );
uapi( $d, { action => 'add', username => 'ed', password => 'y' } );
grant_caps( $d, 'ed', 'manage_content' );

# --- operator (manage_config) registers a domain ----------------------------
{
    my $r = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'clienta.com', content_root => 'sites/clienta', seed => 1 } );
    ok( $r->{ok}, 'operator registers a domain via the API' ) or diag encode_json($r);
    like( slurp("$d/lazysite/lazysite.conf"), qr/^alias_hosts: clienta\.com/m,
        'the API write reached the conf' );
    ok( -d "$d/sites/clienta", 'the API provisioned the content root' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/domain-add/,
        'domain-add is recorded in the audit trail' );
}

# --- content editor (no manage_config) is forbidden -------------------------
{
    my $r = post( $d, 'ed', 'role-ed', 'action=domain-add',
        { host => 'clientb.com', content_root => 'sites/clientb' } );
    ok( !$r->{ok}, 'content editor cannot register a domain' );
    is( $r->{kind}, 'forbidden', 'domain-add is forbidden for a non-config editor' );
    unlike( slurp("$d/lazysite/lazysite.conf"), qr/clientb/, 'no conf change from the denied call' );
}

# --- domain-add over GET is refused (must be POST) --------------------------
{
    my $r = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-add&host=clientc.com',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    ok( !$r->{ok}, 'domain-add over GET is refused' );
}

# --- SM155: domain-alias-add is manage_config-gated -------------------------
{
    my $r = post( $d, 'op', 'role-op', 'action=domain-alias-add',
        { host => 'www.clienta.com', of => 'clienta.com' } );
    ok( $r->{ok}, 'operator adds an alias host' ) or diag encode_json($r);
    like( slurp("$d/lazysite/lazysite.conf"),
        qr/^alias\.www\.clienta\.com\.content_root: sites\/clienta$/m,
        'the alias shares the canonical content root' );

    my $e = post( $d, 'ed', 'role-ed', 'action=domain-alias-add',
        { host => 'evil.com', of => 'clienta.com' } );
    is( $e->{kind}, 'forbidden', 'content editor cannot add an alias' );
}

# --- SM155: domain-preview renders a domain under its Host (pre-DNS) ---------
{
    require Cwd;
    my $processor = Cwd::abs_path("$root/lazysite-processor.pl");
    mkdir "$d/sites";
    mkdir "$d/sites/clienta";
    open my $ix, '>', "$d/sites/clienta/index.md" or die $!;
    print $ix "---\ntitle: Client A\n---\n\nPREVIEW-OF-CLIENTA\n";
    close $ix;
    my $r = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-preview&host=clienta.com',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        LAZYSITE_PROCESSOR => $processor );
    ok( $r->{ok}, 'operator previews a registered domain' ) or diag encode_json($r);
    like( $r->{html}, qr/PREVIEW-OF-CLIENTA/, 'preview renders the domain content root' );

    my $ef = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-preview&host=clienta.com',
        HTTP_X_REMOTE_USER => 'ed', HTTP_X_REMOTE_GROUPS => 'role-ed' );
    ok( !$ef->{ok}, 'content editor cannot preview a domain (manage_config)' );
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; <$fh> }

done_testing();

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
grant_caps( $d, 'op', 'manage_users', 'manage_domains' );
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
    like( slurp("$d/lazysite/logs/audit.log"), qr/domain-add \| clienta\.com \|/,
        'domain-add is audited with the HOST as its target (not a bare /)' );
}

# --- a host with no content_root serves the DEFAULT site --------------------
# content_root is optional: an empty one registers the host but writes no
# content_root line, so it inherits the base (the default site).
{
    my $r = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'vanity.example', content_root => '' } );
    ok( $r->{ok}, 'a domain with no content_root registers (serves the default)' )
        or diag encode_json($r);
    like( slurp("$d/lazysite/lazysite.conf"), qr/^alias_hosts:.*vanity\.example/m,
        'the host is registered in alias_hosts' );
    unlike( slurp("$d/lazysite/lazysite.conf"), qr/^alias\.vanity\.example\.content_root:/m,
        'no content_root line is written - the host inherits the default site' );
}

# --- a reserved (system) content_root is refused ----------------------------
{
    my $r = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'bad.example', content_root => 'lazysite/auth' } );
    ok( !$r->{ok}, 'a content_root inside the reserved lazysite/ area is refused' );
    is( $r->{kind}, 'invalid', 'reserved content_root is an invalid request' );
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
    like( slurp("$d/lazysite/logs/audit.log"), qr/domain-alias-add \| www\.clienta\.com \|/,
        'domain-alias-add is audited with the alias host as its target' );

    my $e = post( $d, 'ed', 'role-ed', 'action=domain-alias-add',
        { host => 'evil.com', of => 'clienta.com' } );
    is( $e->{kind}, 'forbidden', 'content editor cannot add an alias' );
}

# --- SM155: an alias mirrors the canonical's OWN presentation (title) --------
# A sub-domain with its own site_name, then aliased: the alias must carry the
# sub-domain's site_name, not fall back to the DEFAULT host's (the reported bug).
{
    post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'shop.clienta.com', content_root => 'sites/shop',
            site_name => 'Client A Shop', seed => 1 } );
    my $r = post( $d, 'op', 'role-op', 'action=domain-alias-add',
        { host => 'www.shop.clienta.com', of => 'shop.clienta.com' } );
    ok( $r->{ok}, 'alias of a sub-domain is added' ) or diag encode_json($r);
    like( slurp("$d/lazysite/lazysite.conf"),
        qr/^alias\.www\.shop\.clienta\.com\.site_name: Client A Shop$/m,
        'the alias carries the sub-domain site_name (title), not the default host' );
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

    # REGRESSION: in the wrapped deployment (Apache/Hestia + dev server) the
    # auth wrapper sets LAZYSITE_PROCESSOR to the ORIGINALLY requested CGI -
    # i.e. THIS manager-api - not the processor. Trusting it re-entered
    # manager-api with auth stripped and the preview showed
    # {"error":"Authentication required"} instead of the page. The preview must
    # resolve the processor by name in that cgi-bin, so it still renders.
    my $wrapped = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-preview&host=clienta.com',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        LAZYSITE_PROCESSOR => $mapi );    # wrapper points back at manager-api
    ok( $wrapped->{ok}, 'preview works when the wrapper points LAZYSITE_PROCESSOR at manager-api' )
        or diag encode_json($wrapped);
    like( $wrapped->{html}, qr/PREVIEW-OF-CLIENTA/,
        'wrapped preview renders the processor, not the manager-api auth error' );
    unlike( $wrapped->{html} // '', qr/Authentication required/,
        'wrapped preview is not the re-entered auth error' );
}

# --- SM156: domain-check is manage_config-gated + registered-only -----------
# Uses a .invalid host (RFC 6761: guaranteed never to resolve), so the real
# DNS/TLS/HTTP probe fast-fails offline instead of hanging or hitting the net.
{
    post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'unconfigured.invalid', content_root => 'sites/uc' } );

    my $r = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-check&host=unconfigured.invalid',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    ok( $r->{ok}, 'operator runs a domain check' ) or diag encode_json($r);
    is( scalar @{ $r->{checks} || [] }, 4, 'four checks are reported' );
    is( $r->{checks}[0]{id}, 'dns', 'first check is DNS' );
    is( $r->{all_pass}, 0, 'an unconfigured (.invalid) domain is not ready' );

    my $ef = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-check&host=unconfigured.invalid',
        HTTP_X_REMOTE_USER => 'ed', HTTP_X_REMOTE_GROUPS => 'role-ed' );
    ok( !$ef->{ok}, 'content editor cannot run a domain check (manage_config)' );

    my $un = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-check&host=stranger.invalid',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    ok( !$un->{ok}, 'an unregistered host is refused (no SSRF to arbitrary targets)' );
    like( $un->{error}, qr/Not a registered domain/, 'refusal names the reason' );
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; <$fh> }

done_testing();

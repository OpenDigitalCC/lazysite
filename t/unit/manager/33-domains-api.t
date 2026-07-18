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
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
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

# The alias-as-clone concept was retired: an "alias" was just a domain created as
# a copy of another (same content root + presentation), which is now the "Copy
# settings from" pre-fill on Add domain - a second domain-add, no separate action.
# Two domains sharing a content_root still both serve it (that is the SM110
# alias_hosts mechanism, exercised in t/integration/16-domain-aliases.t).

# --- SM155: domain-preview renders a domain under its Host (pre-DNS) ---------
{
    require Cwd;
    my $processor = Cwd::abs_path("$root/lazysite-processor.pl");
    mkdir "$d/sites";
    mkdir "$d/sites/clienta";
    # Include non-ASCII content (French + Thai) to guard the UTF-8 round-trip:
    # the preview captures the processor's raw bytes and must decode them before
    # the JSON layer re-encodes, or they double-encode into mojibake.
    open my $ix, '>:encoding(UTF-8)', "$d/sites/clienta/index.md" or die $!;
    print $ix "---\ntitle: Client A\n---\n\nPREVIEW-OF-CLIENTA h\x{e9}bergeurs \x{0e2a}\x{0e33}\n";
    close $ix;
    my $r = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=domain-preview&host=clienta.com',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        LAZYSITE_PROCESSOR => $processor );
    ok( $r->{ok}, 'operator previews a registered domain' ) or diag encode_json($r);
    like( $r->{html}, qr/PREVIEW-OF-CLIENTA/, 'preview renders the domain content root' );
    like( $r->{html}, qr/h\x{e9}bergeurs/,
        'preview preserves UTF-8 (French) - no double-encoding' );
    unlike( $r->{html}, qr/h\x{c3}\x{a9}bergeurs/,
        'preview does not mojibake the UTF-8 (no e-acute -> A-tilde-copy)' );

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

# --- SM165 access keys surface in domains-list (feeds the tick-list pickers) --
# The Domains edit form picks allowed_groups / locked_users from tick-lists, so
# domains-list must report the domain's current values to pre-tick them.
{
    post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'clienta.com', key => 'allowed_groups', value => 'clienta-editors' } );
    post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'clienta.com', key => 'locked_users', value => 'alice,bob' } );
    my $r = mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=domains-list',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    ok( ( grep { $_ eq 'allowed_groups' } @{ $r->{keys} } ),
        'domains-list advertises allowed_groups' );
    ok( ( grep { $_ eq 'locked_users' } @{ $r->{keys} } ),
        'domains-list advertises locked_users' );
    my ($ca) = grep { $_->{host} eq 'clienta.com' } @{ $r->{domains} };
    is( $ca->{allowed_groups}, 'clienta-editors', 'clienta.com surfaces its allowed_groups' );
    # domain_set normalises the list separator to ', '; the tick-list splits on
    # comma and trims, so either spelling round-trips.
    is( $ca->{locked_users}, 'alice, bob', 'clienta.com surfaces its locked_users' );
}

# --- SM179: the language keys are settable via domain-set (not conf-only) -----
# So an operator (or an agent with manage_domains) can configure a language set
# through the API / CLI / Domains page, not just by hand-editing lazysite.conf.
{
    my $ok = post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'clienta.com', key => 'lang', value => 'fr' } );
    ok( $ok->{ok}, 'domain-set accepts lang' ) or diag encode_json($ok);
    post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'clienta.com', key => 'lang_group', value => 'providers' } );

    # A bad language tag is rejected (it lands in <html lang> / names an i18n file).
    my $bad = post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'clienta.com', key => 'lang', value => 'not a lang!' } );
    ok( !$bad->{ok}, 'domain-set rejects an invalid language tag' );

    my $r = mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=domains-list',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    my ($ca) = grep { $_->{host} eq 'clienta.com' } @{ $r->{domains} };
    is( $ca->{lang},       'fr',        'domains-list surfaces lang' );
    is( $ca->{lang_group}, 'providers', 'domains-list surfaces lang_group' );

    # The language keys can also be set at CREATION (Add domain form).
    my $add = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'de.clienta.com', content_root => 'sites/de',
            lang => 'de', lang_group => 'providers' } );
    ok( $add->{ok}, 'domain-add accepts lang / lang_group at creation' )
        or diag encode_json($add);
    my $bad = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'x.clienta.com', lang => 'bad lang' } );
    ok( !$bad->{ok}, 'domain-add rejects an invalid language tag' );

    # SEC (F6.11): a CR/LF in any value must be refused, or it could smuggle a
    # second conf directive on the next line.
    my $crlf = post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'y.clienta.com',
            site_name => "Y\ncontent_root: ../lazysite/auth" } );
    ok( !$crlf->{ok}, 'domain-add rejects a CR/LF-bearing value (no conf-line injection)' );
    unlike( slurp("$d/lazysite/lazysite.conf"), qr{content_root: \.\./lazysite/auth},
        'the smuggled directive did not reach the conf' );
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; <$fh> }

done_testing();

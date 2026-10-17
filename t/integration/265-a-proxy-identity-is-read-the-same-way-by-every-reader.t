#!/usr/bin/perl
# SM1131 / SM1132 / SM1133 (SM1128 phase 1, ruled 2026-10-17 "rulings as
# proposed"): EVERY READER READS THE PROXY THE SAME WAY.
#
# united/platform puts every service behind Authentik. Its groups header is
# `X-Authentik-Groups: Site Editors|Members` - pipe-separated, and "Site Editors"
# is not a lazysite group name. Before this, the configured header names reached
# the page gate and nothing else (the manager, the manager API, the ACL code read
# the fixed X-Remote-* names), the page gate split on commas and the manager on
# commas or whitespace, and no directory name could be a group.
#
# The same request, through the real CGIs, with
#   auth_header_groups: X-Authentik-Groups   auth_header_groups_separator: |
# and a page gated on `site-editors`:
#
#   - the PAGE GATE serves it          (SM1131 + SM1132 + SM1133 normalising)
#   - a per-file ACL READ serves it    (the ACL code's own reader)
#   - the MANAGER ENTRY lets it in     (and the manager API accepts its `ui`)
#   - a mapped name (auth_group_map) opens a page gated on the lazysite name
#   - the same headers WITHOUT auth_proxy_trusted open nothing
#   - nor WITH it, from a peer outside auth_proxy_trusted_from (SM1129)
#   - the cookie path is unchanged, and now works with renamed proxy headers too
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor run_script site_tempdir);

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    my $conf = "site_name: T\nmanager: enabled\n"
        . "auth_header_user: X-Authentik-Username\n"
        . "auth_header_groups: X-Authentik-Groups\n"
        . "auth_header_groups_separator: |\n"
        . "auth_group_map: Platform Admins = operators\n";
    # SM1129: the flag names a proxy and auth_proxy_trusted_from names which peer;
    # the CGIs run here from loopback (TestHelper sets REMOTE_ADDR for such a site).
    $conf .= "auth_proxy_trusted: true\nauth_proxy_trusted_from: " . ( $o{from} // '127.0.0.1' ) . "\n"
        unless $o{untrusted};
    spit( "$d/lazysite/lazysite.conf", $conf );
    spit( "$d/index.md", "---\ntitle: Home\n---\nHome.\n" );
    spit( "$d/editors.md",
        "---\ntitle: Editors\nauth_groups: [site-editors]\n---\nSECRET-EDITORS\n" );
    spit( "$d/ops.md",
        "---\ntitle: Ops\nauth_groups: [operators]\n---\nSECRET-OPS\n" );
    spit( "$d/private/brief.html", '<h1>acl-private</h1>' );
    spit( "$d/lazysite/auth/acls.json", encode_json( { 'private/brief.html' => { read => ['@site-editors'] } } ) );
    # site-editors may use the manager; it is a directory group, so no local
    # account and no local membership exists for it. SM1135: a group a proxy names
    # grants a capability only when the operator marked it, so it is marked here
    # (t/integration/271 holds the unmarked half).
    spit( "$d/lazysite/auth/groups-settings.json",
        encode_json( { 'site-editors' => { label => 'x', ui => 1, manage_content => 1, directory_grants => 1 } } ) );
    spit( "$d/lazysite/auth/groups", "local: nobody\n" );
    return $d;
}

my %AK = ( HTTP_X_AUTHENTIK_USERNAME => 'sam', HTTP_X_AUTHENTIK_GROUPS => 'Site Editors|Members' );
my %CLEAR = map { $_ => undef } qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED);

sub status { return ( $_[0] =~ /^Status:\s*(\d+)/m )[0] // 200 }

subtest 'the page gate: `Site Editors|Members` opens a page gated on site-editors' => sub {
    my $d   = site();
    my $out = run_processor( $d, '/editors', %CLEAR, %AK );
    is( status($out), 200, 'served' ) or diag( substr $out, 0, 300 );
    like( $out, qr/SECRET-EDITORS/, 'with the body' );

    my $no = run_processor( $d, '/editors', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'Members|Other' );
    is( status($no), 403, 'a signed-in non-member is refused' );
    unlike( $no, qr/SECRET/, 'and gets none of it' );

    # The old reading: the whole header as ONE group name, or split on spaces.
    my $space = run_processor( $d, '/editors', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'Site|Editors' );
    is( status($space), 403, 'two groups Site and Editors are not the group Site Editors' );
};

subtest 'a per-file ACL read: @site-editors is satisfied by the directory group' => sub {
    my $d  = site();
    my $ok = run_processor( $d, '/private/brief', %CLEAR, %AK );
    like( $ok, qr/acl-private/, 'the file is served' ) or diag( substr $ok, 0, 300 );
    my $no = run_processor( $d, '/private/brief', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'Members' );
    unlike( $no, qr/acl-private/, 'a non-member is not served' );
};

subtest 'the manager entry: a directory group holding `ui` is let in' => sub {
    my $d  = site();
    my $in = run_processor( $d, '/manager/', %CLEAR, %AK );
    unlike( $in, qr{^Location: /login}m, 'not sent to sign in' ) or diag( substr $in, 0, 300 );
    unlike( $in, qr/Manager access not permitted/, 'and not told the account lacks the manager' );
    my $out = run_processor( $d, '/manager/', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'Members' );
    like( $out, qr/Manager access not permitted|Status: 302/,
        'a signed-in account in no ui group is refused' );
};

subtest 'the manager API takes the same identity' => sub {
    my $d = site();
    my $call = sub {
        my (%env) = @_;
        my $out = run_script( 'lazysite-manager-api.pl',
            env => { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=pages&plugins=0',
                REMOTE_ADDR => '127.0.0.1', %CLEAR, %env } );
        my ($st) = $out =~ /^Status:\s*(\d+)/m;
        $out =~ s/\A.*?\r?\n\r?\n//s;
        return ( $st // 200, eval { decode_json($out) } || {} );
    };
    my ( $st, $body ) = $call->(%AK);
    # Not vacuous: an identity the gate stripped would also not be "refused for
    # lacking manager access" - it would be refused for having no identity.
    unlike( $body->{error} // '', qr/Authentication required/i, 'the proxy user is recognised' );
    unlike( $body->{error} // '', qr/manager access/i, 'the directory group holding ui is not refused for lacking manager access' );
    ( $st, $body ) = $call->( %AK, HTTP_X_AUTHENTIK_GROUPS => 'Members' );
    like( $body->{error} // '', qr/manager access/i, 'a signed-in account in no ui group is refused' );
};

subtest 'the ACL code (Auth::Acl::_is_operator) reads the same groups' => sub {
    my $d = site();
    # The operator group is a directory group too: the `manager` flag on its record.
    spit( "$d/lazysite/auth/groups-settings.json",
        encode_json( { 'site-editors' => { label => 'x', ui => 1, manager => 1, directory_grants => 1 },
                'other' => { label => 'y', ui => 1, manager => 1 } } ) );
    require Lazysite::Auth::Acl;
    no warnings 'once';
    local $Lazysite::Auth::Acl::DOCROOT    = $d;
    local $Lazysite::Auth::Acl::auth_user  = 'sam';
    local $Lazysite::Auth::Acl::token_auth = 0;
    local %ENV = %ENV;
    delete @ENV{ keys %CLEAR };
    @ENV{ keys %AK } = values %AK;
    $ENV{REMOTE_ADDR} = '127.0.0.1';    # SM1129: the listed proxy peer
    ok( Lazysite::Auth::Acl::_is_operator(), '`Site Editors|Members` makes a proxy account an operator via site-editors' );
    $ENV{HTTP_X_AUTHENTIK_GROUPS} = 'Members';
    ok( !Lazysite::Auth::Acl::_is_operator(), 'and `Members` alone does not' );
};

subtest 'SM1133: a mapped name opens a page gated on the lazysite name' => sub {
    my $d  = site();
    my $ok = run_processor( $d, '/ops', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'platform  ADMINS|Members' );
    is( status($ok), 200, 'Platform Admins = operators: served' ) or diag( substr $ok, 0, 300 );
    like( $ok, qr/SECRET-OPS/, 'with the body' );
    my $no = run_processor( $d, '/ops', %CLEAR, %AK, HTTP_X_AUTHENTIK_GROUPS => 'Operators Club' );
    is( status($no), 403, 'an unmapped name that normalises to something else does not match' );
};

subtest 'without auth_proxy_trusted the same headers open nothing' => sub {
    my $d = site( untrusted => 1 );
    for my $uri ( '/editors', '/private/brief' ) {
        my $out = run_processor( $d, $uri, %CLEAR, %AK );
        unlike( $out, qr/SECRET|acl-private/, "$uri: not served" );
    }
    my $m = run_processor( $d, '/manager/', %CLEAR, %AK );
    like( $m, qr{Status: 302}, 'the manager entry redirects to sign in' );
};

# SM1129 + SM1131: the reader asks proxy_identity, so the flag alone is not a
# trusted proxy for any reader - a peer outside auth_proxy_trusted_from is nobody
# on the page gate, the ACL read and the manager entry alike.
subtest 'with the flag on, a peer outside auth_proxy_trusted_from opens nothing' => sub {
    my $d = site( from => '10.9.9.9' );
    for my $uri ( '/editors', '/private/brief' ) {
        my $out = run_processor( $d, $uri, %CLEAR, %AK, REMOTE_ADDR => '127.0.0.1' );
        unlike( $out, qr/SECRET|acl-private/, "$uri: not served" );
    }
    my $m = run_processor( $d, '/manager/', %CLEAR, %AK, REMOTE_ADDR => '127.0.0.1' );
    like( $m, qr{Status: 302}, 'the manager entry redirects to sign in' );

    # The manager API's gate strips only the FIXED names, so a renamed header from
    # an unlisted peer reaches the reader there: the reader's own ask of
    # proxy_identity is all that stands between it and an identity.
    my $out = run_script( 'lazysite-manager-api.pl',
        env => { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=pages&plugins=0',
            REMOTE_ADDR => '127.0.0.1', %CLEAR, %AK } );
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $body = eval { decode_json($out) } || {};
    like( $body->{error} // '', qr/Authentication required/i,
        'the manager API: the renamed headers from an unlisted peer are nobody' )
        or diag( substr $out, 0, 300 );
};

subtest 'the cookie path is the fixed names, and works whatever the proxy is called' => sub {
    my $d = site();
    my $out = run_processor( $d, '/editors', %CLEAR,
        LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => 'rita', HTTP_X_REMOTE_GROUPS => 'site-editors,members' );
    is( status($out), 200, 'a wrapper-vouched session opens the gate with the proxy names renamed' )
        or diag( substr $out, 0, 300 );
};

done_testing();

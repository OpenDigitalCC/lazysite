#!/usr/bin/perl
# SM1135 (SM1128 phase 1, P1-6; ruled 2026-10-17 R1: "page and file access by
# default; capabilities only for groups the operator marks"): A GROUP A TRUSTED
# PROXY NAMES GRANTS A CAPABILITY ONLY IF THE OPERATOR MARKED IT.
#
# Behind an identity provider the directory decides who is in `site-editors`.
# A lazysite group that happens to carry that name and holds `ui` and
# `manage_content` must not hand the manager to the whole directory group unless
# the operator said so. The gate for that is `directory_grants: true` on the
# group's record (groups-settings.json), set on the Groups page or by the users
# tool, by the operator only.
#
# Every capability gate asks the one rule (Auth::Settings::request_cap_groups).
# This drives them through the real CGIs, with the proxy headers Authentik sends:
#
#   - a MARKED group grants `ui` (the /manager entry, the manager API) AND a
#     capability (manage_content: briefs-list answers, which it asks of the
#     account's capabilities - a proxy user has no local account)
#   - an UNMARKED group of the same name gives PAGE access (an auth_groups page)
#     and nothing in the manager
#   - an operator group (the `manager` flag) unmarked is NOT operator; marked is
#   - the COOKIE path is unchanged: the same unmarked group, vouched by the
#     wrapper, still opens the manager
#   - a manage_users holder cannot set the mark; the operator can; the audit
#     names it
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(run_processor run_script site_tempdir repo_root);
use ManagerSession ();

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf",
        "site_name: T\nmanager: enabled\n"
            . "auth_header_user: X-Authentik-Username\n"
            . "auth_header_groups: X-Authentik-Groups\n"
            . "auth_header_groups_separator: |\n"
            . "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n" );
    spit( "$d/index.md",   "---\ntitle: Home\n---\nHome.\n" );
    spit( "$d/editors.md", "---\ntitle: Editors\nauth_groups: [site-editors]\n---\nSECRET-EDITORS\n" );
    my %rec = (
        'site-editors' => { label => 'x', ui => 1, manage_content => 1, ( $o{marked} ? ( directory_grants => 1 ) : () ) },
        ( $o{groups} ? %{ $o{groups} } : () ),
    );
    spit( "$d/lazysite/auth/groups-settings.json", encode_json( \%rec ) );
    spit( "$d/lazysite/auth/groups", "local: nobody\n" );
    return $d;
}

my %AK    = ( HTTP_X_AUTHENTIK_USERNAME => 'sam', HTTP_X_AUTHENTIK_GROUPS => 'Site Editors|Members' );
my %CLEAR = map { $_ => undef } qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED);

sub status { return ( $_[0] =~ /^Status:\s*(\d+)/m )[0] // 200 }

# The manager API as the proxy's user: { status, body }.
sub api {
    my ( $d, $action, %env ) = @_;
    my $out = run_script( 'lazysite-manager-api.pl',
        env => { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => "action=$action&plugins=0",
            REMOTE_ADDR => '127.0.0.1', %CLEAR, %env } );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return ( $st // 200, eval { decode_json($out) } || {} );
}

subtest 'a MARKED group grants ui and a capability' => sub {
    my $d  = site( marked => 1 );
    my $in = run_processor( $d, '/manager/', %CLEAR, %AK );
    unlike( $in, qr{^Location: /login}m, 'the manager entry lets it in' ) or diag( substr $in, 0, 300 );
    unlike( $in, qr/Manager access not permitted/, 'and does not call the account unpermitted' );

    my ( $st, $b ) = api( $d, 'pages', %AK );
    unlike( $b->{error} // '', qr/manager access|Authentication required/i, 'the manager API accepts its ui' )
        or diag( explain $b );

    # briefs-list asks the ACCOUNT'S capabilities (manage_content|manage_briefs);
    # sam has no local account, so only the marked group can answer yes.
    ( $st, $b ) = api( $d, 'briefs-list', %AK );
    unlike( $b->{error} // '', qr/requires the|permission|manager access/i,
        'and a capability the group holds (manage_content) is held' )
        or diag( explain $b );
};

subtest 'an UNMARKED group of the same name gives page access and no manager access' => sub {
    my $d   = site();
    my $out = run_processor( $d, '/editors', %CLEAR, %AK );
    is( status($out), 200, 'the page gated on site-editors is served' ) or diag( substr $out, 0, 300 );
    like( $out, qr/SECRET-EDITORS/, 'with its body' );

    my $m = run_processor( $d, '/manager/', %CLEAR, %AK );
    like( $m, qr/Manager access not permitted|Status: 302/, 'the manager entry refuses' );

    my ( $st, $b ) = api( $d, 'briefs-list', %AK );
    like( $b->{error} // '', qr/manager access/i, 'the manager API refuses it for lacking ui' )
        or diag( explain $b );
};

subtest 'the operator group: unmarked is not operator, marked is' => sub {
    my %ops = ( ops => { label => 'ops', manager => 1 } );
    my %OP  = ( HTTP_X_AUTHENTIK_USERNAME => 'olga', HTTP_X_AUTHENTIK_GROUPS => 'Ops' );

    # The operator bypasses the capability gate, so a request that holds no
    # capability of its own is let through only by being the operator.
    my $d = site( groups => \%ops );
    my ( $st, $b ) = api( $d, 'briefs-list', %OP );
    like( $b->{error} // '', qr/manager access/i, 'unmarked: refused as a non-operator with no ui' )
        or diag( explain $b );

    require Lazysite::Auth::Acl;
    no warnings 'once';
    local $Lazysite::Auth::Acl::DOCROOT    = $d;
    local $Lazysite::Auth::Acl::auth_user  = 'olga';
    local $Lazysite::Auth::Acl::token_auth = 0;
    local %ENV = %ENV;
    delete @ENV{ keys %CLEAR };
    @ENV{ keys %OP } = values %OP;
    $ENV{REMOTE_ADDR} = '127.0.0.1';
    ok( !Lazysite::Auth::Acl::_is_operator(), 'unmarked: the ACL code does not call it operator' );

    my $d2 = site( groups => { ops => { label => 'ops', manager => 1, directory_grants => 1 } } );
    ( $st, $b ) = api( $d2, 'briefs-list', %OP );
    unlike( $b->{error} // '', qr/manager access|requires the|permission/i, 'marked: the operator passes the gate' )
        or diag( explain $b );
    local $Lazysite::Auth::Acl::DOCROOT = $d2;
    ok( Lazysite::Auth::Acl::_is_operator(), 'marked: the ACL code calls it operator' );
};

subtest 'the cookie path is unchanged: the same unmarked group, vouched by the wrapper' => sub {
    my $d = site();
    my ( $st, $b ) = api( $d, 'briefs-list',
        LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => 'rita', HTTP_X_REMOTE_GROUPS => 'site-editors' );
    unlike( $b->{error} // '', qr/manager access|Authentication required/i,
        'a session in site-editors holds ui with no mark' ) or diag( explain $b );
    my $m = run_processor( $d, '/manager/', %CLEAR,
        LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => 'rita', HTTP_X_REMOTE_GROUPS => 'site-editors' );
    unlike( $m, qr/Manager access not permitted/, 'and the manager entry lets it in' );
};

subtest 'the mark is the operator\'s: a manage_users holder cannot set it' => sub {
    my $s = ManagerSession::new_site( root => repo_root() );
    my $d = $s->docroot;
    $s->users( 'setup-sysop', '--user', 'boss', 'pw123456789-long-enough' );
    $s->add_user('um');
    $s->users( 'group-add', 'um', 'user-managers' );
    $s->users( 'group-set', 'staff', 'manage_content', 'on' );

    my $set = sub {
        my ( $who, $v ) = @_;
        return $s->call( $who, 'users', groups => 1, query => 'action=users',
            body => { action => 'group-settings-set', group => 'staff', key => 'directory_grants', value => $v } );
    };
    my $marked = sub {
        my $gs = eval { decode_json( slurp("$d/lazysite/auth/groups-settings.json") ) } || {};
        return $gs->{staff}{directory_grants} ? 1 : 0;
    };

    my $r = $set->( 'um', 'on' );
    ok( !$r->{ok}, 'a manage_users holder is refused' ) or diag( explain $r );
    like( $r->{error} // '', qr/Only a sysop/, 'with the reason' );
    is( $marked->(), 0, 'and the group is not marked' );

    $r = $set->( 'boss', 'on' );
    ok( $r->{ok}, 'the operator sets it' ) or diag( explain $r );
    is( $marked->(), 1, 'and the group record carries it' );

    my $view = $s->call( 'boss', 'users', groups => 1, query => 'action=users', body => { action => 'group-settings-get' } );
    ok( $view->{groups}{staff}{directory_grants}, 'the Groups view serves it' ) or diag( explain $view );
    ok( $view->{viewer_operator}, 'and tells the page the viewer is the operator' );
    $view = $s->call( 'um', 'users', groups => 1, query => 'action=users', body => { action => 'group-settings-get' } );
    ok( !$view->{viewer_operator}, 'and not for a manage_users holder, so the tick is not offered' ) or diag( explain $view );

    my $audit = slurp("$d/lazysite/logs/audit.log");
    like( $audit, qr/directory_grants=on/, 'the change is audited' );

    $r = $set->( 'boss', 'off' );
    ok( $r->{ok}, 'the operator clears it' );
    is( $marked->(), 0, 'and the mark is off' );
};

done_testing();

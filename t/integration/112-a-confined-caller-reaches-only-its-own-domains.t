#!/usr/bin/perl
# SM976: a domain-confined caller reaches only its own domains, on every surface;
# the unconfined operator reaches all of them (ruled 2026-10-09, "One rule, fix
# all").
#
# A token scoped to one domain added a domain at any content root, aliased and
# removed any domain; MCP domain_set wrote another domain's access groups
# without manage_users; a cookie manager scoped to one domain built, downloaded
# and deleted another domain's site package; and the navigation actions on all
# three surfaces read and replaced any domain's nav. The probe was
# tmp/q15b-reach-probe.pl. This file is that probe as assertions: every
# action that names a host or a content root, on the control API, MCP and
# WebDAV, for each kind of caller, against its own domain, another domain, a
# domain serving the primary's content, the primary, and a host the instance
# does not serve.
#
# Callers. op: the cookie operator (manage_users). cks/cku: cookie managers
# without manage_users, scoped to sites/mine / bound to no domain. tks/tku:
# tokens, scoped / unscoped. mcs/mcu/mcm: MCP grants, scoped / unscoped / scoped
# with manage_users. dvs/dvu: WebDAV accounts, scoped / unscoped. A caller is
# scoped by naming its group in mine.example.org's allowed_groups.
#
# Expectations are written per caller as Y (served) or N (refused); '-' skips a
# cell (domain-check for an unconfined caller would make a network probe).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL = qw(api ui mcp webdav manage_domains manage_users manage_config manage_content
    manage_nav manage_themes manage_layouts);
my %CAPS = (
    op => [qw(ui manage_domains manage_users manage_config manage_content manage_nav manage_themes manage_layouts)],
    cks => [qw(ui manage_domains manage_nav manage_content manage_config)],
    cku => [qw(ui manage_domains manage_nav manage_content manage_config)],
    tks => [qw(api manage_domains manage_nav manage_content)],
    tku => [qw(api manage_domains manage_nav manage_content)],
    mcs => [qw(mcp manage_domains manage_nav manage_content manage_themes manage_layouts)],
    mcu => [qw(mcp manage_domains manage_nav manage_content manage_themes manage_layouts)],
    mcm => [qw(mcp manage_domains manage_nav manage_content manage_themes manage_layouts manage_users)],
    dvs => [qw(webdav manage_content manage_nav)],
    dvu => [qw(webdav manage_content manage_nav)],
);
my $SCOPED = 'g-cks, g-tks, g-mcs, g-mcm, g-dvs';

# --- one instance ------------------------------------------------------------
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub instance {
    my (%o) = @_;
    my $s = new_site( root => $root,
        conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n"
            . "extensions:\n  - plugins/remap.pl\n" );
    my $d = $s->docroot;
    make_path( "$d/sites/mine/tm", "$d/sites/other/to" );
    spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
    spit( "$d/index.md",          "# primary\n" );
    for my $u ( @{ $o{users} } ) {
        $s->add_user( $u, "pw-$u-0123456789" );
        $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
    }
    return ( $s, $d );
}

my ( $s, $d ) = instance( users => [ sort keys %CAPS ] );

sub uapi {
    my ( $dr, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $dr );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( $d, { action => 'token', username => $_ } )->{token} // '' ) }
    grep { /^(?:tk|mc)/ } keys %CAPS;

sub gz { my ($r) = @_; return ( $r->{_raw} // '' ) =~ m{Content-Type: application/gzip} ? { ok => 1 } : $r }

sub api {
    my ( $who, $action, $body, $query, %o ) = @_;
    my $dr = $o{docroot} // $d;
    if ( $who !~ /^tk/ ) {
        my $ss = $o{session} // $s;
        return gz( $ss->call( $who, $action, ( defined $body ? ( body => $body ) : () ),
                ( defined $query ? ( query => $query ) : () ) ) );
    }
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT} = $dr;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:" . ( $o{token} // $tok{$who} ), '' );
    $ENV{QUERY_STRING}   = $query // "action=$action";
    $ENV{REQUEST_METHOD} = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH} = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return gz( eval { decode_json( $jb // '' ) } // { _raw => $out } );
}
sub op { my ( $a, $b, $q ) = @_; return api( 'op', $a, $b, $q ) }

sub mcp {
    my ( $who, $tool, $args, %o ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $o{docroot} // $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:" . ( $o{token} // $tok{$who} );
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

sub dav {
    my ( $who, $method, $file, %o ) = @_;
    my $r = run_dav( $o{docroot} // $d, $method, "/lazysite/$file",
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( "$who:pw-$who-0123456789", '' ),
        ( $method eq 'PUT' ? ( body => "D$who | /\n" ) : () ) );
    return { ok => ( $r->{code} =~ /^20[014]$/ ? 1 : 0 ), error => "HTTP $r->{code}" };
}

# --- the instance's domains ---------------------------------------------------
for my $set (
    [ 'domain-add', { host => 'mine.example.org', content_root => 'sites/mine', nav_file => 'lazysite/nav-mine.conf' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other', nav_file => 'lazysite/nav-other.conf' } ],
    [ 'domain-add', { host => 'bare.example.org' } ],
    [ 'domain-add', { host => 'tm.example.org', content_root => 'sites/mine/tm' } ],
    [ 'domain-add', { host => 'to.example.org', content_root => 'sites/other/to' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => $SCOPED } ],
    [ 'nav-save', { host => 'mine.example.org', items => [ { label => 'M', url => '/' } ] } ],
    [ 'nav-save', { host => 'other.example.org', items => [ { label => 'O', url => '/' } ] } ],
    [ 'nav-save', { items => [ { label => 'P', url => '/' } ] } ],
    [ 'remap-save', { host => 'other.example.org', rules => [ { prefix => '/x', destination => 'https://x.example.com' } ] } ],
    )
{
    my $r = op( $set->[0], $set->[1] );
    ok( $r->{ok}, "set up: $set->[0] " . ( $set->[1]{host} // 'primary' ) ) or diag( $r->{error} // '' );
}
my $CONF = do { open my $fh, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$fh> };
sub reset_conf { spit( "$d/lazysite/lazysite.conf", $CONF ) }

sub expect {
    my ( $who, $order, $want ) = @_;
    my @w = split //, $want;
    my %by;
    @by{ split / /, $order } = @w;
    return $by{$who};
}

sub check {
    my ( $label, $want, $r ) = @_;
    return if $want eq '-';
    if ( $want eq 'Y' ) { ok( $r->{ok}, "served: $label" ) or diag( $r->{error} // $r->{_raw} // '' ) }
    else {
        ok( !$r->{ok}, "refused: $label" );
        # A refusal for a malformed call or a missing object would pass the line
        # above whatever the scope rule said.
        unlike( $r->{kind} // '', qr/\A(?:invalid|not-found|unknown-domain)\z/,
            '...and not for the shape of the call' ) or diag( $r->{error} // '' );
    }
    return;
}

# --- control API ---------------------------------------------------------------
my $API = 'op cks cku tks tku';
my ( $pkgM, $pkgO );
my @api = (
    [ 'domain-set mine site_name', 'YYYYN', sub { api( $_[0], 'domain-set', { host => 'mine.example.org', key => 'site_name', value => "M$_[0]" } ) } ],
    [ 'domain-set other site_name', 'YNYNN', sub { api( $_[0], 'domain-set', { host => 'other.example.org', key => 'site_name', value => "O$_[0]" } ) } ],
    [ 'domain-set bare (serves the primary) site_name', 'YNYNN', sub { api( $_[0], 'domain-set', { host => 'bare.example.org', key => 'site_name', value => "B$_[0]" } ) } ],
    [ 'domain-set mine content_root -> sites/other', 'YNYNN', sub {
            my $r = api( $_[0], 'domain-set', { host => 'mine.example.org', key => 'content_root', value => 'sites/other' } );
            op( 'domain-set', { host => 'mine.example.org', key => 'content_root', value => 'sites/mine' } ) if $r->{ok};
            $r } ],
    [ 'domain-add at sites/mine/new', 'YYYYN', sub {
            my $r = api( $_[0], 'domain-add', { host => "n1$_[0].example.org", content_root => 'sites/mine/new' } );
            op( 'domain-remove', { host => "n1$_[0].example.org" } ) if $r->{ok};
            $r } ],
    [ 'domain-add at sites/else', 'YNYNN', sub {
            my $r = api( $_[0], 'domain-add', { host => "n2$_[0].example.org", content_root => 'sites/else' } );
            op( 'domain-remove', { host => "n2$_[0].example.org" } ) if $r->{ok};
            $r } ],
    [ 'domain-add with no content root', 'YNYNN', sub {
            my $r = api( $_[0], 'domain-add', { host => "n3$_[0].example.org" } );
            op( 'domain-remove', { host => "n3$_[0].example.org" } ) if $r->{ok};
            $r } ],
    [ 'domain-alias-add of mine', 'YYYYN', sub {
            my $r = api( $_[0], 'domain-alias-add', { host => "a1$_[0].example.org", alias_of => 'mine.example.org' } );
            op( 'domain-remove', { host => "a1$_[0].example.org" } ) if $r->{ok};
            $r } ],
    [ 'domain-alias-add of other', 'YNYNN', sub {
            my $r = api( $_[0], 'domain-alias-add', { host => "a2$_[0].example.org", alias_of => 'other.example.org' } );
            op( 'domain-remove', { host => "a2$_[0].example.org" } ) if $r->{ok};
            $r } ],
    [ 'domain-remove tm (inside sites/mine)', 'YYYYN', sub {
            my $r = api( $_[0], 'domain-remove', { host => 'tm.example.org' } );
            op( 'domain-add', { host => 'tm.example.org', content_root => 'sites/mine/tm' } ) if $r->{ok};
            $r } ],
    [ 'domain-remove to (inside sites/other)', 'YNYNN', sub {
            my $r = api( $_[0], 'domain-remove', { host => 'to.example.org' } );
            op( 'domain-add', { host => 'to.example.org', content_root => 'sites/other/to' } ) if $r->{ok};
            $r } ],
    [ 'domain-check other (refused before any probe)', '-N-NN', sub { api( $_[0], 'domain-check', undef, 'action=domain-check&host=other.example.org' ) } ],
    [ 'domain-preview mine', 'YYYYN', sub { api( $_[0], 'domain-preview', undef, 'action=domain-preview&host=mine.example.org' ) } ],
    [ 'domain-preview other', 'YNYNN', sub { api( $_[0], 'domain-preview', undef, 'action=domain-preview&host=other.example.org' ) } ],
    [ 'remap-save mine', 'YYYYN', sub { api( $_[0], 'remap-save', { host => 'mine.example.org', rules => [] } ) } ],
    [ 'remap-save other', 'YNYNN', sub { api( $_[0], 'remap-save', { host => 'other.example.org', rules => [ { prefix => '/x', destination => 'https://x.example.com' } ] } ) } ],
    [ 'remap-save unserved host', 'YNYNN', sub { api( $_[0], 'remap-save', { host => 'unserved.example.net', rules => [] } ) } ],
    [ 'nav-read mine', 'YYYYN', sub { api( $_[0], 'nav-read', undef, 'action=nav-read&host=mine.example.org' ) } ],
    [ 'nav-read other', 'YNYNN', sub { api( $_[0], 'nav-read', undef, 'action=nav-read&host=other.example.org' ) } ],
    [ 'nav-read unserved', 'YNYNN', sub { api( $_[0], 'nav-read', undef, 'action=nav-read&host=unserved.example.net' ) } ],
    [ 'nav-read primary', 'YNYNY', sub { api( $_[0], 'nav-read', undef, 'action=nav-read' ) } ],
    [ 'nav-save mine', 'YYYYN', sub { api( $_[0], 'nav-save', { host => 'mine.example.org', items => [ { label => "M$_[0]", url => '/' } ] } ) } ],
    [ 'nav-save other', 'YNYNN', sub { api( $_[0], 'nav-save', { host => 'other.example.org', items => [ { label => "O$_[0]", url => '/' } ] } ) } ],
    # tm and to inherit the primary's nav file, so writing it writes theirs.
    [ 'nav-save primary (also tm and to)', 'YNYNN', sub { api( $_[0], 'nav-save', { items => [ { label => "P$_[0]", url => '/' } ] } ) } ],
    [ 'site-backup-create mine', 'YYYYN', sub { api( $_[0], 'site-backup-create', { host => 'mine.example.org' } ) } ],
    [ 'site-backup-create other', 'YNYNN', sub { api( $_[0], 'site-backup-create', { host => 'other.example.org' } ) } ],
    [ "site-backup-inspect other's package", 'YNYNN', sub { api( $_[0], 'site-backup-inspect', undef, "action=site-backup-inspect&name=$pkgO" ) } ],
    [ "site-backup-download other's package", 'YNYNN', sub { api( $_[0], 'site-backup-download', undef, "action=site-backup-download&name=$pkgO" ) } ],
    [ "backup-list shows other's package", 'YNYNN', sub {
            my $l = api( $_[0], 'backup-list' );
            { ok => ( grep { ( $_->{name} // '' ) eq $pkgO } @{ $l->{backups} || [] } ) ? 1 : 0 } } ],
    [ "site-backup-delete other's package", 'YNYNN', sub {
            my $r = api( $_[0], 'site-backup-delete', { name => $pkgO } );
            $pkgO = op( 'site-backup-create', { host => 'other.example.org' } )->{name} if $r->{ok};
            $r } ],
    [ 'site-backup-apply to mine', 'YYYYN', sub { my $r = api( $_[0], 'site-backup-apply', { name => $pkgM, host => 'mine.example.org' } ); reset_conf(); $r } ],
    [ 'site-backup-apply to other', 'YNYNN', sub { my $r = api( $_[0], 'site-backup-apply', { name => $pkgM, host => 'other.example.org' } ); reset_conf(); $r } ],
    [ 'site-backup-apply to the primary, content at sites/mine', 'YNYNN', sub {
            my $r = api( $_[0], 'site-backup-apply', { name => $pkgM, content_root => 'sites/mine' } ); reset_conf(); $r } ],
    [ 'site-export-primary', 'YNYNY', sub { api( $_[0], 'site-export-primary', {} ) } ],
    [ 'aliases-list mine', 'YYYYN', sub { api( $_[0], 'aliases-list', undef, 'action=aliases-list&host=mine.example.org' ) } ],
    [ 'aliases-list other', 'YNYNN', sub { api( $_[0], 'aliases-list', undef, 'action=aliases-list&host=other.example.org' ) } ],
    [ "aliases-list of a folder in mine (the Files page's call)", 'YYYYN', sub { api( $_[0], 'aliases-list', undef, 'action=aliases-list&path=sites%2Fmine' ) } ],
    [ 'aliases-list of the primary', 'YNYNY', sub { api( $_[0], 'aliases-list', undef, 'action=aliases-list' ) } ],
    [ 'cache-invalidate a page of other', 'YNYNN', sub { api( $_[0], 'cache-invalidate', {}, 'action=cache-invalidate&host=other.example.org&path=/index' ) } ],
);
for my $who ( split / /, $API ) {
    subtest "control API, $who" => sub {
        reset_conf();
        $pkgM = op( 'site-backup-create', { host => 'mine.example.org' } )->{name}  // '';
        $pkgO = op( 'site-backup-create', { host => 'other.example.org' } )->{name} // '';
        check( $_->[0], expect( $who, $API, $_->[1] ), $_->[2]->($who) ) for @api;

        my %listed = (
            'domains-list' => [ map { $_->{host} } @{ api( $who, 'domains-list' )->{domains} || [] } ],
            'remap-list' => [ map { $_->{host} } @{ api( $who, 'remap-list' )->{rules} || [] } ],
        );
        my %want = (
            op => [ '(default)', qw(mine.example.org other.example.org bare.example.org tm.example.org to.example.org) ],
            cku => [ '(default)', qw(mine.example.org other.example.org bare.example.org tm.example.org to.example.org) ],
            cks => [qw(mine.example.org tm.example.org)],
            tks => [qw(mine.example.org tm.example.org)],
            tku => [ '(default)', 'bare.example.org' ],
        );
        is_deeply( $listed{'domains-list'}, $want{$who}, 'domains-list shows the domains it reaches' );
        my @other = grep { $_ eq 'other.example.org' } @{ $listed{'remap-list'} };
        is( scalar @other, ( $who =~ /^(?:op|cku)$/ ? 1 : 0 ), "remap-list shows other's rules only to the unconfined" );
    };
}

# --- MCP -----------------------------------------------------------------------
my $MCP = 'mcs mcu mcm';
my @mcp = (
    [ 'domain_set mine site_name', 'YNY', sub { mcp( $_[0], 'domain_set', { host => 'mine.example.org', key => 'site_name', value => "M$_[0]" } ) } ],
    [ 'domain_set other site_name', 'NNN', sub { mcp( $_[0], 'domain_set', { host => 'other.example.org', key => 'site_name', value => "O$_[0]" } ) } ],
    [ 'domain_set bare site_name', 'NNN', sub { mcp( $_[0], 'domain_set', { host => 'bare.example.org', key => 'site_name', value => "B$_[0]" } ) } ],
    [ 'domain_set other allowed_groups', 'NNN', sub { my $r = mcp( $_[0], 'domain_set', { host => 'other.example.org', key => 'allowed_groups', value => "g-$_[0]" } ); reset_conf(); $r } ],
    [ 'domain_set mine allowed_groups (needs manage_users)', 'NNY', sub { my $r = mcp( $_[0], 'domain_set', { host => 'mine.example.org', key => 'allowed_groups', value => "$SCOPED, g-$_[0]" } ); reset_conf(); $r } ],
    [ 'preview_domain mine', 'YNY', sub { mcp( $_[0], 'preview_domain', { host => 'mine.example.org' } ) } ],
    [ 'preview_domain other', 'NNN', sub { mcp( $_[0], 'preview_domain', { host => 'other.example.org' } ) } ],
    [ 'site_backup mine', 'YNY', sub { mcp( $_[0], 'site_backup', { host => 'mine.example.org' } ) } ],
    [ 'site_backup other', 'NNN', sub { mcp( $_[0], 'site_backup', { host => 'other.example.org' } ) } ],
    [ 'site_apply to mine', 'YNY', sub { my $r = mcp( $_[0], 'site_apply', { name => $pkgM, host => 'mine.example.org' } ); reset_conf(); $r } ],
    [ 'site_apply to other', 'NNN', sub { my $r = mcp( $_[0], 'site_apply', { name => $pkgM, host => 'other.example.org' } ); reset_conf(); $r } ],
    [ 'site_apply to the primary', 'NNN', sub { my $r = mcp( $_[0], 'site_apply', { name => $pkgM } ); reset_conf(); $r } ],
    [ 'activate_theme bound to mine', 'YNY', sub { my $r = mcp( $_[0], 'activate_theme', { theme => 'plain', host => 'mine.example.org' } ); reset_conf(); $r } ],
    [ 'activate_theme bound to other', 'NNN', sub { my $r = mcp( $_[0], 'activate_theme', { theme => 'plain', host => 'other.example.org' } ); reset_conf(); $r } ],
    [ 'activate_layout bound to other', 'NNN', sub { my $r = mcp( $_[0], 'activate_layout', { layout => 'plain', host => 'other.example.org' } ); reset_conf(); $r } ],
    [ 'read_nav mine', 'YNY', sub { mcp( $_[0], 'read_nav', { host => 'mine.example.org' } ) } ],
    [ 'read_nav other', 'NNN', sub { mcp( $_[0], 'read_nav', { host => 'other.example.org' } ) } ],
    [ 'read_nav primary', 'NYN', sub { mcp( $_[0], 'read_nav', {} ) } ],
    [ 'set_nav mine', 'YNY', sub { mcp( $_[0], 'set_nav', { host => 'mine.example.org', items => [ { label => "M$_[0]", url => '/' } ] } ) } ],
    [ 'set_nav other', 'NNN', sub { mcp( $_[0], 'set_nav', { host => 'other.example.org', items => [ { label => "O$_[0]", url => '/' } ] } ) } ],
    [ 'set_nav primary (also tm and to)', 'NNN', sub { mcp( $_[0], 'set_nav', { items => [ { label => "P$_[0]", url => '/' } ] } ) } ],
);
for my $who ( split / /, $MCP ) {
    subtest "MCP, $who" => sub {
        reset_conf();
        $pkgM = op( 'site-backup-create', { host => 'mine.example.org' } )->{name} // '';
        check( $_->[0], expect( $who, $MCP, $_->[1] ), $_->[2]->($who) ) for @mcp;
        my @hosts = map { $_->{host} } @{ mcp( $who, 'list_domains', {} )->{domains} || [] };
        is_deeply( \@hosts,
            ( $who eq 'mcu' ? [ '(default)', 'bare.example.org' ] : [qw(mine.example.org tm.example.org)] ),
            'list_domains shows the domains it reaches' );
    };
}

# --- WebDAV ---------------------------------------------------------------------
my $DAV = 'dvs dvu';
for my $who ( split / /, $DAV ) {
    subtest "WebDAV, $who" => sub {
        reset_conf();
        my @dav = (
            [ 'GET nav-mine.conf',  'YN' ], [ 'PUT nav-mine.conf',  'YN' ],
            [ 'GET nav-other.conf', 'NN' ], [ 'PUT nav-other.conf', 'NN' ],
            # The primary's file is also tm's (dvs reaches it) and to's (neither does).
            [ 'GET nav.conf', 'YY' ], [ 'PUT nav.conf', 'NN' ],
        );
        for my $c (@dav) {
            my ( $m, $f ) = split / /, $c->[0];
            check( "$c->[0] as $who", expect( $who, $DAV, $c->[1] ), dav( $who, $m, $f ) );
        }
    };
}

# --- one site, no domains: an unbound grant still keeps the primary's nav --------
subtest 'a single-site instance: an unbound grant reads and writes the primary nav' => sub {
    my ( $s1, $d1 ) = instance( users => [qw(tku mcu dvu)] );
    my %t1 = map { $_ => ( uapi( $d1, { action => 'token', username => $_ } )->{token} // '' ) } qw(tku mcu);
    ok( api( 'tku', 'nav-read', undef, 'action=nav-read', docroot => $d1, token => $t1{tku} )->{ok}, 'token nav-read' );
    ok( api( 'tku', 'nav-save', { items => [ { label => 'T', url => '/' } ] }, undef, docroot => $d1, token => $t1{tku} )->{ok}, 'token nav-save' );
    ok( mcp( 'mcu', 'read_nav', {}, docroot => $d1, token => $t1{mcu} )->{ok}, 'MCP read_nav' );
    ok( mcp( 'mcu', 'set_nav', { items => [ { label => 'M', url => '/' } ] }, docroot => $d1, token => $t1{mcu} )->{ok}, 'MCP set_nav' );
    ok( dav( 'dvu', 'PUT', 'nav.conf', docroot => $d1 )->{ok}, 'WebDAV PUT nav.conf' );
};

done_testing();

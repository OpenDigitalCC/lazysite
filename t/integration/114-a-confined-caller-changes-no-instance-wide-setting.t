#!/usr/bin/perl
# SM976 R1 (ruled 2026-10-09, "Confined = no instance-wide"): a domain-confined
# caller - a token, MCP grant or cookie manager whose scope binds some domains -
# changes no instance-wide setting. It acts on its own domains only, through the
# actions addressed to a host. The operator, an unbound cookie manager and an
# unbound token or grant (which reach the primary, whose settings these are) are
# unchanged.
#
# Before this, a token scoped to one domain with manage_config rewrote the
# instance's site_name, and confined callers activated the instance theme and
# layout, enabled and configured extensions, rotated the auth secret, wrote the
# connector, handler and schedule registries, deleted layouts, created,
# restored and downloaded whole-instance backups (with the account store), and
# MCP grants did the same through activate_theme/activate_layout without a host,
# install_layout, delete_layout, the handler and schedule tools and create_theme
# with activate. The probe was tmp/q15c-probe.pl.
#
# Every action declared `instance_wide` in Lazysite::ControlApi::Actions is
# called here by every caller that holds its capability on that door; t/lint/218
# holds every mutating action to that list.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP                      qw(encode_json decode_json);
use IPC::Open2                    qw(open2);
use IPC::Open3                    qw(open3);
use Symbol                        qw(gensym);
use MIME::Base64                  qw(encode_base64);
use File::Path                    qw(make_path);
use TestHelper                    qw(repo_root);
use ManagerSession                qw(new_site);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL = qw(api ui mcp manage_domains manage_users manage_config manage_content manage_themes
    manage_layouts manage_connectors manage_forms manage_data audit_switch purge manage_briefs);
my @WORK = grep { !/^(?:api|ui|mcp|manage_users)$/ } @ALL;
my %CHAN = ( cku => 'ui', cks => 'ui', tku => 'api', tks => 'api', mcu => 'mcp', mcs => 'mcp' );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nlayout: base\ntheme: one\n"
        . "layouts_repo: invalid\nextensions:\n  - plugins/remap.pl\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
for my $l (qw(base spare gone)) {
    make_path("$d/lazysite/layouts/$l/themes");
    spit( "$d/lazysite/layouts/$l/layout.tt", "<html>[% content %]</html>\n" );
}
for my $t (qw(one two loose)) {
    make_path("$d/lazysite/layouts/base/themes/$t");
    spit( "$d/lazysite/layouts/base/themes/$t/theme.json",
        qq({"name":"$t","version":"1.0.0","layouts":["base"],"config":{}}) );
}
$s->add_user('op');
$s->grant( 'op', 'g-op', [ 'ui', 'manage_users', @WORK ], \@ALL );
for my $u ( sort keys %CHAN ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", [ $CHAN{$u}, @WORK ], \@ALL );
}
sub op { my ( $a, $b, $q ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ), ( defined $q ? ( query => $q ) : () ) ) }
ok( op( 'domain-add', { host => 'mine.example.org', content_root => 'sites/mine' } )->{ok}, 'setup: mine' );
ok( op( 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } )->{ok}, 'setup: other' );
ok( op( 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks, g-tks, g-mcs' } )->{ok},
    'setup: cks, tks and mcs are scoped to mine' );
my $full = op( 'backup-create', {}, 'action=backup-create&scope=full' )->{name} // '';
ok( length $full, 'setup: a full instance backup exists' );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tku tks mcu mcs);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query ) if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    my $txt = $j->{result}{content}[0]{text} // '';
    return eval { decode_json($txt) } // { ok => 0, error => $txt };
}

sub refused_iw { my ($r) = @_; return ( !$r->{ok} && ( $r->{error} // '' ) =~ /changes the whole instance/ ) ? 1 : 0 }

# Every instance-wide action, with a call that would do something real.
my %CALL = (
    'config-set'         => [ { key => 'site_name', value => 'Taken' } ],
    'theme-activate'     => [ {}, 'action=theme-activate&theme=two' ],
    'layout-activate'    => [ {}, 'action=layout-activate&layout=spare' ],
    'layouts-repo-set'   => [ { value  => 'probe/repo' } ],
    'layout-install'     => [ { layout => 'x' } ],
    'layouts-install'    => [ { tag    => 'v1' } ],
    'layout-delete'      => [ {}, 'action=layout-delete&layout=gone' ],
    'plugin-enable'      => [ { script => 'plugins/remap.pl' } ],
    'plugin-disable'     => [ { script => 'plugins/remap.pl' } ],
    'plugin-save'        => [ { script => 'plugins/remap.pl', values    => {} } ],
    'plugin-action'      => [ { script => 'plugins/remap.pl', action_id => 'none' } ],
    'audit-trail-set'    => [ { state  => 'on',               reason    => 'probe' } ],
    'git-init'           => [ {} ],
    'bad-url-block'      => [ { ip => '192.0.2.7' } ],
    'bad-url-unblock'    => [ { ip => '192.0.2.7' } ],
    'rotate-auth-secret' => [ {} ],
    'backup-create'      => [ {} ],
    'backup-restore' => [ {}, 'action=backup-restore&name=lazysite-manual-20260101-000000.tar.gz' ],
    'backup-delete' => [ { name => 'lazysite-manual-20260101-000000.tar.gz' } ],
    'artifact-backups-delete' => [ {}, 'action=artifact-backups-delete&path=lazysite/layouts/base-backup-20260101' ],
    'connector-save' => [ { id => 'probe', connector => { type => 'http', url => 'https://example.invalid/' } } ],
    'connector-secret-set' => [ { id => 'probe', secret => 's' } ],
    'connector-delete'     => [ { id => 'probe' } ],
    'odoo-secret-set'      => [ { secret => 's' } ],
    'odoo-secret-clear'    => [ {} ],
    # SM1051: handler-save and handler-delete left the list - a handler may carry
    # domain:, and an instance handler (none) is refused to a confined caller in
    # the branch: t/integration/210.
    'schedule-save'   => [ { id => 'probe', handler => 'probe', every => 300 } ],
    'schedule-delete' => [ { id => 'probe' } ],
    'briefs-migrate'  => [ {} ],
);
my %IW = Lazysite::ControlApi::Actions::instance_wide();
is_deeply( [ sort keys %CALL ], [ sort keys %IW ], 'this file calls every instance-wide action' );
my %GATE = %Lazysite::ControlApi::Actions::GATE;
sub door_has { my ( $who, $a ) = @_; return $who =~ /^tk/ ? defined $GATE{$a} : 1 }

my $conf_before = do { open my $fh, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$fh> };

# --- the confined callers are refused, and nothing changes ---------------------
for my $who (qw(cks tks)) {
    for my $a ( sort keys %CALL ) {
        next unless door_has( $who, $a );
        my $r = api( $who, $a, @{ $CALL{$a} } );
        ok( refused_iw($r), "$who: $a refused as instance-wide" ) or diag explain $r;
    }
}
my $conf_after = do { open my $fh, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$fh> };
is( $conf_after, $conf_before, 'lazysite.conf is unchanged by every refused call' );
ok( -d "$d/lazysite/layouts/gone", 'the layout nobody serves is still installed' );

my %MCP = (
    activate_theme  => { theme  => 'two' },
    activate_layout => { layout => 'spare' },
    install_layout  => { layout => 'x' },
    delete_layout   => { layout => 'gone' },
    save_schedule   => { id => 'probe', handler => 'probe', every => 300 },
    delete_schedule => { id => 'probe' },
);
my %twin = Lazysite::ControlApi::Actions::mcp_twins();
is_deeply( [ sort keys %MCP ], [ sort map { $twin{$_} } grep { $twin{$_} } keys %IW ],
    'and every MCP twin of one' );
for my $t ( sort keys %MCP ) {
    ok( refused_iw( mcp( 'mcs', $t, $MCP{$t} ) ), "mcs: $t refused as instance-wide" );
}
my $made = mcp( 'mcs', 'create_theme', { layout => 'base', name => 'made', activate => JSON::PP::true } );
ok( refused_iw($made), 'mcs: create_theme with activate refused' );
ok( !-d "$d/lazysite/layouts/base/themes/made", '...before anything was written' );

subtest 'a confined caller still acts on its own domain, through a host' => sub {
    my $r = mcp( 'mcs', 'activate_theme', { theme => 'two', host => 'mine.example.org' } );
    ok( $r->{ok}, 'mcs: activate_theme with its own host' ) or diag explain $r;
    ok( refused_iw( mcp( 'mcs', 'activate_layout', { layout => 'spare' } ) ), '...the same tool without a host is still refused' );
    ok( !refused_iw( mcp( 'mcs', 'activate_theme', { theme => 'two', host => 'other.example.org' } ) ),
        '...another host is the domain rule\'s answer, not this one' );
    ok( mcp( 'mcs', 'create_theme', { layout => 'base', name => 'made2' } )->{ok}, 'mcs: create_theme without activate' );
    ok( mcp( 'mcs', 'copy_theme', { theme => 'two', new_name => 'copied', layout => 'base' } )->{ok}, 'mcs: copy_theme' );
    ok( api( 'cks', 'theme-copy', { new_name => 'copied2', layout => 'base' }, 'action=theme-copy&path=two' )->{ok}, 'cks: theme-copy' );
    ok( api( 'tks', 'regenerate-registries', {} )->{ok}, 'tks: regenerate-registries' );
};

subtest 'a confined manager deletes only its own themes, and sees no instance backup' => sub {
    my $del = api( 'cks', 'theme-delete', {}, 'action=theme-delete&path=loose' );
    ok( !$del->{ok}, 'cks: an operator\'s theme is not its to delete' );
    is( $del->{kind}, 'not-yours', '...for the reason a token is given (SM262)' );
    ok( -d "$d/lazysite/layouts/base/themes/loose", '...and it is still there' );
    my @seen = grep { ( $_->{scope} // '' ) ne 'site' } @{ api( 'cks', 'backup-list' )->{backups} || [] };
    is( scalar @seen, 0, 'cks: backup-list shows no instance backup' );
    ok( refused_iw( api( 'cks', 'backup-download', undef, "action=backup-download&name=$full" ) ),
        'cks: backup-download of the full backup refused' );
    my @op_seen = grep { ( $_->{scope} // '' ) ne 'site' } @{ api( 'cku', 'backup-list' )->{backups} || [] };
    ok( scalar @op_seen, 'cku (unbound): the instance backups are listed' );
};

# --- the unconfined callers are unchanged ----------------------------------------
# Not refused as instance-wide: what each call then does is its own business.
for my $who (qw(op cku tku)) {
    for my $a ( sort grep { $_ ne 'rotate-auth-secret' } keys %CALL ) {
        next unless door_has( $who, $a );
        ok( !refused_iw( api( $who, $a, @{ $CALL{$a} } ) ), "$who: $a is not refused as instance-wide" );
    }
}
my $tc = api( 'tku', 'config-set', { key => 'site_name', value => 'Unbound' } );
ok( $tc->{ok}, 'tku: config-set writes the instance' ) or diag explain $tc;
for my $t ( sort keys %MCP ) {
    ok( !refused_iw( mcp( 'mcu', $t, $MCP{$t} ) ), "mcu: $t is not refused as instance-wide" );
}
ok( !refused_iw( api( 'cku', 'backup-download', undef, "action=backup-download&name=$full" ) ),
    'cku: backup-download is not refused' );

# SM704's manual block never ran: the branch called block() and the script did
# not import it, so every call died ("Undefined subroutine &main::block") and
# answered nothing. Found by this file's probe.
my $blk = api( 'op', 'bad-url-block', { ip => '192.0.2.9' } );
ok( $blk->{ok}, 'op: bad-url-block blocks an address by hand' ) or diag explain $blk;
ok( exists( ( api( q(op), q(bad-url-blocks) )->{blocks} || {} )->{q(192.0.2.9)} ),
    '...and the address is listed' );
ok( api( 'op', 'rotate-auth-secret', {} )->{ok}, 'op: rotate-auth-secret' );

done_testing();

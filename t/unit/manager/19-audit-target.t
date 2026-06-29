#!/usr/bin/perl
# SM078 + SM077: the audit trail records the action TARGET and its ORIGIN
# (ui = cookie manager, api = control-API token), action_audit filters by user
# and target, and the reader stays backward-compatible with older 5- and
# 6-field lines. Also covers action_principals (the permissions-picker source).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");

# Stub users-tool for action_principals (list + groups).
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my $a = $r->{action} // '';
if    ($a eq 'list')   { print encode_json({ ok=>1, users => ['alice','bob'] }) }
elsif ($a eq 'groups') { print encode_json({ ok=>1, groups => { editors=>['bob'], admins=>['alice'] } }) }
else                   { print encode_json({ ok=>1 }) }
STUB
close $sf;
chmod 0755, $stub;

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT}       = $d;
$ENV{LAZYSITE_USERS_TOOL} = $stub;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# --- target + origin recorded ---
main::audit_log( 'alice', 'save', 'content/about.md', '1.2.3.4', 'ok', 'ui' );
main::audit_log( 'claude-dhcf', 'theme-activate', 'sky', '5.6.7.8', 'ok', 'api' );
my $entries = main::action_audit()->{entries};
my ($ui)  = grep { $_->{action} eq 'save' } @$entries;
my ($api) = grep { $_->{action} eq 'theme-activate' } @$entries;
is( $ui->{target}, 'content/about.md', 'SM078: target recorded' );

# --- plugin actions name the plugin, not '/' ---
is( main::_audit_plugin_target( { plugin => 'stats' }, undef ),
    'stats', 'plugin param used as audit target' );
is( main::_audit_plugin_target( {}, '{"script":"/x/plugins/form-handler.pl"}' ),
    'form-handler', 'plugin target derived from body script basename' );
is( main::_audit_plugin_target( {}, '{"script":"form-smtp"}' ),
    'form-smtp', 'plugin target from a bare script name' );
is( main::_audit_plugin_target( {}, undef ), '', 'no plugin info -> empty target' );

# plugin-save names the setting(s) changed, not just the plugin.
is( main::_audit_plugin_target( { plugin => 'lazysite' },
        '{"values":{"site_name":"X"}}', 'plugin-save' ),
    'lazysite (site_name)', 'plugin-save names the changed setting' );
is( main::_audit_plugin_target( { plugin => 'lazysite' },
        '{"values":{"webdav_enabled":"on","site_name":"X"}}', 'plugin-save' ),
    'lazysite (site_name, webdav_enabled)', 'plugin-save lists keys, sorted' );
is( main::_audit_plugin_target( { plugin => 'stats' }, '{}', 'plugin-action' ),
    'stats', 'a non-save plugin action stays just the plugin name' );
is( main::_audit_implicit_target('nav-save'), 'nav', 'nav-save audit target is nav, not /' );
is( main::_audit_implicit_target('save'),     '',    'actions with a real path have no implicit target' );

# --- date-range filter (start/end) on the audit page ---
{
    open my $lh, '>>', "$d/lazysite/logs/audit.log" or die $!;
    print $lh "2026-01-05T10:00:00Z | dave | save | content/jan.md | 1.1.1.1 | ok | ui\n";
    print $lh "2026-06-15T10:00:00Z | dave | save | content/jun.md | 1.1.1.1 | ok | ui\n";
    print $lh "2026-12-20T10:00:00Z | dave | save | content/dec.md | 1.1.1.1 | ok | ui\n";
    close $lh;
    my $jun = main::action_audit( start => '2026-06-01', end => '2026-06-30' )->{entries};
    my @t = sort map { $_->{target} } grep { $_->{user} eq 'dave' } @$jun;
    is_deeply( \@t, ['content/jun.md'], 'date range returns only entries within [start,end]' );
    my $from = main::action_audit( start => '2026-06-01' )->{entries};
    ok( ( grep { $_->{target} eq 'content/dec.md' } @$from ),
        'open-ended start includes later entries' );
    ok( !( grep { ( $_->{target} // '' ) eq 'content/jan.md' } @$from ),
        'start excludes earlier entries' );
}
is( $ui->{origin}, 'ui',  'SM077: cookie action recorded as origin=ui' );
is( $api->{origin}, 'api', 'SM077: token action recorded as origin=api' );

# --- target filter ---
main::audit_log( 'alice', 'delete', 'content/about.md', '1.2.3.4', 'ok', 'ui' );
my $bytarget = main::action_audit( target => 'content/about.md' )->{entries};
ok( scalar(@$bytarget) >= 2, 'target filter returns that file history' );
ok( ( !grep { ( $_->{target} // '' ) ne 'content/about.md' } @$bytarget ),
    'target filter excludes other targets' );

# --- backward compatibility: older 5- and 6-field lines parse ---
open my $fh, '>>', "$d/lazysite/logs/audit.log" or die $!;
print {$fh} "2026-01-01T00:00:00Z | bob | delete | 9.9.9.9 | fail\n";                # 5-field (pre-SM078)
print {$fh} "2026-01-02T00:00:00Z | carol | save | content/x.md | 9.9.9.9 | ok\n";  # 6-field (SM078)
close $fh;
my %by_user = map { ( $_->{user} // '' ) => $_ } @{ main::action_audit()->{entries} };
is( $by_user{bob}{target},   '',             'old 5-field line: empty target' );
is( $by_user{bob}{origin},   '',             'old 5-field line: empty origin' );
is( $by_user{carol}{target}, 'content/x.md', '6-field line: target parsed' );
is( $by_user{carol}{origin}, '',             '6-field line: empty origin (back-compat)' );

# --- action_principals merges users + group names for the pickers ---
my $p = main::action_principals();
ok( $p->{ok}, 'principals ok' );
is_deeply( $p->{users}, [ 'alice', 'bob' ], 'principals: users listed' );
is_deeply( $p->{groups}, [ 'admins', 'editors' ], 'principals: group names listed (sorted)' );

# --- pagination: 50 rows per page ---
main::audit_log( 'pager', 'create', "content/p$_.md", '1.1.1.1', 'ok', 'ui' ) for ( 1 .. 60 );
my $pg1 = main::action_audit( user => 'pager', per_page => 50, page => 1 );
is( scalar @{ $pg1->{entries} }, 50, 'page 1 returns 50 rows' );
is( $pg1->{total}, 60, 'total counts all matching entries' );
is( $pg1->{pages}, 2,  'two pages at 50/page' );
is( $pg1->{page},  1,  'page echoed' );
my $pg2 = main::action_audit( user => 'pager', per_page => 50, page => 2 );
is( scalar @{ $pg2->{entries} }, 10, 'page 2 returns the remaining 10 rows' );
my $pgX = main::action_audit( user => 'pager', per_page => 50, page => 99 );
is( $pgX->{page}, 2, 'an out-of-range page clamps to the last' );

# --- failure detail (8th field) round-trips ---
main::audit_log( 'dave', 'edit', 'lazysite/forms/x.conf', '2.2.2.2', 'fail', 'mcp', 'blocked-config' );
my ($f) = grep { ( $_->{status} // '' ) eq 'fail' && ( $_->{target} // '' ) eq 'lazysite/forms/x.conf' }
    @{ main::action_audit()->{entries} };
is( $f->{detail}, 'blocked-config', 'audit records + returns a failure detail' );

done_testing();

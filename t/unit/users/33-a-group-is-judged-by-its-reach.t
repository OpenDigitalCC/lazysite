#!/usr/bin/perl
# SM564: a group is judged by its REACH, not its record.
#
# A group's declared capabilities and what its members can actually call are
# different things - SM570 proved an account holding no content capability
# could rewrite ACLs. So the question "does this group still make sense" is
# answered empirically: per surface, what can a member CALL, derived from the
# same `unlocks` tables the dispatchers are held to (t/lint/14, 23, 86).
#
# Two rules must fall out of the tables, never be declared: a channel flag
# alone unlocks nothing (a door is not an authority), and an action capability
# without its door reaches nothing. And nesting must be honoured, because the
# resolver honours it - a report that read direct membership only would show
# nothing for exactly the grants hardest to audit (SM268 02-6).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root);
use Lazysite::Capabilities qw(describe reach_for channel_keys);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

# --- the function: exactly the table, and nothing a door alone adds --------
my $table   = describe()->{capabilities};
my @nav_api = @{ $table->{manage_nav}{unlocks}{api} || [] };
my @nav_mcp = @{ $table->{manage_nav}{unlocks}{mcp} || [] };
ok( @nav_api && @nav_mcp, 'the fixture capability has a surface on both remote channels' );

my $r = reach_for( { manage_nav => 1, api => 1 } );
is_deeply( [ sort @{ $r->{api}{callable} } ], [ sort @nav_api ],
    'one capability + its door: callable on that door is EXACTLY what the table unlocks' );
is_deeply( $r->{mcp}{callable}, [],
    'the same capability reaches nothing on a door that is not held' );
is_deeply( [ sort @{ $r->{mcp}{unlocked} } ], [ sort @nav_mcp ],
    'though the report still says what that closed door would unlock' );
is( $r->{api}{held}, 1, 'the held door is reported open' );
is( $r->{mcp}{held}, 0, 'and the other closed' );
is_deeply( [ map { @{ $r->{$_}{callable} } } qw(ui webdav) ], [],
    'a capability with no surface on a channel adds nothing there' );

my $door_only = reach_for( { api => 1, mcp => 1, webdav => 1, ui => 1 } );
is_deeply( [ map { @{ $door_only->{$_}{callable} }, @{ $door_only->{$_}{unlocked} } } channel_keys() ],
    [], 'every door open and no action capability: nothing is callable anywhere (SM570)' );

my $no_door = reach_for( { manage_nav => 1, manage_content => 1 } );
is_deeply( [ map { @{ $no_door->{$_}{callable} } } channel_keys() ],
    [], 'action capabilities with no door reach nothing' );

# --- the command: the tool reports the same, through the nesting closure ---
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

sub users {
    my $cmd = join ' ', map { quotemeta } ( $^X, $script, '--docroot', $d, @_ );
    my $out = qx($cmd 2>&1);
    return ( $? >> 8, $out );
}

users( 'group-set',  'nav-only',  'manage_nav', 'on' );
users( 'group-set',  'nav-only',  'api',        'on' );
users( 'group-set',  'door-only', 'mcp',        'on' );
users( 'group-set',  'inner',     'ui',         'on' );
users( 'group-nest', 'inner',     'nav-only' );

my ( $rc, $out ) = users( 'group-reach', 'nav-only' );
is( $rc, 0, 'group-reach runs' ) or diag($out);
my ($api_line) = $out =~ /^\s+api\s+open\s+(\d+ callable: [^\n]*)$/m;
ok( defined $api_line, 'the api door is open with a callable list' ) or diag($out);
like( $api_line, qr/\b\Q$_\E\b/, "  ... naming $_" ) for @nav_api;
my ($n) = $api_line =~ /^(\d+) callable/;
is( $n, scalar @nav_api, '  ... and exactly that many' );
like( $out, qr/^\s+mcp\s+closed\s+0 callable \(\d+ unlocked/m,
    'the mcp door is closed and the unreachable count is shown, so the drift is legible' );
unlike( $out, qr/^\s+mcp\s+open/m, 'mcp is not reported open by the api flag' );

( $rc, $out ) = users( 'group-reach', 'door-only' );
like( $out, qr/holds: \(no action capability\)/, 'a door-only group is named as such' );
like( $out, qr/^\s+mcp\s+open\s+0 callable$/m,
    'and its open door has NOTHING behind it - a channel flag alone adds nothing' );

( $rc, $out ) = users( 'group-reach', 'inner' );
like( $out, qr/manage_nav \(via nav-only\)/,
    'a nested group inherits its parent\'s capability and says where it came from' );
like( $out, qr/^\s+api\s+open\s+\d+ callable: .*\bnav-read\b/m,
    'and reaches the parent\'s actions - the closure caps_for enforces' );

( $rc, $out ) = users('group-reach');
like( $out, qr/^== nav-only/m,  'no argument: every group is reported' );
like( $out, qr/^== door-only/m, '  ... including the door-only one' );

users( 'add',       'm1', 'pass12345678' );
users( 'group-add', 'm1', 'plain-members' );
( $rc, $out ) = users( 'group-reach', 'plain-members' );
is( $rc, 0, 'a group that exists only in the membership file is still a group' ) or diag($out);
like( $out, qr/holds: \(no action capability\)/, '  ... and is reported as holding nothing' );
like( $out, qr/doors: \(none/, '  ... with no door - not omitted, which would read as "not a group"' );

( $rc, $out ) = users( 'group-reach', 'no-such-group' );
isnt( $rc, 0, 'an unknown group is refused' );
like( $out, qr/not found/, '  ... by name' );

done_testing();

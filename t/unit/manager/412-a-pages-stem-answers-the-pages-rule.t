#!/usr/bin/perl
# SM1296 (O-3, edge walk of 0.16.1): GET_PERMISSIONS ON A PAGE'S STEM ANSWERS THE
# RULE THAT GOVERNS THE PAGE, AND SAYS WHICH KEY HOLDS IT.
#
# On edge, /zz76/b.md was a draft: drafted through its stem before a move, and
# the move folded the rule into the page's own key (SM1257). get_permissions on
# /zz76/b then answered `acl: null` - the exact key held nothing - so a caller
# checking the page it had just drafted saw no rule at all. Asserted through the
# control API's acl-get (the twin of MCP get_permissions: both are
# Files::action_acl_get) and the CLI's `lazysite acl show`, from both sides: a
# rule at the page's key asked by the stem, and a rule at the stem asked by the
# page. A folder of the stem's name keeps the stem key as the folder's rule.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my $s = new_site( root => $root );
my $d = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'ops', [qw(ui manage_content manage_users)], [qw(ui manage_content manage_users)] );
sub call { my ( $a, %o ) = @_; return $s->call( 'boss', $a, %o ) }
sub get  { return call( 'acl-get', query => "action=acl-get&path=$_[0]" ) }
sub acls { open my $f, '<', "$d/lazysite/auth/acls.json" or return {}; local $/; return JSON::PP::decode_json(<$f>) }

make_path("$d/zz76");
ok( call( 'acl-set', query => 'action=acl-set&path=/zz76/a', body => { draft => JSON::PP::true } )->{ok},
    'the page is drafted through its stem' );
ok( call( 'save', query => 'action=save&path=/zz76/a.md', body => { content => "---\ntitle: A\n---\nHeld.\n" } )->{ok},
    'and written' );
ok( call( 'move', query => 'action=move&path=/zz76/a.md&to=/zz76/b.md', body => {} )->{ok},
    'and moved' ) or diag explain $s->last_stderr;
ok( acls()->{'zz76/b.md'}{draft}, 'the draft is at the page\'s own key now (SM1257\'s fold)' );
ok( !exists acls()->{'zz76/b'}, 'and nothing is at its stem' );

subtest 'the stem answers the page\'s rule, and names the key' => sub {
    my $r = get('/zz76/b');
    ok( $r->{ok}, 'acl-get answers' ) or diag explain $r;
    ok( ref $r->{acl} eq 'HASH' && $r->{acl}{draft}, 'with the draft that governs /zz76/b.md' )
        or diag explain $r;
    is( $r->{key}, 'zz76/b.md', 'and the key that holds it' );
    my $p = get('/zz76/b.md');
    ok( $p->{acl}{draft}, 'the page path answers the same' );
    is( $p->{key}, 'zz76/b.md', '...from the same key' );
};

subtest 'a rule at the stem answers for the page; both are named when both hold part' => sub {
    ok( call( 'save', query => 'action=save&path=/zz76/c.md', body => { content => "---\ntitle: C\n---\nx\n" } )->{ok},
        'a second page' );
    ok( call( 'acl-set', query => 'action=acl-set&path=/zz76/c', body => { read => ['boss'] } )->{ok},
        'gated through its stem' );
    my $r = get('/zz76/c.md');
    is_deeply( $r->{acl}{read}, ['boss'], 'the page path answers the stem\'s rule' );
    is( $r->{key}, 'zz76/c', '...naming the stem key' );
    ok( call( 'acl-set', query => 'action=acl-set&path=/zz76/c.md', body => { draft => JSON::PP::true } )->{ok},
        'and drafted at its own key' );
    $r = get('/zz76/c');
    ok( $r->{acl}{draft}, 'the stem: the page\'s draft' );
    is_deeply( $r->{acl}{read}, ['boss'], '...and the stem\'s read list, as the engine reads the two' );
    is( $r->{key}, 'zz76/c.md', '...held at the page\'s key' );
    is_deeply( $r->{keys}, [ 'zz76/c.md', 'zz76/c' ], '...with both keys named' );
};

subtest 'a folder of the stem\'s name keeps its own rule' => sub {
    make_path("$d/zz76/f");
    ok( call( 'save', query => 'action=save&path=/zz76/f.md', body => { content => "---\ntitle: F\n---\nx\n" } )->{ok},
        'a landing page beside its folder' );
    ok( call( 'acl-set', query => 'action=acl-set&path=/zz76/f.md', body => { draft => JSON::PP::true } )->{ok},
        'the page is a draft at its own key' );
    my $r = get('/zz76/f');
    ok( !( ref $r->{acl} eq 'HASH' && $r->{acl}{draft} ), 'the folder\'s path does not answer the page\'s draft' );
    ok( !defined $r->{key}, '...and holds no rule of its own' );
};

subtest 'acl-set\'s audit still records the key it writes' => sub {
    ok( call( 'acl-set', query => 'action=acl-set&path=/zz76/b', body => { read => ['boss'] } )->{ok},
        'a rule written at the stem of a page whose rule is at its own key' );
    ok( acls()->{'zz76/b'} && !acls()->{'zz76/b'}{draft}, 'the stem key holds only what was written' );
    open my $lf, '<', "$d/lazysite/logs/audit.log" or die $!;
    my ($row) = reverse grep { /\| acl-set \|/ } <$lf>;
    close $lf;
    like( $row // '', qr{\| /zz76/b \|.*\| new -> read: boss}, 'the audit says the KEY had no rule before ("new")' )
        or diag $row;
    unlike( $row // '', qr{draft.* ->}, '...not the page\'s draft, which this write did not touch' );
};

subtest 'lazysite acl show names the key' => sub {
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-acl.pl", 'show', '/zz76/c', '--docroot', $d,
            '--actor', 'local' ], stderr => 'merge' );
    is( $r->{status} >> 8, 0, 'show answers' ) or diag $r->{out};
    like( $r->{out}, qr/^\s+key:\s+zz76\/c\.md \+ zz76\/c$/m, 'and says where the rule is held' );
    like( $r->{out}, qr/policy: draft/, '...and that it is a draft' );
};

done_testing;

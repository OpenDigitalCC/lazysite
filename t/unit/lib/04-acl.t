#!/usr/bin/perl
# SM079 step 2c: Lazysite::Auth::Acl - the SM074 ACL store + allow checks,
# unit-tested in-process.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Acl qw(load_acls save_acls _acl_norm _to_list _acl_allows);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
$Lazysite::Auth::Acl::DOCROOT = $d;

is_deeply( load_acls(), {}, 'empty store when no file' );
ok( save_acls( { 'content/x.md' => { owner => 'alice', write => ['bob'] } } ), 'save_acls' );
is_deeply( load_acls(), { 'content/x.md' => { owner => 'alice', write => ['bob'] } },
    'save then load round-trips' );

is( _acl_norm('/content/x.md'), 'content/x.md', '_acl_norm strips leading slash' );
is_deeply( _to_list('a, b c'),      [qw(a b c)], '_to_list splits comma/space' );
is_deeply( _to_list( [ 'x', '' ] ), ['x'],       '_to_list arrayref drops empties' );
is( _to_list(undef), undef, '_to_list undef stays undef' );

ok( _acl_allows( 'content/x.md',  'write', 'alice' ), 'owner allowed' );
ok( _acl_allows( 'content/x.md',  'write', 'bob' ),   'write-list member allowed' );
ok( !_acl_allows( 'content/x.md', 'write', 'eve' ),   'non-member denied' );
ok( _acl_allows( 'unlisted.md', 'write', 'eve' ), 'no entry -> allowed (scope governs)' );

# --- SM077: @group entries match via the requester's groups ---
save_acls( { 'content/team.md' => { owner => 'alice', write => ['@editors'] } } );
{
    local @Lazysite::Auth::Acl::user_groups = ('editors');
    ok( _acl_allows( 'content/team.md', 'write', 'bob' ),
        '@group entry allows a member of that group' );
}
{
    local @Lazysite::Auth::Acl::user_groups = ('authors');
    ok( !_acl_allows( 'content/team.md', 'write', 'bob' ),
        'a non-member of the @group is denied' );
}
{
    local @Lazysite::Auth::Acl::user_groups = ();    # e.g. a token partner
    ok( !_acl_allows( 'content/team.md', 'write', 'bob' ),
        'a requester with no groups never matches a @group (safe default)' );
}
ok( _acl_allows( 'content/team.md', 'write', 'alice' ),
    'owner still allowed regardless of groups' );

# --- DAO-4: load_acls is memoised, and the memo may not outlive a save ------
#
# Keyed on (path, mtime, size). Two saves in the same second, of the SAME
# LENGTH - 'bob' and 'eve' are both three characters - carry an identical key,
# which is the one case the key cannot see. save_acls clears the memo and the
# one-second guard covers the rest; without either, this reads a permission
# decision from before the operator changed it.
save_acls( { 'content/memo.md' => { owner => 'alice', write => ['bob'] } } );
ok( _acl_allows( 'content/memo.md', 'write', 'bob' ), 'the saved rule is seen' );
save_acls( { 'content/memo.md' => { owner => 'alice', write => ['eve'] } } );
ok( !_acl_allows( 'content/memo.md', 'write', 'bob' ),
    'a same-second, same-size rewrite is seen too - bob loses write' );
ok( _acl_allows( 'content/memo.md', 'write', 'eve' ),
    'and eve, who replaced him, has it' );

# And a caller that mutates what load_acls handed back cannot change what the
# next caller reads: several manager actions delete from the map before saving,
# and a save that FAILS would otherwise leave the process answering from a map
# that never reached the file.
{
    my $mine = load_acls();
    delete $mine->{'content/memo.md'};
    ok( _acl_allows( 'content/memo.md', 'write', 'eve' ),
        'mutating one caller\'s copy leaves the store as it was' );
}

done_testing();

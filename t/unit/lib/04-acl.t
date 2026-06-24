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
is_deeply( _to_list('a, b c'), [qw(a b c)], '_to_list splits comma/space' );
is_deeply( _to_list( [ 'x', '' ] ), ['x'], '_to_list arrayref drops empties' );
is( _to_list(undef), undef, '_to_list undef stays undef' );

ok( _acl_allows( 'content/x.md', 'write', 'alice' ), 'owner allowed' );
ok( _acl_allows( 'content/x.md', 'write', 'bob' ),   'write-list member allowed' );
ok( !_acl_allows( 'content/x.md', 'write', 'eve' ),  'non-member denied' );
ok( _acl_allows( 'unlisted.md', 'write', 'eve' ),    'no entry -> allowed (scope governs)' );

done_testing();

#!/usr/bin/perl
# SM1092: a WebDAV DELETE of a folder answers 204 only when the folder is gone.
#
# The 0.15.5 test plan, "Found outside the rows": "WebDAV DELETE of a folder
# answered 204 and left files. /zz-0155-f7/ held two pages whose rule had just
# been removed (content moved back from the private store); DELETE of the folder
# returned 204, and the folder and both .md files were still there; deleting the
# files then the folder worked."
#
# The shape that produces it: a rule on each page moves the page into the
# private store, and the move creates the folder there too (SM286). Removing the
# rules moves the pages back and leaves that folder behind, empty. The folder
# now exists in BOTH trees, resolve() prefers the private one, and DELETE
# removed the empty private twin and answered 204 with the public folder and
# its pages untouched.
#
# And the members are asked: a folder DELETE removes every path beneath it, so a
# member whose rule refuses the caller write refuses the whole DELETE, nothing
# removed, the response naming the member (RFC 4918 9.6.1 lets a server refuse
# a collection it cannot delete in full; the safe choice of the two).
use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64);
use File::Path   qw(remove_tree);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav dav_users_tool grant_caps);
use Lazysite::Auth::Acl ();
use Lazysite::Private   ();

my $s = setup_dav_site();
my $a = $s->{auth};
my $d = $s->{docroot};
my $p = Lazysite::Private::private_root($d);
# setup_dav_site's docroot is a bare tempdir; the store beside it is not inside
# what CLEANUP removes, so it goes here.
END { remove_tree($p) if defined $p && -d $p }

sub acls {
    my ($set) = @_;
    local $Lazysite::Auth::Acl::DOCROOT = $d;
    my $all = Lazysite::Auth::Acl::load_acls();
    if ($set) {
        for my $k ( keys %$set ) {
            if   ( defined $set->{$k} ) { $all->{$k} = $set->{$k} }
            else                        { delete $all->{$k} }
        }
        Lazysite::Auth::Acl::save_acls($all) or die 'acls';
    }
    return $all;
}

sub put { run_dav( $d, 'PUT', $_[0], body => $_[1], HTTP_AUTHORIZATION => $_[2] // $a ) }

# --- the field shape: rules set on two pages, then removed ---------------------
is( run_dav( $d, 'MKCOL', '/zz-f7', HTTP_AUTHORIZATION => $a )->{code}, 201, 'the folder is made' );
is( put( '/zz-f7/a.md', "a\n" )->{code}, 201, 'a page in it' );
is( put( '/zz-f7/b.md', "b\n" )->{code}, 201, 'and a second' );

my $rule = { owner => 'deploy', read => ['deploy'], write => ['deploy'] };
acls( { 'zz-f7/a.md' => $rule, 'zz-f7/b.md' => $rule } );
ok( ( Lazysite::Private::move_in( $d, $_ ) )[0], "the rule moves $_ into the store" )
    for 'zz-f7/a.md', 'zz-f7/b.md';
acls( { 'zz-f7/a.md' => undef, 'zz-f7/b.md' => undef } );
ok( ( Lazysite::Private::move_out( $d, $_ ) )[0], "removing it moves $_ back" )
    for 'zz-f7/a.md', 'zz-f7/b.md';
ok( -f "$d/zz-f7/a.md" && -f "$d/zz-f7/b.md", 'both pages are public again' );
ok( -d "$p/zz-f7", 'and the store still holds the folder they were moved into' );

my $r = run_dav( $d, 'DELETE', '/zz-f7', HTTP_AUTHORIZATION => $a );
is( $r->{code}, 204, 'DELETE of the folder answers 204' ) or diag $r->{body};
ok( !-e "$d/zz-f7", 'and the folder is gone from the document root' )
    or diag( 'left: ' . join ', ', glob("$d/zz-f7/*") );
ok( !-e "$p/zz-f7", 'and from the private store' );

# --- a folder in both trees whose twin holds a gated page ----------------------
is( run_dav( $d, 'MKCOL', '/zz-mix', HTTP_AUTHORIZATION => $a )->{code}, 201, 'a second folder' );
is( put( '/zz-mix/open.md',  "o\n" )->{code}, 201, 'a public page' );
is( put( '/zz-mix/gated.md', "g\n" )->{code}, 201, 'and one about to be gated' );
acls( { 'zz-mix/gated.md' => $rule } );
ok( ( Lazysite::Private::move_in( $d, 'zz-mix/gated.md' ) )[0], 'the gated page moves into the store' );
$r = run_dav( $d, 'DELETE', '/zz-mix', HTTP_AUTHORIZATION => $a );
is( $r->{code}, 204, 'its owner deletes the folder' ) or diag $r->{body};
ok( !-e "$d/zz-mix", 'the public half is gone' );
ok( !-e "$p/zz-mix", 'and the private half' );
ok( !acls()->{'zz-mix/gated.md'}, 'and the gated page\'s rule with it' );

# --- a member the caller may not write refuses the whole DELETE ----------------
dav_users_tool( $d, 'add', 'bob', 'pw-long-enough' );
grant_caps( $d, 'bob', 'webdav', 'manage_content' );
my $bob = 'Basic ' . encode_base64( 'bob:pw-long-enough', '' );
is( run_dav( $d, 'MKCOL', '/zz-own', HTTP_AUTHORIZATION => $a )->{code}, 201, 'a third folder' );
is( put( '/zz-own/mine.md',   "m\n" )->{code}, 201, 'a page the caller may write' );
is( put( '/zz-own/theirs.md', "t\n" )->{code}, 201, 'and one about to be someone else\'s' );
acls( { 'zz-own/theirs.md' => { owner => 'bob', write => ['bob'] } } );
is( put( '/zz-own/theirs.md', "x\n" )->{code}, 403, 'control: the caller may not write it alone' );

$r = run_dav( $d, 'DELETE', '/zz-own', HTTP_AUTHORIZATION => $a );
is( $r->{code}, 403, 'so the folder DELETE is refused' ) or diag $r->{body};
like( $r->{body}, qr{'zz-own/theirs\.md'}, 'naming the member that refused it' );
like( $r->{headers}{'x-lazysite-deny-reason'} // '', qr{zz-own/theirs\.md},
    'in the deny-reason header too' );
ok( -f "$d/zz-own/mine.md",   'nothing was removed: the permitted page is still there' );
ok( -f "$d/zz-own/theirs.md", 'and the refusing one' );
ok( acls()->{'zz-own/theirs.md'}, 'and its rule' );

$r = run_dav( $d, 'DELETE', '/zz-own', HTTP_AUTHORIZATION => $bob );
is( $r->{code}, 204, 'a caller every member admits deletes the folder' ) or diag $r->{body};
ok( !-e "$d/zz-own", 'and it is gone' );

done_testing();

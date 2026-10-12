#!/usr/bin/perl
# SM1049 (P-10): a write-only rule on a folder that nothing needed moving for
# answers ok:true.
#
# The report: a write-only rule on a domain root "returns ok:false, kind
# partial, 'content could not be moved out of the document root', although the
# rule is stored and in force and nothing needed moving."
#
# A write-only rule does not keep the public out (SM286), so its direction is
# back into the document root. A folder whose own content is public, and that
# holds a gated subfolder, has a twin in the private store - the subfolder's -
# and the mover was asked to move that whole twin into a document root that
# already holds the folder. It refused, rightly: doing it would have published
# the gated subfolder. But nothing was due, and the reply said partial.
#
# What must still be partial: a move that was due and failed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path        qw(make_path);
use TestHelper        qw(repo_root);
use ManagerSession    qw(new_site);
use Lazysite::Private ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/blog/members", "$d/sites/plain" );
spit( "$d/sites/blog/index.md",         "# Blog\n" );
spit( "$d/sites/blog/members/index.md", "# Members\n" );
spit( "$d/sites/plain/index.md",        "# Plain\n" );
$s->add_user('op');
$s->grant( 'op', 'g-op', [qw(ui manage_users manage_domains manage_content)],
    [qw(ui manage_users manage_domains manage_content)] );
sub op { my ( $a, $b, $q ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ), query => $q ) }
ok( op( 'domain-add', { host => 'blog.example.test', content_root => 'sites/blog' }, 'action=domain-add' )->{ok},
    'set up: a domain at sites/blog' );

my $priv = Lazysite::Private::private_root($d);

subtest 'a gated subfolder, then a write-only rule on the domain root' => sub {
    my $g = op( 'acl-set', { read => ['op'] }, 'action=acl-set&path=sites/blog/members/' );
    ok( $g->{ok}, 'the subfolder is gated' ) or diag( $g->{error} // '' );
    ok( -e "$priv/sites/blog/members/index.md", '...and its content is in the private store' );

    my $r = op( 'acl-set', { write => ['op'] }, 'action=acl-set&path=sites/blog/' );
    ok( $r->{ok}, 'the write-only rule on the root answers ok:true' )
        or diag( 'got: ' . ( $r->{kind} // '' ) . ' - ' . ( $r->{error} // '' ) );
    isnt( $r->{kind} // '', 'partial', '...not partial' );
    is( $r->{content_moved},       0, '...nothing moved' );
    is( $r->{content_move_failed}, 0, '...and nothing failed' );
    ok( -e "$priv/sites/blog/members/index.md", 'the gated subfolder stays in the private store' );
    ok( !-e "$d/sites/blog/members/index.md", '...and is not published' );
    ok( -e "$d/sites/blog/index.md",          "the root's own page is where it was" );
};

subtest 'a write-only rule on a folder with nothing private' => sub {
    my $r = op( 'acl-set', { write => ['op'] }, 'action=acl-set&path=sites/plain/' );
    ok( $r->{ok}, 'ok:true' ) or diag( $r->{error} // '' );
    is( $r->{content_moved}, 0, '...nothing moved' );
};

subtest 'a move that was due and failed is still partial' => sub {
    # The folder was gated, so its content is in the store; then a stray public
    # copy of the same file appears. Ungating has to bring the folder back and
    # cannot, because the document root already holds it.
    make_path("$d/sites/gone");
    spit( "$d/sites/gone/index.md", "# Gone\n" );
    ok( op( 'acl-set', { read => ['op'] }, 'action=acl-set&path=sites/gone/' )->{ok}, 'a folder is gated' );
    ok( -e "$priv/sites/gone/index.md", '...and moved into the store' );
    make_path("$d/sites/gone");
    spit( "$d/sites/gone/index.md", "# a stray public copy\n" );
    my $r = op( 'acl-set', { read => [] }, 'action=acl-set&path=sites/gone/' );
    ok( !$r->{ok}, 'ungating it cannot move the content back: ok:false' );
    is( $r->{kind} // '',          'partial', '...kind partial' );
    is( $r->{content_move_failed}, 1,         '...content_move_failed' );
    like( $r->{error} // '', qr/moved back into the document root/, '...naming the direction it could not move' );
};

done_testing;

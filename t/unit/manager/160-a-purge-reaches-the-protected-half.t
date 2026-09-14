#!/usr/bin/perl
# N141D (SM852's MISS row): removing a domain with --purge deletes the
# protected half of its content too, and reports only what it actually deleted.
#
# domain_remove built its target as realpath("$DOCROOT/$clean") - the PUBLIC
# path. A protected section's bytes live in the private store BESIDE the
# docroot, so for a domain whose content root is gated, the one thing most worth
# deleting was the one thing the delete could not see.
#
# AND IT ANSWERED purged => 1. That is what lifts this above a missed file: an
# operator removing a domain to be rid of its content was told the content was
# gone, while the client's pages sat on disk. The thing deleted was the empty
# public husk a gated folder leaves behind.
#
# Reproduced before it was touched (tmp/repro-sm852-purge-reports-purged.pl):
# two files in the private store before, two after, purged => 1.
#
# SM852 graded this row FROM READING rather than reproducing it. It reproduced.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Private;
use Lazysite::Manager::Domains;

sub w {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
}

# A site with one alias domain whose content root is $root_name.
sub site {
    my (%o) = @_;
    my $d    = site_tempdir();
    my $priv = Lazysite::Private::private_root($d);
    make_path("$d/lazysite");

    if ( $o{private} ) {
        make_path("$priv/$o{root}");
        w( "$priv/$o{root}/index.md", "---\ntitle: P\n---\n\nCLIENT SECRET\n" );
        w( "$priv/$o{root}/notes.md", "---\ntitle: N\n---\n\nMORE\n" );
    }
    if ( $o{public} ) {
        make_path("$d/$o{root}");
        w( "$d/$o{root}/index.md", "---\ntitle: Pub\n---\n\nPublic\n" );
    }

    w( "$d/lazysite/lazysite.conf",
              "site_name: T\n"
            . "alias_hosts: client.example\n"
            . "alias.client.example.content_root: $o{root}\n" );

    no warnings 'once';
    $Lazysite::Manager::Domains::DOCROOT = $d;
    use warnings 'once';
    return ( $d, $priv );
}

sub files_in { my @f = glob "$_[0]/*"; return scalar @f }

# --- a GATED content root: both halves go, and the count says two ------------
{
    my ( $d, $priv ) = site( root => 'clientwork', private => 1, public => 1 );
    is( files_in("$priv/clientwork"), 2, 'the protected content is there to start' );

    my $r = Lazysite::Manager::Domains::domain_remove( 'client.example', purge => 1 );
    ok( $r->{ok}, 'the domain is removed' ) or diag explain $r;

    ok( !-d "$priv/clientwork",
        'the PROTECTED half of the content root is purged' )
        or diag( 'This is the defect: the delete resolved only '
            . '"$DOCROOT/$root", which is where a gated folder is NOT, so the '
            . "client's pages survived a purge that reported success." );
    ok( !-d "$d/clientwork", 'and so is the public half' );

    is( $r->{purged}, 2, 'and the count reports BOTH trees, not a flag' )
        or diag( 'purged was a boolean set by reaching the end of a block - it '
            . 'reported the attempt, not the outcome, and said the same thing '
            . 'whether one half or both had gone.' );
}

# --- an ordinary PUBLIC content root is unchanged in behaviour ---------------
{
    my ( $d, $priv ) = site( root => 'plainsite', public => 1 );
    my $r = Lazysite::Manager::Domains::domain_remove( 'client.example', purge => 1 );
    ok( $r->{ok}, 'a public-only domain is removed' );
    ok( !-d "$d/plainsite", 'its content is purged' );
    is( $r->{purged}, 1, 'and the count is one, because there was one tree' )
        or diag( 'Counting must not inflate: a site with no private store has '
            . 'one half, and saying two would be the old overclaim reversed.' );
}

# --- without --purge, NOTHING is deleted -------------------------------------
#
# The flag is the whole consent for destroying content. Reaching further into
# the private store must not have widened what an unflagged removal does.
{
    my ( $d, $priv ) = site( root => 'keepme', private => 1, public => 1 );
    my $r = Lazysite::Manager::Domains::domain_remove('client.example');
    ok( $r->{ok}, 'the domain is removed without purge' );
    is( $r->{purged}, 0, 'and nothing is reported purged' );
    ok( -d "$priv/keepme", 'the protected content is still there' )
        or diag( 'A removal without --purge that deletes the private store '
            . 'would be a far worse defect than the one being fixed.' );
    ok( -d "$d/keepme", 'and so is the public content' );
}

# --- containment still holds on BOTH roots -----------------------------------
#
# The docroot check could not speak for the private store - it is not under the
# docroot - so each half is confined to its own root. A content root escaping
# upward must delete nothing, in either tree.
{
    my $d    = site_tempdir();
    my $priv = Lazysite::Private::private_root($d);
    make_path("$d/lazysite");
    make_path("$priv/outside");
    w( "$priv/outside/keep.md", "keep\n" );

    # A sibling of the docroot that must never be touched.
    my $sibling = "$d/../sibling-tree";
    make_path($sibling);
    w( "$sibling/precious.md", "precious\n" );

    w( "$d/lazysite/lazysite.conf",
              "site_name: T\n"
            . "alias_hosts: client.example\n"
            . "alias.client.example.content_root: ../sibling-tree\n" );
    no warnings 'once';
    $Lazysite::Manager::Domains::DOCROOT = $d;
    use warnings 'once';

    Lazysite::Manager::Domains::domain_remove( 'client.example', purge => 1 );
    ok( -f "$sibling/precious.md",
        'a content root pointing outside the docroot purges nothing' )
        or diag( 'Reaching into a second root must not become reaching into '
            . 'any root.' );
}

done_testing();

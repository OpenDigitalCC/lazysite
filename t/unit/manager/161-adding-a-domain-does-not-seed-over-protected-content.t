#!/usr/bin/perl
# N141D (SM852 S3): adding a domain whose content root is a PROTECTED folder
# adopts that folder - it does not build a public twin and seed a page into it.
#
# domain_add resolved nothing. It built `"$DOCROOT/$rel"` and asked `-d`, then
# `-e "$dir/index.md"`. A protected folder's bytes are in the private store
# beside the docroot, so both questions answered "not there" about content that
# was there: the call made a PUBLIC directory at the gated path and wrote a
# public seed page into it, and the domain served the seed instead of the
# client's homepage.
#
# WHY IT IS WORSE THAN ONE WRONG PAGE, and this is SM852's central point: a
# public directory at a gated path pulls every LATER write under that folder
# into the served tree - including writes from the manager, MCP and DAV paths
# that resolve correctly, because they find the public directory first. One
# careless mkdir un-gates a section for everything that follows.
#
# Reproduced before fixing (tmp/repro-sm852-s3-seed-over-gated.pl). SM852 graded
# this row FROM READING; it reproduced exactly as written.
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

sub site {
    my $d    = site_tempdir();
    my $priv = Lazysite::Private::private_root($d);
    make_path("$d/lazysite");
    w( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    no warnings 'once';
    $Lazysite::Manager::Domains::DOCROOT = $d;
    use warnings 'once';
    return ( $d, $priv );
}

# --- a PROTECTED content root is adopted, not shadowed -----------------------
{
    my ( $d, $priv ) = site();
    make_path("$priv/clientwork");
    w( "$priv/clientwork/index.md",
        "---\ntitle: Client work\n---\n\nTHE REAL HOMEPAGE\n" );

    my $r = Lazysite::Manager::Domains::domain_add( 'client.example',
        content_root => 'clientwork', seed => 1, site_name => 'Client work' );
    ok( $r->{ok}, 'the domain is configured' ) or diag explain $r;

    ok( !-e "$d/clientwork/index.md",
        'no public seed page is written over the protected homepage' )
        or diag( 'This is the defect: the domain now serves a generic "Replace '
            . 'this page" seed in place of the client\'s real homepage.' );

    ok( !-d "$d/clientwork",
        'and no public directory is created at the gated path' )
        or diag( 'A public directory here un-gates the section for every LATER '
            . 'write, including from the paths that resolve correctly - they '
            . 'find the public directory first. That is the compounding half '
            . 'of SM852.' );

    # The protected content is untouched - adoption means leaving it alone.
    open my $fh, '<', "$priv/clientwork/index.md" or die $!;
    my $kept = do { local $/; <$fh> };
    close $fh;
    like( $kept, qr/THE REAL HOMEPAGE/,
        'the protected homepage is exactly as it was' );
}

# --- an ordinary new content root is still provisioned and seeded ------------
#
# The fix must not stop domain_add doing its job. A root that exists nowhere is
# created in the docroot and seeded, exactly as before.
{
    my ( $d, $priv ) = site();
    my $r = Lazysite::Manager::Domains::domain_add( 'fresh.example',
        content_root => 'freshsite', seed => 1, site_name => 'Fresh' );
    ok( $r->{ok}, 'a brand new domain is configured' );
    ok( -d "$d/freshsite", 'its content root is created in the docroot' );
    ok( -f "$d/freshsite/index.md", 'and seeded' )
        or diag( 'Resolving first must not turn every add into an adoption.' );
}

# --- an existing PUBLIC root is adopted without being re-seeded --------------
{
    my ( $d, $priv ) = site();
    make_path("$d/existing");
    w( "$d/existing/index.md", "---\ntitle: Mine\n---\n\nHAND WRITTEN\n" );

    my $r = Lazysite::Manager::Domains::domain_add( 'old.example',
        content_root => 'existing', seed => 1, site_name => 'Old' );
    ok( $r->{ok}, 'a domain over an existing public tree is configured' );

    open my $fh, '<', "$d/existing/index.md" or die $!;
    my $kept = do { local $/; <$fh> };
    close $fh;
    like( $kept, qr/HAND WRITTEN/,
        'an existing public homepage is not overwritten by the seed' )
        or diag( 'Unchanged behaviour - asserted so the fix above cannot quietly '
            . 'alter the public case while addressing the private one.' );
}

done_testing();

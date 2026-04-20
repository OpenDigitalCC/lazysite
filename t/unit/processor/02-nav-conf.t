#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

sub write_nav {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( SUFFIX => '.conf', UNLINK => 1 );
    print $fh $content;
    close $fh;
    return $path;
}

# --- basic nav ---
{
    my $nav = main::parse_nav( write_nav("Home | /\nAbout | /about\n") );
    is( scalar @$nav,        2,       'two top-level items' );
    is( $nav->[0]{label},    'Home',  'first label' );
    is( $nav->[0]{url},      '/',     'first url' );
    is( $nav->[1]{label},    'About', 'second label' );
    is( $nav->[1]{url},      '/about','second url' );
}

# --- children ---
{
    my $nav = main::parse_nav(
        write_nav("Docs | /docs\n  Install | /docs/install\n  Config | /docs/config\n") );
    is( scalar @$nav, 1, 'one top-level item' );
    is( scalar @{ $nav->[0]{children} }, 2, 'two children' );
    is( $nav->[0]{children}[0]{label}, 'Install',        'child label' );
    is( $nav->[0]{children}[0]{url},   '/docs/install',  'child url' );
}

# --- non-clickable parent (no url) ---
{
    my $nav = main::parse_nav( write_nav("Resources\n  GitHub | https://github.com\n") );
    is( $nav->[0]{url}, '', 'non-clickable parent has empty url' );
    is( $nav->[0]{children}[0]{url}, 'https://github.com', 'child url intact' );
}

# --- comments and blank lines ---
{
    my $nav = main::parse_nav( write_nav(
        "# Comment\n\nHome | /\n\n# Another comment\nAbout | /about\n"
    ) );
    is( scalar @$nav, 2, 'comments and blank lines ignored' );
}

# --- missing file returns empty arrayref ---
{
    my $nav = main::parse_nav('/nonexistent/nav.conf');
    is_deeply( $nav, [], 'missing file returns empty array' );
    is( ref $nav, 'ARRAY', 'return is arrayref even when missing' );
}

# --- empty file ---
{
    my $nav = main::parse_nav( write_nav("") );
    is_deeply( $nav, [], 'empty file returns empty array' );
}

# --- labels without URL create non-clickable top-level item ---
{
    my $nav = main::parse_nav( write_nav("Group\n  Child | /c\n") );
    is( $nav->[0]{label}, 'Group', 'parent label' );
    is( $nav->[0]{url},   '',      'parent url empty' );
}

done_testing();

#!/usr/bin/perl
# SM1152 (SM1082 Q5, SM666): a registry rebuild found stale on a request is no
# longer done inside that request.
#
# SM1069 measured the rebuild at 1.5-3 s on a 1,800-rule fixture, paid by the one
# request that happened to arrive after the TTL. The request now serves the
# registry it has and starts a detached rebuild, under one lock so only one
# runs. A registry that does not exist yet is still built on first need: there
# is nothing to serve.
#
# End to end through the real processor for the first two cases; the third
# (the lock) drives the scheduler in one process with a slow rebuild, because
# "one rebuild started" is a count and a count needs the work to be visible.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(realpath);
use Time::HiRes qw(sleep);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_processor setup_test_site site_tempdir load_processor);

my $root = repo_root();

sub t_put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub t_slurp { open my $fh, '<', $_[0] or return ''; local $/; my $c = <$fh>; close $fh; return $c // '' }

sub site {
    my $d = realpath( site_tempdir() );
    setup_test_site($d);
    make_path("$d/lazysite/templates/registries");
    copy( "$root/starter/lazysite/templates/registries/sitemap.xml.tt",
        "$d/lazysite/templates/registries/sitemap.xml.tt" ) or die $!;
    t_put( "$d/about.md", "---\ntitle: About\nregister:\n  - sitemap.xml\n---\nAbout.\n" );
    return $d;
}

sub age { my ($p) = @_; my $old = time() - 100_000; utime $old, $old, $p; return }

# --- a stale registry is served at once and rebuilt afterwards ---------
{
    my $d    = site();
    my $file = "$d/lazysite/cache/registries/_root/sitemap.xml";
    make_path("$d/lazysite/cache/registries/_root");
    t_put( $file, "OLD-REGISTRY\n" );
    age($file);

    my $out = run_processor( $d, '/sitemap.xml' );
    like( $out, qr/OLD-REGISTRY/, 'the stale registry is what the request is served' );
    unlike( $out, qr/<urlset/, 'and the request did not rebuild it' );

    my $fresh = 0;
    for ( 1 .. 100 ) {
        if ( t_slurp($file) =~ /<urlset/ ) { $fresh = 1; last }
        sleep 0.1;
    }
    ok( $fresh, 'the registry was rebuilt afterwards, in the background' );
    like( t_slurp($file), qr{/about}, 'with the site as it is now' );
}

# --- a registry that does not exist is built on first need -------------
{
    my $d   = site();
    my $out = run_processor( $d, '/sitemap.xml' );
    like( $out, qr/<urlset/, 'a missing registry is built for the request that needs it' );
    ok( -f "$d/lazysite/cache/registries/_root/sitemap.xml", 'and is kept' );
}

# --- two concurrent stale requests start one rebuild --------------------
{
    my $d = site();

    # Loaded FIRST: loading renders a page, and a render that finds a stale
    # registry starts the very rebuild this case is counting.
    load_processor($d);
    my $file = "$d/lazysite/cache/registries/_root/sitemap.xml";
    make_path("$d/lazysite/cache/registries/_root");
    t_put( $file, "OLD\n" );
    age($file);
    my $tally = "$d/rebuilds";
    {
        no warnings 'redefine';
        no strict 'refs';
        *{'main::update_registries'} = sub {
            t_put( $tally, t_slurp($tally) . "x" );
            sleep 0.6;    # a real window for the second request to arrive in
            t_put( $file, "FRESH\n" );
            return;
        };
    }
    my $first  = main::_schedule_registry_rebuild($file);
    my $second = main::_schedule_registry_rebuild($file);
    ok( $first && $second, 'both requests were told a rebuild is in hand' );

    for ( 1 .. 100 ) { last if t_slurp($file) eq "FRESH\n"; sleep 0.1 }
    sleep 0.3;
    is( length t_slurp($tally), 1, 'and exactly one rebuild ran' );
}

done_testing;

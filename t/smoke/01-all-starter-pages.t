#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor);

# Render every starter/*.md file (excluding those requiring auth or
# that are HTTP error templates) and verify 200 OK.

my $root    = repo_root();
my $starter = "$root/starter";
ok( -d $starter, 'starter directory exists' ) or do { done_testing; exit };

# Copy starter into a tempdir so we don't pollute the repo with .html caches.
my $docroot = tempdir( CLEANUP => 1 );
system( "cp", "-r", "$starter/.", $docroot );
make_path("$docroot/lazysite/cache") unless -d "$docroot/lazysite/cache";

# Seed lazysite.conf from example if missing.
unless ( -f "$docroot/lazysite/lazysite.conf" ) {
    if ( -f "$docroot/lazysite.conf.example" ) {
        system( "cp", "$docroot/lazysite.conf.example", "$docroot/lazysite/lazysite.conf" );
    }
}
# Seed nav.conf from example if missing.
unless ( -f "$docroot/lazysite/nav.conf" ) {
    if ( -f "$docroot/nav.conf.example" ) {
        system( "cp", "$docroot/nav.conf.example", "$docroot/lazysite/nav.conf" );
    }
}

# Collect .md files to render.
my @md;
find(
    sub {
        return unless /\.md\z/;
        my $full = $File::Find::name;
        my $rel  = $full;
        $rel =~ s{^\Q$docroot\E/}{};

        # Skip system paths and error page templates.
        return if $rel =~ m{^lazysite/};
        return if $rel =~ m{^(?:402|403|404)\.md\z};
        # Manager pages enforce auth/groups → different flow.
        return if $rel =~ m{^manager/};

        push @md, $full;
    },
    $docroot
);

ok( scalar @md > 0, 'starter has renderable .md pages' );

for my $file ( sort @md ) {
    my $uri = $file;
    $uri =~ s{^\Q$docroot\E}{};
    $uri =~ s{\.md\z}{};
    $uri =~ s{/index\z}{/};

    # Clear any co-located cache.
    ( my $cache = $file ) =~ s{\.md\z}{.html};
    unlink $cache if -f $cache;

    my $out = run_processor( $docroot, $uri );
    # Accept any non-5xx response: 200 (happy path), 302 (redirect, e.g.
    # auth bounce), or 402 (payment-demo pages correctly signalling
    # payment required). What we're checking is "the processor doesn't
    # crash on any starter content".
    like( $out, qr/Status:\s*(?:200|302|402)/,
        "render: $uri → 200/302/402" );
}

done_testing();

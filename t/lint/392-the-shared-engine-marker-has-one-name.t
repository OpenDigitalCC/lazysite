#!/usr/bin/perl
# SM1361: THE SHARED-ENGINE MARKER HAS ONE NAME, written twice by necessity.
#
# The image writes a marker file at the engine's root. Lazysite::Extensions
# reads it to apply X1's shared rule (the engine's own payload path, or the
# site's own extensions dir), and install.pl reads it to lay a new site with
# --engine shared by default. install.pl loads no Lazysite module (SM767), so
# the name is a literal there. A drift would leave the loader and the
# installer disagreeing about whether a site is shared: the manager would list
# none of the image's extensions, or the installer would lay an engine copy
# that nothing runs. Pinned here, as t/lint/51 pins the private store's path.
#
# n795 (the restack): and a third reader, the FastCGI pool launcher (n791,
# ruling 203), which runs the engine's own processor for a site only on an
# engine carrying the marker, and the site's own everywhere else. It loads no
# Lazysite module either, so the name is a literal there too; a drift would
# have the pool refuse every site in the container (it would look for each
# site's own engine, which a shared-engine site does not hold).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
require Lazysite::Extensions;
my $name = do { no warnings 'once'; $Lazysite::Extensions::SHARED_MARK };
ok( defined $name && $name =~ /\A[A-Z][A-Z-]+\z/, "the loader's marker name ($name)" );

open my $fh, '<', "$root/install.pl" or die $!;
my $inst = do { local $/; <$fh> };
close $fh;
my @lit = $inst =~ m{"\$STAGE_DIR/([A-Z][A-Z-]+)"}g;
is_deeply( \@lit, [$name], 'install.pl reads the same name, once, at its payload root' );

open my $ph, '<', "$root/tools/lazysite-pool.pl" or die $!;
my $pool = do { local $/; <$ph> };
close $ph;
my @plit = $pool =~ m{"\$engine_root/([A-Z][A-Z-]+)"}g;
is_deeply( \@plit, [$name], 'the pool launcher reads the same name, once, at its engine root' );

done_testing();

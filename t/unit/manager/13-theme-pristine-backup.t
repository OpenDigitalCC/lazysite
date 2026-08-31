#!/usr/bin/perl
# SM176: switching away from a theme snapshots it only if it was EDITED since
# install. A pristine (unchanged) theme must not spawn a backup; an edited one
# must; a theme with no recorded baseline keeps the pre-SM176 fallback (backs up).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
# ../../lib from t/unit/manager is t/lib, the TEST library. The engine's own
# lib reaches @INC from the gate's `prove -l`, so this file is fine there and
# died only when run on its own - which is exactly when someone is debugging
# it. Naming both costs nothing and removes the trap.
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes   ();
use Lazysite::Manager::Artifact ();

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub backups { my ( $parent, $name ) = @_; return grep { -d } glob("$parent/$name-backup-*") }

my $parent = tempdir( CLEANUP => 1 );

# A freshly-installed theme: content + a recorded pristine baseline.
make_path("$parent/fresh");
spit( "$parent/fresh/theme.json", '{"name":"fresh","layouts":["base"]}' );
spit( "$parent/fresh/style.css",  "body{}\n" );
Lazysite::Manager::Themes::_write_pristine( $parent, 'fresh',
    Lazysite::Manager::Artifact::_artifact_digest("$parent/fresh") );

# Switching away from a pristine (unedited) theme: no backup.
Lazysite::Manager::Themes::_snapshot_artifact( $parent, 'fresh' );
is( scalar( backups( $parent, 'fresh' ) ), 0,
    'a pristine, unedited theme is NOT backed up when you switch away' );

# The operator edits the theme; switching away now DOES back it up.
spit( "$parent/fresh/style.css", "body { color: red }\n" );
Lazysite::Manager::Themes::_snapshot_artifact( $parent, 'fresh' );
is( scalar( backups( $parent, 'fresh' ) ), 1, 'an edited theme IS backed up' );

# A theme with no baseline (installed before SM176) keeps the old behaviour.
make_path("$parent/legacy");
spit( "$parent/legacy/theme.json", '{"name":"legacy","layouts":["base"]}' );
Lazysite::Manager::Themes::_snapshot_artifact( $parent, 'legacy' );
is( scalar( backups( $parent, 'legacy' ) ), 1,
    'a theme with no baseline still backs up (pre-SM176 fallback)' );

done_testing();

#!/usr/bin/perl
# Regression: concurrent lazysite.conf writers must not truncate or lose keys.
#
# The Services page saves every changed key as its own config-set, fired in
# parallel (Promise.all), so several processes reach _write_conf_key's
# read-modify-write at once. The old writer opened the conf with '>' (truncating
# it up front, non-atomically), so a concurrent reader could catch the empty file
# mid-write and write back only its own key - truncating lazysite.conf to a
# single line and wiping every other setting (observed in the field, 2026-07-21).
#
# The fix: _write_conf_key takes an exclusive flock across the read-modify-write
# (serialising writers), and write_file_checked writes a temp sibling then
# rename(2)s it over the target (so a reader always sees a complete file). This
# test drives many concurrent writers against one conf and asserts BOTH
# invariants: no key is ever lost, and a reader never observes a truncated file.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# A standalone writer process: set DOCROOT, hammer one key with $iters updates.
my $work   = tempdir( CLEANUP => 1 );
my $writer = "$work/writer.pl";
open my $wf, '>', $writer or die $!;
print $wf <<'CHILD';
use strict;
use warnings;
use lib $ENV{LZS_LIB};
use Lazysite::Manager::Common qw(_write_conf_key);
my ( $docroot, $key, $iters ) = @ARGV;
$Lazysite::Manager::Common::DOCROOT = $docroot;
_write_conf_key( $key, "v$_" ) for 1 .. $iters;
CHILD
close $wf;

# Seed a conf with several keys whose survival we assert afterwards.
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");
my @seed = (
    [ 'site_name'      => 'Seed Site' ],
    [ 'layout'         => 'base' ],
    [ 'theme'          => 'plain' ],
    [ 'nav_file'       => 'lazysite/nav.conf' ],
    [ 'update_channel' => 'stable' ],
);
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf join( '', map { "$_->[0]: $_->[1]\n" } @seed );
close $cf;

my $K     = 12;    # concurrent writers
my $ITERS = 20;    # updates each, to widen the race window
my @kids;
for my $id ( 0 .. $K - 1 ) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        # Clean env: strip coverage instrumentation so K children don't contend
        # on cover_db (the writer code is covered by 17-config-set.t).
        %ENV = ( PATH => $ENV{PATH} // '/usr/bin:/bin', LZS_LIB => "$root/lib" );
        exec( $^X, $writer, $d, "svc$id", $ITERS ) or die "exec: $!";
    }
    push @kids, $pid;
}

# While the writers run, read the conf many times and assert it is NEVER
# truncated: the seed key site_name (which no child touches) must be present on
# every single read. A single miss is the truncation bug.
my $reads           = 0;
my $truncated_reads = 0;
while ( grep { waitpid( $_, 1 ) == 0 } @kids ) {    # 1 = WNOHANG: still running
    for ( 1 .. 40 ) {
        $reads++;
        open my $rf, '<', "$d/lazysite/lazysite.conf" or next;
        my $c = do { local $/; <$rf> };
        close $rf;
        $truncated_reads++ if $c !~ /^site_name: Seed Site$/m;
    }
}
waitpid( $_, 0 ) for @kids;                         # reap any stragglers

cmp_ok( $reads, '>', 0, "reader observed the conf mid-flight ($reads reads)" );
is( $truncated_reads, 0,
    'a concurrent reader never saw a truncated conf (site_name always present)' );

# Final state: every seed key survived with its value, and every writer's key
# landed. Truncation would have dropped most of these.
open my $final, '<', "$d/lazysite/lazysite.conf" or die $!;
my $conf = do { local $/; <$final> };
close $final;

for my $s (@seed) {
    like( $conf, qr/^\Q$s->[0]\E: \Q$s->[1]\E$/m,
        "seed key $s->[0] survived concurrent writes" );
}
for my $id ( 0 .. $K - 1 ) {
    like( $conf, qr/^svc$id: v\d+$/m, "writer key svc$id present after the race" );
}

# No key appears twice (a lost-lock could append a duplicate rather than replace).
my %count;
$count{$1}++ while $conf =~ /^(\w+):/mg;
my @dupes = grep { $count{$_} > 1 } keys %count;
is( "@dupes", '', 'no key was duplicated (replace-in-place held under contention)' );

done_testing();

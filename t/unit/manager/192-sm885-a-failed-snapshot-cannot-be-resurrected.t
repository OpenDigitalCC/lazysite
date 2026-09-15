#!/usr/bin/perl
# SM885: a failed backup must not leave a tarball the listing calls a snapshot.
#
# t/unit/manager/64 already asserts the refusal path removes what it claimed,
# and that assertion is correct - the unlink works. What beat it is a process
# this code never waits for: `tar czf` forks gzip, tar fails early, we reap
# TAR, and the orphaned compressor recreates the name after the unlink. In the
# field that is a 20-byte empty gzip stream sitting in the Backups listing as a
# snapshot that restores nothing.
#
# WHY THIS TEST FAKES tar RATHER THAN RACING IT. The real defect needs the host
# under load - measured at 7 of 40 runs at concurrency 8 and 0 of 300 serially
# - so a test that drove real tar would be the flaky test that started this,
# reproducing the bug a few times in forty. The fake owns the timing instead:
# it writes the archive path, forks a child that recreates that path after the
# parent is gone, and exits 2. That is the orphan, made punctual. The
# assertion is then deterministic and the failure it guards is exact.
#
# WHAT IT THEREFORE DOES NOT PROVE: that real GNU tar forks a compressor which
# behaves this way. That was established separately by measurement, including a
# control arm (`tar cf`, no compressor, 0 of 360), and is recorded in the
# filing. This test pins the ENGINE's side of the contract - that nothing an
# orphaned writer does to the path tar was given can put a file in the listing.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Time::HiRes qw(sleep);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Backups ();

# A stand-in for `tar czf <out> ...` that fails the way a bad -C fails, and
# leaves behind exactly what an orphaned gzip leaves behind: a writer that
# outlives the process we wait for.
sub fake_tar_dir {
    my $bin = tempdir( CLEANUP => 1 );
    open my $fh, '>', "$bin/tar" or die $!;
    print {$fh} <<'PERL';
#!/usr/bin/perl
use strict;
use warnings;
# argv is: czf <archive> -C <docroot> ...
my $out = $ARGV[1];
open my $o, '>', $out or exit 2;   # tar creates the archive, then hits the -C
close $o;
my $pid = fork();
if ( defined $pid && !$pid ) {
    # THE ORPHAN. Outlives its parent, still holding the job of producing the
    # output, and recreates the path by name after the engine has given up.
    close STDIN; close STDOUT; close STDERR;
    select undef, undef, undef, 0.30;
    if ( open my $g, '>', $out ) { print {$g} "\x1f\x8b" . ( "\0" x 18 ); close $g; }
    exit 0;
}
print STDERR "tar: /nonexistent: Cannot open: No such file or directory\n";
exit 2;
PERL
    close $fh;
    chmod oct('0755'), "$bin/tar" or die $!;
    return $bin;
}

# SM754: through the helper, so the docroot sits a level down and every sibling
# the engine writes (the private store at <docroot>-lazysite-private) lands
# inside what CLEANUP removes.
my $d = site_tempdir();
make_path("$d/lazysite/backups");
my $bin = fake_tar_dir();

# Localised for the whole file, not just the call: action_backup_list below
# reads LAZYSITE_DIR too, and scoping it to the create alone pointed the
# listing at the real project tree - which answered, and looked like a
# failure of the fix rather than of the test.
local $Lazysite::Manager::Backups::DOCROOT      = "$d/does-not-exist";
local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

my $r;
{
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    $r = Lazysite::Manager::Backups::action_backup_create('manual');
}

ok( !$r->{ok}, 'the snapshot is refused' );
like( $r->{reason} // q{}, qr/tar exited/, 'and it says tar failed' );

# Wait past the orphan. Before SM885 the engine handed tar the CLAIMED name, so
# this is the moment the refused snapshot reappeared in the listing.
sleep 0.75;

opendir my $dh, "$d/lazysite/backups" or die $!;
my @left = grep { !/\A\.\.?\z/ } readdir $dh;
closedir $dh;

is( scalar(@left), 0,
    'nothing survives in backups/ - not the claimed name, not a staging '
        . 'directory, and not the file the orphaned writer recreated' )
    or diag( "left behind: " . join( ', ', @left ) );

my $list = Lazysite::Manager::Backups::action_backup_list();
is_deeply( $list->{backups}, [],
    'and the listing offers no snapshot to restore' );

done_testing();

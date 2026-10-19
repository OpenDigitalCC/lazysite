#!/usr/bin/perl
# SM1195: `lazysite check --fix` reports "fixed" only when the change TOOK.
#
# Field report (edge, 2026-10-19, run as ispadmin, who is not in www-data):
#
#   fixed: chmod 2775 .../public_html (was 2751)
#   fixed: chmod 2770 .../lazysite/git (was 2775)
#   fixed: chmod 2770 .../lazysite/git (was 0770)
#   fixed: chmod 2770 .../lazysite/git (was 0770)
#   (--fix applied 4 change(s); this report reflects the post-fix state)
#   [ FAIL ] lazysite/git is 0770 (group=www-data) - ... no setgid
#
# Linux clears S_ISGID on chmod when the caller is not root and not in the
# file's group; chmod still returns success. The tool believed the return value,
# said "fixed", and applied the same change on every pass. A second real user is
# not available to a test, so a chmod that returns true while dropping 02000 is
# simulated by wrapping CORE::GLOBAL::chmod (loaded with -M before the tool).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

my $d0 = site_tempdir();
my $shim_dir = "$d0/shim";
make_path($shim_dir);
open my $sh, '>', "$shim_dir/DropSetgid.pm" or die $!;
print {$sh} <<'PM';
package DropSetgid;
use strict; use warnings;
BEGIN {
    *CORE::GLOBAL::chmod = sub {
        my ( $mode, @f ) = @_;
        if ( open my $l, '>>', $ENV{SHIM_LOG} ) {
            printf {$l} "%04o %s\n", $mode, $_ for @f;
            close $l;
        }
        return 0 if ( $ENV{SHIM_MODE} // '' ) eq 'refuse';
        $mode &= ~02000 if ( $ENV{SHIM_MODE} // '' ) eq 'drop';
        return CORE::chmod( $mode, @f );
    };
}
1;
PM
close $sh;

# A docroot at 0755 whose install state declares 2775: queued for --fix.
sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite");
    chmod 0755, $d;
    open my $o, '>', "$d/lazysite/.install-state.json" or die $!;
    print {$o} qq({"dirs":{"$d":"2775"}}\n);
    close $o;
    return $d;
}

sub run {
    my ( $mode, $d ) = @_;
    my $log = "$d.log";
    unlink $log;
    local $ENV{SHIM_MODE}  = $mode;
    local $ENV{SHIM_LOG}   = $log;
    local $ENV{LAZYSITE_CHECK_GROUPS} = '0';    # the caller is in no group of the path's
    open my $fh, '-|', $^X, "-I$shim_dir", '-MDropSetgid', $tool, '--docroot', $d, '--fix'
        or return ( '', 0 );
    my $out = do { local $/; <$fh> };
    close $fh;
    my $n = 0;
    if ( open my $l, '<', $log ) { $n++ while <$l>; close $l }
    return ( $out // '', $n );
}

# --- 1. a chmod that takes is still "fixed" ---------------------------------
{
    my $d = site();
    my ( $out, $n ) = run( 'pass', $d );
    like( $out, qr/^fixed: chmod 2775 \Q$d\E \(was 0755\)/m, 'a chmod that took is reported fixed' );
    unlike( $out, qr/not fixed/, 'and nothing is reported not fixed' );
    like( $out, qr/--fix applied 1 change\(s\)(?!.*not)/, 'the count line says one applied' );
    is( ( stat $d )[2] & 07777, 02775, 'the mode is really 2775' );
}

# --- 2. a chmod that returns true and drops setgid is NOT "fixed" -----------
{
    my $d = site();
    my ( $out, $n ) = run( 'drop', $d );
    unlike( $out, qr/^fixed: chmod 2775/m, 'a chmod whose setgid bit was dropped is not reported fixed' );
    like( $out, qr/^not fixed: chmod 2775 \Q$d\E \(was 0755, now 0775\)/m, 'it is reported not fixed, with the mode that resulted' );
    like( $out, qr/setgid bit was dropped because \w+ is not in group/, 'the reason names the setgid rule' );
    like( $out, qr/sudo chmod 2775 '\Q$d\E'/, 'and the root command is given' );
    like( $out, qr/applied 0 change\(s\), 1 not taken/, 'the count line distinguishes applied from not taken' );
    is( $n, 1, 'the same change is attempted once in the run (not once a pass)' );
}

# --- 3. a refused chmod is not fixed either, and says so --------------------
{
    my $d = site();
    my ( $out, $n ) = run( 'refuse', $d );
    like( $out, qr/^not fixed: chmod 2775 \Q$d\E.*refused/m, 'a refused chmod is reported not fixed' );
    like( $out, qr/sudo chmod 2775 '\Q$d\E'/, 'with the root command' );
    is( $n, 1, 'attempted once' );
}

done_testing();

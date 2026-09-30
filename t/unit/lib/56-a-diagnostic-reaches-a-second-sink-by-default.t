#!/usr/bin/perl
# SM932, ruled 2026-09-30: diagnostics forwarding is ON by default, at WARN and
# above, because log_event's only unconditional sink was `print STDERR` and on a
# FastCGI stack that reaches nobody. An operator grepped error_log through four
# failing submissions and found nothing while the same code from a terminal
# printed the cause at once.
#
# What this file pins, and every case is a state that was NOT distinguishable
# before:
#   1  a site with NO forwarding config forwards WARN and ERROR, and not INFO
#   2  `forward_diagnostics: off` still forwards nothing               (the escape)
#   3  `forward_diagnostics: on` still forwards EVERY level  (no configured install moves)
#   4  an explicit level is honoured in both directions
#   5  an UNREADABLE lazysite.conf is reported, not silent, and still forwards
#   6  an UNRECOGNISED value is reported and falls back to the default
#   7  the audit stream is untouched by the diagnostics threshold
#
# Uses the LAZYSITE_SYSLOG_DUMP test seam (test-only): "<priority> <line>" is
# appended to a file instead of calling syslog. The forwarding config is cached
# per process, so each case runs in a fresh subprocess.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();

# $work only ever holds probe scripts and dump files - never a docroot - so a
# bare tempdir is right for it. The SITES below come from site_tempdir, which is
# what lint 118 is about: a docroot handed to the engine must sit under a
# site/public_html shape, not at the root of a tempdir.
my $work = tempdir( CLEANUP => 1 );
my $n    = 0;

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# A site tree with an optional forward_diagnostics line. Returns the lazysite dir.
sub site_with {
    my ($conf_line) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: t\n";
    print {$cf} "$conf_line\n" if defined $conf_line;
    close $cf;
    return "$d/lazysite";
}

# Emit one line at each level from a fresh process and return ( dump, stderr ).
sub emit_all_levels {
    my ( $lzdir, %env ) = @_;
    my $dump  = "$work/dump-" . ++$n;
    my $probe = "$work/probe-$n.pl";
    open my $fh, '>', $probe or die $!;
    print {$fh} qq{use strict;
use warnings;
use lib "$root/lib";
use Lazysite::Audit ();
use Lazysite::Util qw(log_event);
\$Lazysite::Audit::LAZYSITE_DIR = "$lzdir";
log_event( 'DEBUG', 'ctx', 'a debug line' );
log_event( 'INFO',  'ctx', 'an info line' );
log_event( 'WARN',  'ctx', 'a warn line' );
log_event( 'ERROR', 'ctx', 'an error line' );
};
    close $fh;
    local %ENV = ( %ENV, LAZYSITE_SYSLOG_DUMP => $dump,
        LAZYSITE_LOG_LEVEL => 'DEBUG', %env );
    delete $ENV{LAZYSITE_FORWARD_DIAGNOSTICS}
        unless exists $env{LAZYSITE_FORWARD_DIAGNOSTICS};
    my $err = qx{$^X "$probe" 2>&1 1>/dev/null};
    return ( slurp($dump), $err );
}

# Which of the four levels reached the dump.
sub forwarded {
    my ($dump) = @_;
    return join ',', grep { $dump =~ /\Q$_\E/ } qw(debug info warn error);
}

# --- 1. the default: WARN and above, on a site that says nothing ---
{
    my ( $dump, $err ) = emit_all_levels( site_with(undef) );
    is( forwarded($dump), 'warn,error',
        'SM932: with no forward_diagnostics set, WARN and ERROR forward and INFO does not' );
    like( $dump, qr/^warning .*a warn line/m, 'WARN forwards at warning priority' );
    like( $dump, qr/^err .*an error line/m,   'ERROR forwards at err priority' );
    unlike( $dump, qr/an info line/, 'INFO is below the default threshold' );
    unlike( $err, qr/log forwarding failed|cannot read/,
        'a readable conf with no forwarding keys is not a complaint' );
}

# --- 2. off is still off: the escape hatch the default does not remove ---
{
    my ( $dump, $err ) = emit_all_levels( site_with('forward_diagnostics: off') );
    is( forwarded($dump), '', 'forward_diagnostics: off forwards nothing at any level' );
    ok( !length $dump, 'the dump file is empty, not merely missing the levels' );
}

# --- 3. on still means EVERY level, so no configured install changes ---
{
    my ( $dump, undef ) = emit_all_levels( site_with('forward_diagnostics: on') );
    is( forwarded($dump), 'debug,info,warn,error',
        'forward_diagnostics: on forwards every level, as it did before SM932' );
}

# --- 4. an explicit level, checked in BOTH directions ---
{
    my ( $dump, undef ) = emit_all_levels( site_with('forward_diagnostics: error') );
    is( forwarded($dump), 'error', 'forward_diagnostics: error forwards ERROR only' );
}
{
    my ( $dump, undef ) = emit_all_levels( site_with('forward_diagnostics: info') );
    is( forwarded($dump), 'info,warn,error',
        'forward_diagnostics: info forwards INFO and above, and not DEBUG' );
}

# --- 5. an unreadable conf is REPORTED, and forwarding still happens ---
# The defect SM932 names in the forwarding path itself: this read had no else
# branch, so a conf the process cannot open silently decided the answer. It
# cannot use cannot_read (log_event arrives here), so it reports at the end of
# _forward_conf behind its own once-per-process latch.
SKIP: {
    skip 'running as root: chmod 000 would not deny this process', 4 if $> == 0;
    my $lz = site_with('forward_diagnostics: on');
    chmod 0000, "$lz/lazysite.conf" or die "chmod: $!";
    my ( $dump, $err ) = emit_all_levels($lz);
    like( $err, qr/cannot read the log forwarding config/,
        'an unreadable forwarding config is reported, not absorbed' );
    like( $err, qr/\Q$lz\E\/lazysite\.conf/, 'the report names the file' );
    my @said = $err =~ /(cannot read the log forwarding config)/g;
    is( scalar @said, 1, 'reported once per process, not once per log line' );
    is( forwarded($dump), 'warn,error',
        'and the defaults still apply - an unreadable conf does not silence the engine' );
    chmod 0644, "$lz/lazysite.conf";
}

# --- 6. an unrecognised value is reported and falls back to the default ---
{
    my ( $dump, $err ) = emit_all_levels( site_with('forward_diagnostics: sometimes') );
    like( $err, qr/unrecognised forward_diagnostics value/,
        'a value the code cannot honour is named, not ignored' );
    like( $err, qr/error=sometimes/, 'the report quotes the offending value' );
    is( forwarded($dump), 'warn,error', 'and the default applies rather than silence' );
}

# --- 7. the diagnostics threshold does not touch the audit stream ---
# forward_audit is a boolean and stays OFF by default; it forwards at info
# priority, which is BELOW the diagnostics default, so a threshold applied to
# the wrong stream would silently stop audit forwarding for everyone who has it on.
{
    my $lz    = site_with('forward_audit: on');
    my $dump  = "$work/dump-audit";
    my $probe = "$work/probe-audit.pl";
    open my $fh, '>', $probe or die $!;
    print {$fh} qq{use strict;
use warnings;
use lib "$root/lib";
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$lz";
audit_log( 'alice', 'user-add', 'bob', '1.2.3.4', 'ok', 'cli' );
};
    close $fh;
    {
        local %ENV = ( %ENV, LAZYSITE_SYSLOG_DUMP => $dump );
        delete $ENV{LAZYSITE_FORWARD_AUDIT};
        delete $ENV{LAZYSITE_FORWARD_DIAGNOSTICS};
        qx{$^X "$probe" 2>&1 1>/dev/null};
    }
    like( slurp($dump), qr/^info .*\| user-add \|/m,
        'forward_audit: on still forwards the audit line at info, below the diag threshold' );
}

done_testing();

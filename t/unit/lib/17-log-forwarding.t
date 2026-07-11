#!/usr/bin/perl
# External log forwarding (the 'Logging & forwarding' plugin, log.pl):
# forward_audit sends each audit entry to syslog at info priority,
# forward_diagnostics sends log_event lines at their mapped priority, config
# comes from env override or a one-shot lazysite.conf peek, and forwarding
# failure never breaks the caller. Uses the LAZYSITE_SYSLOG_DUMP test seam
# (test-only): "<priority> <line>" is appended to a file instead of syslog.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# The forwarding config is cached per process, so each scenario runs in a
# fresh subprocess: write a probe script, run it, inspect the dump file.
my $work = tempdir( CLEANUP => 1 );
my $n    = 0;

sub run_probe {
    my ( $env, $body ) = @_;
    my $probe = "$work/probe-" . ++$n . '.pl';
    open my $fh, '>', $probe or die $!;
    print {$fh} "use strict;\nuse warnings;\nuse lib \"$root/lib\";\n$body";
    close $fh;
    local %ENV = ( %ENV, %$env );
    my $out = qx{$^X "$probe" 2>&1};
    return ( $? == 0, $out );
}

# --- audit forwarding via env override ---
{
    my $d    = tempdir( CLEANUP => 1 );
    my $dump = "$work/dump-audit";
    make_path("$d/lazysite/logs");
    my ( $ok, $out ) = run_probe(
        {
            LAZYSITE_FORWARD_AUDIT        => 'on',
            LAZYSITE_FORWARD_DIAGNOSTICS  => 'off',
            LAZYSITE_SYSLOG_DUMP          => $dump,
        },
        qq{
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
audit_log( 'alice', 'user-add', 'bob', '1.2.3.4', 'ok', 'cli' );
print "DONE\\n";
});
    ok( $ok, 'probe ran' );
    my $fwd = slurp($dump);
    like( $fwd, qr/^info .* \| alice \| user-add \| bob \| 1\.2\.3\.4 \| ok \| cli$/m,
        'audit entry forwarded as the pipe-format line at info priority' );
    my $disk = slurp("$d/lazysite/logs/audit.log");
    like( $disk, qr/\| user-add \|/, 'file append still happened (forwarding is a copy)' );
}

# --- audit forwarding OFF by default ---
{
    my $d    = tempdir( CLEANUP => 1 );
    my $dump = "$work/dump-off";
    make_path("$d/lazysite/logs");
    run_probe(
        { LAZYSITE_SYSLOG_DUMP => $dump },
        qq{
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
audit_log( 'alice', 'user-add', 'bob', '', 'ok', 'cli' );
});
    ok( !-s $dump, 'nothing forwarded when forward_audit is off (the default)' );
}

# --- diagnostics forwarding: mapped priorities ---
{
    my $dump = "$work/dump-diag";
    run_probe(
        {
            LAZYSITE_FORWARD_AUDIT       => 'off',
            LAZYSITE_FORWARD_DIAGNOSTICS => 'on',
            LAZYSITE_SYSLOG_DUMP         => $dump,
            LAZYSITE_LOG_LEVEL           => 'DEBUG',
        },
        q{
use Lazysite::Util qw(log_event);
log_event( 'WARN',  'ctx', 'careful now' );
log_event( 'ERROR', 'ctx', 'it broke' );
log_event( 'INFO',  'ctx', 'note' );
});
    my $fwd = slurp($dump);
    like( $fwd, qr/^warning .*careful now/m, 'WARN forwards at warning priority' );
    like( $fwd, qr/^err .*it broke/m,        'ERROR forwards at err priority' );
    like( $fwd, qr/^info .*note/m,           'INFO forwards at info priority' );
}

# --- config comes from the lazysite.conf peek (no env) ---
{
    my $d    = tempdir( CLEANUP => 1 );
    my $dump = "$work/dump-conf";
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: t\nforward_audit: on\nsyslog_facility: local3\n";
    close $cf;
    run_probe(
        { LAZYSITE_SYSLOG_DUMP => $dump },
        qq{
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
audit_log( 'alice', 'user-add', 'bob', '', 'ok', 'cli' );
});
    like( slurp($dump), qr/\| user-add \|/,
        'forward_audit read from lazysite.conf (the plugin config path)' );
}

# --- forwarding failure never breaks the caller, and WARNs once ---
{
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    my ( $ok, $out ) = run_probe(
        {
            LAZYSITE_FORWARD_AUDIT => 'on',
            LAZYSITE_SYSLOG_DUMP   => "$d/no-such-dir/dump",    # unwritable seam
        },
        qq{
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
audit_log( 'alice', 'user-add', 'bob', '', 'ok', 'cli' );
audit_log( 'alice', 'user-add', 'carol', '', 'ok', 'cli' );
print "SURVIVED\\n";
});
    ok( $ok, 'process survived a failing forward target' );
    like( $out, qr/SURVIVED/, 'audit_log returned normally' );
    like( $out, qr/log forwarding failed/, 'forwarding failure is WARNed' );
    my @warns = $out =~ /(log forwarding failed)/g;
    is( scalar @warns, 1, 'forwarding failure WARNs once per process' );
    my $disk = slurp("$d/lazysite/logs/audit.log");
    like( $disk, qr/carol/, 'file appends unaffected by the forwarding failure' );
}

done_testing();

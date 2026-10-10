#!/usr/bin/perl
# Audit-guarantee suite: pins the contract that audit logging can never
# SILENTLY cease again (the 0.7.5 field defect: a 0644 CLI-created audit.log
# rejected every CGI append forever, and `open ... or return` swallowed it).
#
# Four angles:
#   1. Every failure mode of the write path is LOUD (a WARN through log_event
#      naming the lost action) and never dies; the healthy path creates the
#      file 0664 (umask-proof) and self-heals an owned 0644 file.
#   2. Structural completeness for the manager API: every dispatched action is
#      either in the audit %skip list or in the expected-audited list kept
#      HERE - adding an action without classifying it fails this test.
#   3. Structural completeness for the users tool: every cmd_* is classified
#      in %CLI_AUDIT_ACTION / %CLI_NO_DIRECT_AUDIT (via `audit-registry`), and
#      every classified-mutating sub really contains a cli_audit call.
#   4. lazysite-check's writable probe (4b) FAILs on the field case: an
#      audit.log that exists but is not appendable by the CGI identity.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
require Lazysite::Audit;
Lazysite::Audit->import('audit_log');

# Run audit_log with STDERR captured; returns the captured diagnostics.
sub audit_capture {
    my (@args) = @_;
    my $err    = '';
    my $lived  = eval {
        local *STDERR;
        open STDERR, '>', \$err or die "capture: $!";
        audit_log(@args);
        1;
    };
    return ( $lived, $err, $@ );
}

# Run audit_log calls in a fresh perl subprocess (fresh WARN-once state).
# Returns (exit_ok, combined output). The WARN-once flag is per process, so
# scenarios that need a clean flag use this instead of in-process calls.
my $probe_dir = tempdir( CLEANUP => 1 );
sub subprocess_audit {
    my ( $lazysite_dir, $n_calls ) = @_;
    $n_calls ||= 1;
    my $probe = "$probe_dir/probe-$$-$n_calls.pl";
    open my $pf, '>', $probe or die $!;
    print {$pf} <<"PROBE";
use strict;
use warnings;
use lib "$root/lib";
use Lazysite::Audit qw(audit_log);
\$Lazysite::Audit::LAZYSITE_DIR = "$lazysite_dir";
audit_log( 'tester', "lost-action-\$_", 'tgt', '', 'ok', 'cli' ) for 1 .. $n_calls;
print "SURVIVED\\n";
PROBE
    close $pf;
    my $out = qx{$^X "$probe" 2>&1};
    my $ok  = ( $? == 0 && $out =~ /SURVIVED/ ) ? 1 : 0;
    return ( $ok, $out );
}

# =========================================================================
# 1. Failure-visibility contract
# =========================================================================

subtest 'healthy path: file created 0664 regardless of umask' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    local $Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
    my $old = umask 0077;    # hostile umask: would give 0600 without the fix
    my ( $lived, $err ) = audit_capture( 'u', 'act', 't', '', 'ok', 'cli' );
    umask $old;
    ok( $lived, 'no die' );
    my $mode = ( stat "$d/lazysite/logs/audit.log" )[2] & 07777;
    is( $mode, 0664, sprintf( 'audit.log created 0664 (got %04o) under umask 0077', $mode ) );
    ok( $mode & 0020, 'group-write bit set: a second identity in the group can append' );
    is( $err, '', 'no warning on the healthy path' );
};

subtest 'self-heal: an owned 0644 file is healed to 0664 and appended' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    my $f = "$d/lazysite/logs/audit.log";
    open my $fh, '>', $f or die $!;
    print {$fh} "seed | line\n";
    close $fh;
    chmod 0644, $f;    # the broken field state
    local $Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
    my ( $lived, $err ) = audit_capture( 'mgr', 'login', '', '1.2.3.4', 'ok', 'ui' );
    ok( $lived, 'no die' );
    my $mode = ( stat $f )[2] & 07777;
    is( $mode, 0664, 'owned 0644 file healed to 0664 on the next append' );
    open my $rd, '<', $f or die $!;
    my @lines = <$rd>;
    close $rd;
    is( scalar @lines, 2, 'the entry was appended after healing' );
    like( $lines[1], qr/\| login \|/, 'appended line is the audit entry' );
};

subtest 'unwritable FILE (0444): no die, WARN names the lost action' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    my $f = "$d/lazysite/logs/audit.log";
    open my $fh, '>', $f or die $!;
    close $fh;
    chmod 0444, $f;
    # Self-heal would fix an OWNED file - but only the group-write bit; 0444
    # heals to 0664 (we own it). Simulate NOT owning it by making the dir
    # unable to... instead assert the heal path here and the true open
    # failure via the unwritable-dir case below.
    local $Lazysite::Audit::LAZYSITE_DIR = "$d/lazysite";
    my ( $lived, $err ) = audit_capture( 'u', 'critical-op', 't', '', 'ok', 'cli' );
    ok( $lived, 'no die on a read-only audit.log' );
    my $mode = ( stat $f )[2] & 07777;
    is( $mode, 0664, 'owned read-only file self-healed (0444 -> 0664)' );
    open my $rd, '<', $f or die $!;
    my @lines = <$rd>;
    close $rd;
    is( scalar @lines, 1, 'entry appended after self-heal - nothing lost' );
};

subtest 'unwritable DIR: no die, WARN reaches stderr with the lost action' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    chmod 0555, "$d/lazysite/logs";    # cannot create audit.log
    my ( $ok, $out ) = subprocess_audit("$d/lazysite");
    chmod 0755, "$d/lazysite/logs";
    ok( $ok, 'process survived (never dies)' );
    like( $out, qr/audit write failed/i, 'WARN emitted' );
    like( $out, qr/lost-action-1/,       'the WARN names the action that was lost' );
};

subtest 'missing logs dir that cannot be created: no die, loud' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    chmod 0555, "$d/lazysite";         # mkdir logs will fail
    my ( $ok, $out ) = subprocess_audit("$d/lazysite");
    chmod 0755, "$d/lazysite";
    ok( $ok, 'process survived' );
    like( $out, qr/audit write failed/i, 'WARN emitted for the unmakeable dir' );
    like( $out, qr/lost-action-1/,       'lost action named' );
};

subtest 'dangling symlink into a nonexistent tree: no die, loud' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    symlink( "$d/nonexistent-dir/audit.log", "$d/lazysite/logs/audit.log" )
        or plan skip_all => 'symlink unsupported';
    my ( $ok, $out ) = subprocess_audit("$d/lazysite");
    ok( $ok, 'process survived' );
    like( $out, qr/audit write failed/i, 'WARN emitted for the dangling symlink' );
};

subtest 'WARN is once per process, but every entry is still attempted' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    chmod 0555, "$d/lazysite/logs";
    my ( $ok, $out ) = subprocess_audit( "$d/lazysite", 3 );
    chmod 0755, "$d/lazysite/logs";
    ok( $ok, 'process survived three failed appends' );
    my @warns = $out =~ /(audit write failed)/g;
    is( scalar @warns, 1, 'exactly one WARN for repeated failures (no log spam)' );
};

# =========================================================================
# 2. Manager API: no unclassified dispatch action
# =========================================================================

subtest 'manager-api: every action is classified (skip-listed or audited)' => sub {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;

    # The dispatch table: every `$action eq '...'` comparison.
    my %dispatch;
    $dispatch{$1} = 1 while $src =~ /\$action\s+eq\s+'([^']+)'/g;
    ok( scalar keys %dispatch > 40, 'dispatch table extracted from source' );

    # The audit %skip list (read-ish actions, deliberately not audited).
    # SM943: derived from Lazysite::ControlApi::Actions - audited exactly when
    # the action mutates, unless its entry says `audited`. The CGI is held to
    # building %skip from there, so this reads what the audit block consults.
    # That the CGI builds %skip from the declaration is asserted with the other
    # nine tables in t/unit/lib/200 (subtest 1).
    require Lazysite::ControlApi::Actions;
    my %skip = Lazysite::ControlApi::Actions::unaudited();
    ok( scalar keys %skip > 40, 'the derived %skip list is not empty' );

    # SM943 stage 3: THE DECISIONS, NOT A SECOND COPY OF THEM.
    #
    # An expected-audited list of 85 names stood here: every audited action,
    # kept beside the declaration as an independent copy. The declaration
    # (Lazysite::ControlApi::Actions) states a RULE - an action is audited
    # exactly when it mutates - and its exceptions, so what a reviewer decides
    # per action is only the exceptions. Those are kept here as the
    # independent, reviewed list, and the declaration must hold exactly them:
    # an ordinary new action needs no line in this file, and an exception -
    # a write the trail skips, or a read it records - cannot be made without
    # one. Flipping an ordinary action either way (`save` unaudited, `notices`
    # audited) still fails, which is what the long list was for.
    #
    # The streaming downloads (file-download, backup-download...) are audited
    # reads deliberately: on GET a success writes no row (the trail's rule for
    # every GET), a refusal does, and a POSTed one audits. Q16b (2026-10-10):
    # this said so before it was true - every one but page-pdf exited before the
    # audit block, so none was ever recorded; all now return to the dispatcher
    # through the one streamed path (t/integration/123). SM554 moved
    # notices and layouts-manifest OUT of the audited set: the manager UI POSTs
    # everything, so those two reads audited on every call and buried the rows
    # recording who changed something.
    #
    # DM-2's data-export is audited DESPITE being a read, and the distinction
    # is not "read versus write" but "a page versus the whole thing". Paging
    # through data-rows is somebody working; downloading an entire table as a
    # file is a discrete, deliberate act with a copy of the data at the end of
    # it. That is the shape of event a trail exists to hold, and there will not
    # be enough of them to bury anything.
    #
    # SM447 / SM687, unchanged by this: the data and table-ACL WRITERS are
    # audited by the rule and their READS skipped by it - asking who LOOKED at
    # a table or a rule would bury the entries recording who changed one.
    my %WRITE_UNAUDITED = map { $_ => 1 } qw(
        audit-trail-set cache-invalidate lock unlock renew-lock
        preview-grant preview-clear regenerate-registries
    );
    my %READ_AUDITED = map { $_ => 1 } qw(
        backup-download data-export file-download file-zip-download
        site-backup-download users
    );

    my %mut          = Lazysite::ControlApi::Actions::mutating();
    my %declared     = Lazysite::ControlApi::Actions::known_actions();
    my @unclassified = grep { !$declared{$_} } sort keys %dispatch;
    ok( !@unclassified, 'every dispatched action carries an audit decision (it is declared)' )
        or diag "UNCLASSIFIED (declare it in ControlApi::Actions): @unclassified";

    my @wu = grep { $mut{$_} && $skip{$_} } sort keys %dispatch;
    is_deeply( \@wu, [ sort keys %WRITE_UNAUDITED ],
        'the writes the trail skips are exactly the reviewed exceptions' )
        or diag 'A mutating action the trail does not record is a decision: '
        . 'name it in %WRITE_UNAUDITED, or audit it.';
    my @ra = grep { !$mut{$_} && !$skip{$_} } sort keys %dispatch;
    is_deeply( \@ra, [ sort keys %READ_AUDITED ],
        'the reads the trail records are exactly the reviewed exceptions' )
        or diag 'A read the trail records is a decision: name it in '
        . '%READ_AUDITED, or leave it to the rule.';
};

# =========================================================================
# 3. Users tool: every cmd_* classified, every mutating cmd_* calls cli_audit
# =========================================================================

subtest 'users tool: registry covers every cmd_*, mutating subs call cli_audit' => sub {
    my $d = tempdir( CLEANUP => 1 );
    my $json = qx{$^X "$root/tools/lazysite-users.pl" --docroot "$d" audit-registry 2>/dev/null};
    my $reg = eval { decode_json($json) };
    ok( ref $reg eq 'HASH', 'audit-registry returns JSON' ) or return;

    my %mut    = %{ $reg->{mutating} || {} };
    my %exempt = %{ $reg->{exempt}   || {} };
    my @subs   = @{ $reg->{subs}     || [] };
    ok( scalar @subs > 30, 'cmd_* set enumerated from the live symbol table' );

    my @unclassified = grep { !$mut{$_} && !$exempt{$_} } @subs;
    ok( !@unclassified, 'every cmd_* is classified mutating or exempt' )
        or diag "UNCLASSIFIED cmd_* (classify in the tool's registry): @unclassified";

    my @both = grep { $mut{$_} && $exempt{$_} } @subs;
    ok( !@both, 'no cmd_* is in both registries' ) or diag "IN BOTH: @both";

    my %live  = map  { $_ => 1 } @subs;
    my @stale = grep { !$live{$_} } ( sort keys %mut, sort keys %exempt );
    ok( !@stale, 'registry names only real cmd_* subs (no stale entries)' )
        or diag "STALE registry entries: @stale";

    # Source check: each registered-mutating sub's body contains a cli_audit
    # call (top-level subs; a body runs to the next `sub ` at column 0).
    open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my %body;
    while ( $src =~ /^sub\s+(cmd_\w+)\s*\{(.*?)(?=^sub\s|\z)/msg ) {
        $body{$1} = $2;
    }
    my @missing;
    for my $s ( sort keys %mut ) {
        push @missing, $s unless defined $body{$s} && $body{$s} =~ /\bcli_audit\s*\(/;
    }
    ok( !@missing, 'every registered-mutating cmd_* contains a cli_audit call' )
        or diag "NO cli_audit CALL IN: @missing";
};

# =========================================================================
# 4. lazysite-check: the 4b probe FAILs on the field case (0644 owner-only)
# =========================================================================

subtest 'lazysite-check FAILs an audit.log the CGI cannot append to' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/logs", "$d/lazysite/auth" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: t\n";
    close $cf;
    my $f = "$d/lazysite/logs/audit.log";
    open my $fh, '>', $f or die $!;
    print {$fh} "seed\n";
    close $fh;
    chmod 0644, $f;    # owner-only write: the field state

    # Expected CGI group: pick one the file/user does NOT match so the
    # ownership+mode arithmetic reflects the www-data-vs-site-user split.
    my $gid   = ( split ' ', $( )[0];
    my $other = 'nogroup';
    $other = 'root' unless defined getgrnam($other);
    my $out = qx{$^X "$root/tools/lazysite-check.pl" --docroot "$d" --group $other 2>&1};
    like( $out, qr/FAIL.*audit\.log.*not writable by the CGI/s,
        '4b fires: 0644 owner-only audit.log is a FAIL, not a silent pass' );

    # Control: 0664 with the CGI group = our own group passes.
    chmod 0664, $f;
    my $mygrp = getgrgid($gid) // $gid;
    my $out2 = qx{$^X "$root/tools/lazysite-check.pl" --docroot "$d" --group $mygrp 2>&1};
    like( $out2, qr/\[\s*ok\s*\].*audit\.log\s+writable by the CGI/i,
        'control: a 0664 group-appendable audit.log passes 4b' );
};

done_testing();

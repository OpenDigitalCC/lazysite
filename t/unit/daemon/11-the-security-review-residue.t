#!/usr/bin/perl
# The residue of the 0.13.8 daemon review: SM787, SM788, SM789 and SM791.
# Four small fixes, each of them a case where the code and its own stated
# intention had drifted apart.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

use Lazysite::Daemon::Service::Scheduler ();
use Lazysite::Daemon::Supervisor         ();

# SM787: THE FAIL-OPEN PROMISE HELD FOR ONE SHAPE OF CORRUPTION OUT OF TWO.
# The module says a corrupt record "reads as empty - every job due at once -
# which is the safe direction". True for a TOTAL parse failure. A record that
# is valid JSON with a top-level object and a SCALAR job value passed the
# guard and then died in tick, every tick, forever - because _write_runs only
# runs when a job completed, so nothing ever repaired the file, and no remote
# surface can read the system tree to say why.
subtest 'structural corruption is fail-open, like the total kind' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/daemon");
    my $f = "$d/lazysite/daemon/scheduler-runs.json";

    my $write = sub {
        open my $fh, '>', $f or die $!;
        print {$fh} $_[0];
        close $fh;
    };

    $write->('["not","a","hash"]');
    my $r = Lazysite::Daemon::Service::Scheduler::_read_runs($d);
    is_deeply( $r, {}, 'the DOCUMENTED case still reads as empty' );

    # The case that killed the tick.
    $write->('{"stats-rollup":"boom","sessions-sweep":{"last_run":100}}');
    $r = Lazysite::Daemon::Service::Scheduler::_read_runs($d);
    ok( !exists $r->{'stats-rollup'},
        'a job entry that is not a job record is dropped, so it reads as never run' );
    is( $r->{'sessions-sweep'}{last_run}, 100,
        'and the entries that ARE records are untouched - one bad line does not '
            . 'discard the record' );

    # The proof that it no longer dies: the read is what tick dereferences.
    my $last = eval { ( ref $r->{'stats-rollup'} eq 'HASH' ? $r->{'stats-rollup'}{last_run} : 0 ) // 0 };
    is( $last, 0, 'and tick can read it without dying' ) or diag $@;
};

subtest 'a last_run in the future does not silently suppress a job' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/daemon");
    open my $fh, '>', "$d/lazysite/daemon/scheduler-runs.json" or die $!;
    # The record is same-uid-writable, so a future stamp is reachable, and it
    # keeps `$now - $last` negative for as long as it says.
    print {$fh} encode_json( { 'daemon-heartbeat' => { last_run => time + 10_000_000 } } );
    close $fh;
    my $runs = Lazysite::Daemon::Service::Scheduler::_read_runs($d);
    is( $runs->{'daemon-heartbeat'}{last_run} > time, 1,
        'the stamp is read as stored - the reader does not rewrite the file' );
    # tick's own normalisation is what refuses it; assert the rule it applies.
    my $src = do {
        open my $s, '<', repo_root() . '/lib/Lazysite/Daemon/Service/Scheduler.pm' or die $!;
        local $/;
        <$s>;
    };
    like( $src, qr/\$last = 0 if \$last !~.*\|\| \$last > \$now;/,
        'tick treats a non-numeric or FUTURE stamp as never run - an occasional '
            . 'harmless re-run beats a job that never runs and says nothing' );
};

# SM788: the comment said "everything after the last )" and the code took the
# first. Anchoring earlier leaves MORE fields, never fewer, so the value was
# wrong rather than absent - which means _is_ours failed CLOSED, not open.
subtest 'the start-time parse reads the field its comment names' => sub {
    my $stat = '1234 (x) 9 9 9 9 9) S 1 1 1 0 -1 4194560 100 0 0 0 1 2 3 4 20 0 1 0 '
        . "209152295 12345 678\n";
    my $li = rindex( $stat, ')' );
    my @f  = split ' ', substr( $stat, $li + 1 );
    is( $f[19], '209152295', 'the fixture really does carry field 22 after the LAST )' );

    my ($old) = $stat =~ /\)\s+(.*)\z/s;
    my @o     = split /\s+/, $old;
    isnt( $o[19], '209152295',
        'and the old leftmost-paren parse read a different field entirely' );

    my $src = do {
        open my $s, '<', repo_root() . '/lib/Lazysite/Daemon/Supervisor.pm' or die $!;
        local $/;
        <$s>;
    };
    my ($sub) = $src =~ /(sub _start_ticks \{.*?\n\})/s;
    ok( $sub, '_start_ticks was found' ) or return;
    like( $sub, qr/rindex\( \$line, '\)' \)/, 'it parses from the last )' );
    # Checked against the CODE, not the whole sub: the comment quotes the old
    # regex on purpose, to say what it used to do, so a naive search for that
    # text finds the explanation and calls it the defect.
    ( my $code = $sub ) =~ s/^\s*#.*$//mg;
    unlike( $code, qr/\$line =~/,
        'and no longer matches a regex against the stat line at all' );
};

# SM789: flock binds the inode, so a lock survives its file being unlinked -
# and a second supervisor opening a NEW file at the same path locks it too.
subtest 'the supervisor lock holds the path, not just the inode' => sub {
    my $src = do {
        open my $s, '<', repo_root() . '/lib/Lazysite/Daemon/Supervisor.pm' or die $!;
        local $/;
        <$s>;
    };
    my ($sub) = $src =~ /(sub _acquire_lock \{.*?\n\})/s;
    ok( $sub, '_acquire_lock was found' ) or return;
    like( $sub, qr/stat \$fh/,   'it stats the locked descriptor' );
    like( $sub, qr/stat \$path/, 'and the path' );
    like( $sub, qr/\$onfd\[1\] == \$onpath\[1\]/,
        'and compares the inode - a lock on an unlinked inode excludes nobody' );
    like( $sub, qr/return 0/, 'a mismatch is a failure to acquire, not a success' );
};

# SM791: two one-line guards in the root-run provisioning. Neither is
# exploitable as it stands, which is the reason to close the class cheaply.
subtest 'provisioning refuses a value that could split a line' => sub {
    my $src = do {
        open my $s, '<', repo_root() . '/tools/lazysite-hestia-domain.pl' or die $!;
        local $/;
        <$s>;
    };
    my ($check) = $src =~ /(sub check_domain \{.*?\n\})/s;
    ok( $check, 'check_domain was found' ) or return;
    like( $check, qr/\\A\[A-Za-z0-9\]/, 'the domain pattern anchors with \A' );
    like( $check, qr/\\z/, 'and \z - Perl\'s $ matches before a trailing newline' );

    my ($kv) = $src =~ /(sub write_kv_file \{.*?\n\})/s;
    ok( $kv, 'write_kv_file was found' ) or return;
    like( $kv, qr/\[\\r\\n\]/,
        'and no value carrying a line break is written - the guard is HERE '
            . 'because the registry and pool writers share this sub' );
};

done_testing;

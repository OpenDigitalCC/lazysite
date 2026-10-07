#!/usr/bin/perl
# SM932 (2): `lazysite check --sinks` sends one marked diagnostic line through
# the engine's own forwarding and says whether the system log received it.
#
# NOTHING HERE REACHES THE HOST'S LOG. The engine's LAZYSITE_SYSLOG_DUMP redirect
# takes the line to a file, and the journal cases use a stand-in journalctl on
# PATH (LAZYSITE_CHECK_SINK_READ=journal forces that read). A probe that wrote to
# the real syslog on every suite run would be a test touching the host.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $script" unless -f $script;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" . ( $conf // '' ) );
    return $d;
}

# The check, its sinks lines only. %env is laid over a clean forwarding env.
sub sinks {
    my ( $d, %env ) = @_;
    local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS};
    local $ENV{LAZYSITE_SYSLOG_DUMP};
    local $ENV{LAZYSITE_CHECK_SINK_READ};
    local $ENV{PATH} = $ENV{PATH};
    $ENV{$_} = $env{$_} for keys %env;
    my $out = qx($^X \Q$script\E --docroot \Q$d\E --sinks 2>&1);
    return join "\n", grep { /diagnostic sinks/ } split /\n/, $out;
}

# A stand-in journalctl: prints $body, exits $rc.
sub fake_journal {
    my ( $body, $rc ) = @_;
    my $bin = site_tempdir() . '/bin';
    make_path($bin);
    spit( "$bin/journalctl", "#!/bin/sh\n$body\nexit " . ( $rc // 0 ) . "\n" );
    chmod 0755, "$bin/journalctl";
    return "$bin:$ENV{PATH}";
}

subtest 'the default forwards, and the probe is received' => sub {
    my $d    = site();
    my $dump = "$d/../syslog.dump";
    my $r    = sinks( $d, LAZYSITE_SYSLOG_DUMP => $dump );
    like( $r, qr/\[\s+ok\s+\] diagnostic sinks: syslog received the probe \(the syslog dump file\)/,
        'received, and says where it looked' ) or diag($r);
    like( slurp($dump) // '', qr/^err lazysite check: diagnostic sink probe [0-9a-f]{16}/m,
        'through the engine\'s forward_line, at err so any threshold passes it' );
};

subtest 'forwarding off is said, and nothing is sent' => sub {
    my $d    = site("forward_diagnostics: off\n");
    my $dump = "$d/../syslog.dump";
    my $r    = sinks( $d, LAZYSITE_SYSLOG_DUMP => $dump );
    like( $r, qr/\[ warn \] diagnostic sinks: syslog forwarding is off/, 'a warning naming the setting' ) or diag($r);
    ok( !-e $dump, 'and no line was sent' );
};

subtest 'a line that cannot be sent is a failure' => sub {
    my $d = site();
    my $r = sinks( $d, LAZYSITE_SYSLOG_DUMP => "$d/no/such/dir/dump" );
    like( $r, qr/\[ FAIL \] diagnostic sinks: the probe line could not be sent/, 'FAIL, not ok' ) or diag($r);
};

subtest 'read from the journal: received' => sub {
    my $d    = site();
    my $dump = "$d/../syslog.dump";
    my $r    = sinks( $d, LAZYSITE_SYSLOG_DUMP => $dump, LAZYSITE_CHECK_SINK_READ => 'journal',
        PATH => fake_journal("cat '$dump' 2>/dev/null") );
    like( $r, qr/\[\s+ok\s+\] diagnostic sinks: syslog received the probe \(the system journal\)/,
        'found in what journalctl printed' ) or diag($r);
};

subtest 'read from the journal: sent, never arrived' => sub {
    my $d = site();
    my $r = sinks( $d, LAZYSITE_SYSLOG_DUMP => "$d/../syslog.dump", LAZYSITE_CHECK_SINK_READ => 'journal',
        PATH => fake_journal('echo "some other line"') );
    like( $r, qr/\[ FAIL \] diagnostic sinks: sent to syslog, but the system journal did not receive it/,
        'a readable journal without the line is a failure' ) or diag($r);
};

subtest 'a journal this account cannot read is not a pass' => sub {
    my $d = site();
    my $r = sinks( $d, LAZYSITE_SYSLOG_DUMP => "$d/../syslog.dump", LAZYSITE_CHECK_SINK_READ => 'journal',
        PATH => fake_journal('echo "No journal files were found."') );
    like( $r, qr/\[ warn \] diagnostic sinks: sent to syslog; cannot confirm it arrived - journalctl: No journal files/,
        'cannot tell, and says why' ) or diag($r);
};

subtest 'a plain check sends nothing' => sub {
    my $d    = site();
    my $dump = "$d/../syslog.dump";
    local $ENV{LAZYSITE_SYSLOG_DUMP} = $dump;
    qx($^X \Q$script\E --docroot \Q$d\E 2>&1);
    ok( !-e $dump, 'without --sinks the host log is not written' );
};

done_testing();

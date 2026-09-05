#!/usr/bin/perl
# SM752: the daemon plugin's Status action produces output, in the state an
# operator actually clicks it.
#
# 0.13.0 shipped with `require Lazysite::Daemon::Supervisor` in plugins/daemon.pl
# and no @INC bootstrap. The manager runs a plugin action as a SUBPROCESS, so
# the require died, and a plugin action that dies prints nothing to stdout - so
# the manager answered "Action produced no output".
#
# THE STATE IT FAILED IN IS THE ONE THE FEATURE IS FOR. Plugin enabled, runtime
# not started, an operator asking why nothing is happening: that is precisely
# when the desired/runtime split is worth having, and it was the one moment it
# said nothing at all. The safety half held - nothing was dishonestly claimed to
# be running - but the diagnostic half was absent exactly where it was designed
# to be present.
#
# t/unit/daemon/01 tests Supervisor::status() directly and passed throughout,
# because calling a function in-process never exercises the subprocess load. The
# field found it in one click. This file is the assertion that would have caught
# it: run the plugin THE WAY THE MANAGER DOES, and require that something comes
# back.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP   ();

my $root   = repo_root();
my $plugin = "$root/plugins/daemon.pl";
plan skip_all => 'no daemon plugin' unless -f $plugin;

sub status_for {
    my ($docroot) = @_;

    # PERL5OPT cleared for the same reason t/tools/60 clears it: this may run
    # inside a coverage run, and the inner process should not inherit it.
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    local $ENV{PERL5LIB}              = '';
    return
      scalar
      qx($^X \Q$plugin\E --action status --docroot \Q$docroot\E 2>/dev/null);
}

sub site {
    my (@plugins) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: t\n";
    if (@plugins) {
        print {$fh} "plugins:\n";
        print {$fh} "  - $_\n" for @plugins;
    }
    close $fh;
    return $d;
}

subtest 'enabled but not started - the state the field found empty' => sub {
    my $out = status_for( site('daemon.pl') );

    ok( defined $out && length $out,
        'the action produces OUTPUT - this returned nothing in 0.13.0' )
      or return;

    my $st = eval { JSON::PP->new->decode($out) };
    ok( ref $st eq 'HASH', 'and it is JSON the manager can render' )
      or do { diag($out); return };

    # SM222's vocabulary: desired is what the configuration says, verdict is
    # what the runtime is doing, and when they disagree the verdict SAYS so.
    is( $st->{desired}, 'on',
        'desired: on - the plugin is enabled, which the manager knows' );
    is( $st->{verdict}, 'inconsistent',
            'verdict: inconsistent - switched on and not running, NOT a claim '
          . 'to be running' );
    is( $st->{services}[0]{verdict},
        'inconsistent', 'and the scheduler service says the same of itself' );
    ok( !$st->{healthy}, 'which is not a healthy state' );
    like(
        $st->{message},
        qr/not running/,
        'with a message in words an operator can read'
    );
    like(
        $st->{remedy},
        qr/systemctl enable --now lazysited\@/,
        'and a remedy that names the command, not "check the host service"'
    );
};

subtest 'disabled - the other half of the same question' => sub {
    my $out = status_for( site() );
    ok( defined $out && length $out, 'still answers when the plugin is off' )
      or return;

    my $st = eval { JSON::PP->new->decode($out) };
    ok( ref $st eq 'HASH', 'as JSON' ) or do { diag($out); return };

    is( $st->{desired}, 'off', 'desired: off' );
    is( $st->{verdict}, 'off', 'verdict: off - off is what was asked for' );
    ok( $st->{healthy},        'so it is healthy, and carries no remedy' );
    ok( !exists $st->{remedy}, 'no remedy on a healthy status' );
    like( $st->{message}, qr/disabled/,
        'and says the plugin is disabled, which is why nothing runs' );
};

subtest 'the action is declared, so the button exists to be pressed' => sub {

    # A status action that works but is not advertised is as useless to an
    # operator as one that is advertised and does not work.
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    local $ENV{PERL5LIB}              = '';

    # SCALAR FIRST. `qx` as an argument is in LIST context and returns a list
    # of LINES, so decode would get only "{" - which is the bug this session
    # fixed in t/lint/76 and which I then wrote again here, three hours later,
    # in a test about a plugin that prints multi-line JSON. The first version
    # failed for exactly that reason.
    my $raw  = qx($^X \Q$plugin\E --describe 2>/dev/null);
    my $desc = eval { JSON::PP->new->decode($raw) };
    ok( ref $desc eq 'HASH', 'the plugin describes itself' ) or return;

    my @ids = map { $_->{id} } @{ $desc->{actions} || [] };
    ok( ( grep { $_ eq 'status' } @ids ), 'and declares the status action' );
};

done_testing();

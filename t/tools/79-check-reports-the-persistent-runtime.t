#!/usr/bin/perl
# SM893: `lazysite check` reports whether this site's persistent runtime is
# armed, and whether that matches what the site wants.
#
# WHY IT DID NOT BEFORE: the host half (conf + timer, root) and the site half
# (the `daemon` extension, the sysop) are owned by different people, and the
# only place they could be seen to disagree was the manager's Status button -
# which nobody presses until something is already wrong. `lazysite check` had
# zero occurrences of `daemon`.
#
# FOUR STATES, and the test drives all four, because the interesting ones are
# not the happy path:
#
#   armed + wanted      -> OK (running, or the timer will start it)
#   armed + not wanted  -> OK, and it SAYS SO. This is the normal resting state
#                          and the one operators misread: `inactive (dead)` is
#                          correct for a site whose extension is off.
#   not armed + wanted  -> FAIL. The sysop has enabled the extension and
#                          nothing will ever start it.
#   not armed + neither -> WARN, against the SM893 ruling that every site is
#                          armed, not against the site: nothing is broken today.
#
# Driven through the real script with LAZYSITE_DAEMON_DIR pointed at a fixture,
# so no systemd and no root are needed and the four states are reachable.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);

my $root = repo_root();

# One site, reused; the two switches are moved between subtests.
my $docroot = site_tempdir();
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/logs");

sub set_conf {
    my ($with_daemon) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    print {$fh} "plugins:\n  - plugins/daemon.pl\n" if $with_daemon;
    close $fh;
    return;
}

my $daemon_dir = "$docroot/../daemon-etc";
make_path($daemon_dir);

sub arm {
    open my $fh, '>', "$daemon_dir/probe.example.conf" or die $!;
    print {$fh} "DOCROOT=$docroot\nUSER=www-data\n";
    close $fh;
    return;
}
sub disarm { unlink "$daemon_dir/probe.example.conf"; return }

sub check_output {
    local %ENV = ( env_passthrough(), LAZYSITE_DAEMON_DIR => $daemon_dir );
    my $out = qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$docroot\E 2>&1);
    return $out // '';
}

subtest 'not armed, extension off: a warning about the ruling, not the site' => sub {
    set_conf(0);
    disarm();
    my $out = check_output();
    like( $out, qr/not armed for the persistent runtime/,
        'it says the site is not armed' );
    unlike( $out, qr/can never start/,
        'and does not claim anything is broken - the extension is off' );
};

subtest 'not armed, extension ON: the dangerous cell, and it fails' => sub {
    set_conf(1);
    disarm();
    my $out = check_output();
    like( $out, qr/the runtime can never start/,
        'it says the runtime can never start' )
        or diag( 'This is the state where a sysop has enabled the extension '
            . 'and no host operator has provisioned the site. Silence here is '
            . 'what SM893 exists to remove.' );
    like( $out, qr/lazysite-hestia-domain add/, 'and names the remedy' );
};

# WHAT THIS FIXTURE CANNOT REACH, said rather than worked around: the two
# ARMED states below depend on the lazysited@ unit template being installed on
# the host, and a test cannot install systemd units. So `armed and idle` - the
# message that exists to settle the reading operators get wrong - is asserted
# for its DECISION here (not-found is distinguished from disabled) and its
# wording is pinned by the source check in this same suite rather than driven.
#
# That distinction is itself worth a test: `systemctl is-enabled` answers
# `not-found` for a template that is not installed and `disabled` for one that
# is, and sending an operator to `systemctl enable` a unit that does not exist
# wastes their time and reads as their mistake.
subtest 'armed, but the unit template is not installed' => sub {
    set_conf(0);
    arm();
    my $out = check_output();
    like( $out, qr/unit template\s+is not installed/,
        'it distinguishes a missing template from a disabled timer' )
        or diag("got: $out");
    unlike( $out, qr/systemctl enable --now/,
        'and does NOT tell the operator to enable a unit that does not exist' );
};

subtest 'armed with the extension ON, template missing: still a failure' => sub {
    set_conf(1);
    arm();
    my $out = check_output();
    like( $out, qr/nothing can start it/,
        'the wanted-but-unstartable case is a failure whatever the cause' );
};

subtest 'no daemon directory at all: silent' => sub {
    set_conf(0);
    local %ENV = ( env_passthrough(),
        LAZYSITE_DAEMON_DIR => "$docroot/../definitely-not-here" );
    my $out = qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$docroot\E 2>&1);
    unlike( $out // '', qr/persistent runtime/,
        'a host with no systemd flow is not nagged about one' );
};

done_testing();

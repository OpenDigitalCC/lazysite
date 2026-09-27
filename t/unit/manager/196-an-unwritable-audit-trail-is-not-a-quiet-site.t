#!/usr/bin/perl
# SM907 AT2: a short audit page has six possible meanings, and until this change
# it had one rendering.
#
# The field case: a trail the CGI could READ and could not APPEND to. The page
# showed the six events a root shell had written, looked healthy, and said
# nothing about every web-server event since - so the operator had to ask why an
# agent's deployment left no trace. Two other states were indistinguishable from
# each other: a trail that exists and will not open answered `ok` with an empty
# list, exactly like a new site that has genuinely recorded nothing.
#
# What is asserted here is the DIFFERENCE between the states, not the wording:
# each answer has to be distinguishable by a client, and the one state where an
# empty list is the truth has to stay silent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

# SM118's rule: a docroot sits a level down, never at the top of a tempdir - this
# test chmods the directory ABOVE the log, and a bare tempdir would be chmodding
# the temp root itself.
my $d = site_tempdir();
make_path("$d/lazysite/logs");

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $d;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $dir = "$d/lazysite/logs";
my $log = "$dir/audit.log";

# The page reads through an append-only cache keyed on the file's identity. Each
# state must be answered from the FILE, as a fresh request would be, so the cache
# never carries one state's answer into the next.
sub audit_now {
    unlink "$d/lazysite/cache/audit-cache.json";
    return main::action_audit();
}

main::audit_log( 'ada', 'login', 'site.invalid', '1.2.3.4', 'ok', 'ui' );
main::audit_log( 'ada', 'save',  'index.md',     '1.2.3.4', 'ok', 'ui' );

subtest 'a recording trail says nothing and lists everything' => sub {
    my $r = audit_now();
    ok( $r->{ok}, 'ok' );
    is( scalar @{ $r->{entries} }, 2, 'both events listed' );
    is( $r->{trail}{state}, 'appendable', 'state: appendable' );
    ok( !$r->{trail}{why}, 'a healthy trail volunteers no warning' );
};

subtest 'READABLE AND NOT APPENDABLE is the field case, and it is named' => sub {
    chmod 0444, $log;
    my $r = audit_now();
    ok( $r->{ok}, 'still ok - what is on disk is still worth showing' );
    is( scalar @{ $r->{entries} }, 2, 'the entries that were written are listed' );
    is( $r->{trail}{state}, 'unwritable', 'state: unwritable' );
    like( $r->{trail}{why}, qr/lost/i, 'says events are being lost' );
    is( $r->{trail}{file}, $log, 'names the file' );
    like( $r->{trail}{repair}, qr/lazysite check/, 'names the repair' );
    chmod 0644, $log;
};

subtest 'a trail that will not open is a refusal, never an empty list' => sub {
    chmod 0000, $log;
  SKIP: {
        skip 'running as root: mode does not restrain this process', 4 if $> == 0;
        my $r = audit_now();
        ok( !$r->{ok}, 'refused' );
        is( $r->{kind}, 'store-uninspectable', 'SM873 kind: the host cannot read its own state' );
        is( Lazysite::Manager::Common::refusal_status( $r->{kind} ),
            '500 Internal Server Error', 'and it answers 500, not 400' );
        like( $r->{error}, qr/\Q$log\E/, 'the refusal names the file' );
    }
    chmod 0644, $log;
};

subtest 'ABSENT and UNREADABLE are different answers' => sub {
    unlink $log;
    my $r = audit_now();
    ok( $r->{ok}, 'ok: a new site recording nothing is not a fault' );
    is( scalar @{ $r->{entries} }, 0, 'no entries' );
    is( $r->{trail}{state}, 'never-written', 'state: never-written' );
    ok( !$r->{trail}{why}, 'and it stays silent - an empty list is the truth here' );
};

subtest 'a trail that cannot be started says so' => sub {
  SKIP: {
        skip 'running as root: mode does not restrain this process', 3 if $> == 0;
        chmod 0500, $dir;    # traversable, not writable: no trail can be created
        my $r = audit_now();
        is( $r->{trail}{state}, 'cannot-start', 'state: cannot-start' );
        like( $r->{trail}{why}, qr/recorded/i, 'says nothing is being recorded' );
        like( $r->{trail}{repair}, qr/lazysite check/, 'names the repair' );
        chmod 0755, $dir;
    }
};

subtest 'switched off is a choice, not a fault, and is still disclosed' => sub {
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\naudit_trail: off\n";
    close $fh;
    main::audit_log( 'ada', 'save', 'after-off.md', '1.2.3.4', 'ok', 'ui' );
    my $r = audit_now();
    ok( $r->{ok}, 'ok' );
    is( $r->{trail}{state}, 'off', 'state: off' );
    like( $r->{trail}{why}, qr/switched off/i, 'says recording is off' );
    ok( !$r->{trail}{repair}, 'no repair offered: it is a setting, not a fault' );
};

done_testing;

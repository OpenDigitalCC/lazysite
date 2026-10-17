#!/usr/bin/perl
# SM1107 (0.15.6 test plan, U8): AN OPERATOR RETRIES AN OUTBOX ENTRY NOW.
#
# The field report: "No way to retry an outbox entry now. After a transport fix,
# entries sit in backoff for minutes. notify-outbox-list is the only outbox
# action. A 'retry now' for the operator would make a mail fix testable without
# posting fresh events." outbox_retry makes a waiting (retrying) entry due now,
# by event id or for a whole rule. It does not send: the job does, on its next
# tick, under every rule it always applies - so it neither bypasses the
# per-recipient cap nor a held fold, and an entry already sent is not sent again.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my ( $D, $SENT, $BROKEN );
local $Lazysite::Outbox::MAIL_SENDER = sub { die "connection refused\n" if $BROKEN; $SENT++; return 1 };

sub site {
    my ($cap) = @_;
    $D = site_tempdir();
    make_path( "$D/lazysite/forms", "$D/lazysite/logs" );
    spit( "$D/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\n" );
    my $rule = sub { my ($id) = @_;
        "  - id: $id\n    type: notify\n    name: $id\n    recipients: [{\"fixed\":[\"$id\@example.org\"]}]\n"
        . "    from: news\@news.example\n    unsubscribe: false\n    per_recipient_hour: $cap\n" };
    spit( "$D/lazysite/forms/handlers.conf", "handlers:\n" . $rule->('zz57-a') . $rule->('zz57-b') );
    $Lazysite::Handlers::DOCROOT = $D;
    ( $SENT, $BROKEN ) = ( 0, 0 );
    return;
}

sub queue {
    my ($rule) = @_;
    my $r = Lazysite::Handlers::deliver( $rule, { post => 'p' }, origin => 'form', source => 'form:c', actor => 'zz9member' );
    die 'not queued' unless $r->{ok} && $r->{queued};
    return;
}

sub listed { my (%a) = @_; return Lazysite::Outbox::outbox_list( docroot => $D, %a ) }
sub run_at { my ($now) = @_; return Lazysite::Outbox::run( docroot => $D, actor => 'jobs', now => $now ) }

my $T = time;

subtest 'a retrying entry becomes due now, and the next run sends it' => sub {
    site(10);
    queue('zz57-a');
    queue('zz57-b');
    $BROKEN = 1;
    run_at($T);
    my $l = listed( rule => 'zz57-a' );
    is( $l->{entries}[0]{state}, 'retrying', 'the transport is down: the entry is retrying' );
    my $due = $l->{entries}[0]{due};
    cmp_ok( $due, '>', $T + 60, 'and waits minutes' );

    $BROKEN = 0;
    run_at( $T + 10 );
    is( $SENT, 0, 'the transport is fixed, and the entry still sits in backoff' );

    my $id = $l->{entries}[0]{id};
    my $r  = Lazysite::Outbox::outbox_retry( docroot => $D, id => $id, now => $T + 10 );
    ok( $r->{ok}, 'retry by id' ) or diag explain $r;
    is( $r->{retried}, 1, 'one entry made due' );
    run_at( $T + 11 );
    is( $SENT, 1, 'the next run sends it' );
    is_deeply( [ map { $_->{state} } @{ listed( rule => 'zz57-a' )->{entries} } ], ['sent'], 'and it is listed as sent, not queued (SM1122)' );
    is( scalar @{ listed( rule => 'zz57-b' )->{entries} }, 1, 'the other rule\'s entry was not touched' );
};

subtest 'by rule: every waiting entry of that rule, no other' => sub {
    site(10);
    queue('zz57-a') for 1 .. 3;
    queue('zz57-b');
    $BROKEN = 1;
    run_at($T);
    $BROKEN = 0;
    my $r = Lazysite::Outbox::outbox_retry( docroot => $D, rule => 'zz57-a', now => $T + 10 );
    is( $r->{retried}, 3, 'three made due' );
    run_at( $T + 11 );
    is( $SENT, 3, 'three sent' );
    is( scalar @{ listed( rule => 'zz57-b' )->{entries} }, 1, 'the other rule still waits' );
};

subtest 'it does not bypass the cap, a held fold, or resend a sent entry' => sub {
    site(1);    # one an hour
    queue('zz57-a') for 1 .. 3;
    run_at($T);
    is( $SENT, 1, 'one sent' );
    my $l = listed( rule => 'zz57-a' );
    is( scalar @{ $l->{held} }, 1, 'two are held by the cap' );
    my $r = Lazysite::Outbox::outbox_retry( docroot => $D, rule => 'zz57-a', now => $T + 10 );
    ok( $r->{ok}, 'retry accepted' );
    is( $r->{retried}, 0, 'nothing made due' );
    is( $r->{held}, 1, 'and it says a held message was left to the cap' );
    run_at( $T + 11 );
    is( $SENT, 1, 'nothing more was sent: the cap still holds' );
};

subtest 'an entry the job already sent is not made due again' => sub {
    site(10);
    queue('zz57-a');
    run_at($T);
    is( $SENT, 1, 'sent' );
    # An entry the job could not remove: still on disk, the ledger says it went.
    make_path("$D/lazysite/notify/outbox");
    queue('zz57-a');
    my $out = "$D/lazysite/notify/outbox";
    chmod 0555, $out;
    run_at( $T + 1 );
    chmod 0755, $out;
    is( $SENT, 2, 'the second went' );
    my $r = Lazysite::Outbox::outbox_retry( docroot => $D, rule => 'zz57-a', now => $T + 2 );
    is( $r->{retried}, 0, 'nothing retried' );
    is( $r->{sent}, 1, 'the sent entry is counted as sent, not retried' );
    run_at( $T + 3 );
    is( $SENT, 2, 'and not sent again' );
};

subtest 'it asks for a rule or an id, and respects who may see the rule' => sub {
    site(10);
    queue('zz57-a');
    $BROKEN = 1;
    run_at($T);
    my $r = Lazysite::Outbox::outbox_retry( docroot => $D, now => $T );
    ok( !$r->{ok}, 'neither a rule nor an id is refused' );
    is( $r->{kind}, 'invalid', 'as invalid' );
    $r = Lazysite::Outbox::outbox_retry( docroot => $D, rule => 'not a rule!', now => $T );
    is( $r->{kind}, 'invalid', 'a malformed rule is invalid' );
    $r = Lazysite::Outbox::outbox_retry( docroot => $D, id => 'nothere', now => $T );
    is( $r->{kind}, 'invalid', 'a malformed id is invalid' );
    $r = Lazysite::Outbox::outbox_retry( docroot => $D, id => 'a' x 16, now => $T );
    is( $r->{kind}, 'not-found', 'an id that is not in the outbox is not found' );

    my $id = listed()->{entries}[0]{id};
    $r = Lazysite::Outbox::outbox_retry( docroot => $D, id => $id, now => $T, may_see => sub { 0 } );
    is( $r->{kind}, 'not-found', 'a caller who may not see the rule finds nothing' );
    $r = Lazysite::Outbox::outbox_retry( docroot => $D, rule => 'zz57-a', now => $T, may_see => sub { 0 } );
    is( $r->{retried}, 0, 'and retries nothing by rule' );
};

done_testing();

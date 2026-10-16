#!/usr/bin/perl
# SM1093 (0.15.5 test plan, T4): A DELETED NOTIFY RULE TAKES ITS QUEUED ENTRIES
# WITH IT.
#
# The field report: "Deleting a notify rule leaves its queued entries in the
# outbox (three for zz55-mail, three for zz55-bell, still listed by
# notify-outbox-list after the delete), and nothing removes them." The delete
# now removes the rule's unsent entries - queued, retrying and held - and says
# how many; the sent history (the ledger) and the failed record are not touched,
# and another rule's queue is not either. Entries already stranded by an
# earlier delete are not sent: the outbox job clears them from the queue (to the
# failed record, as a given-up notification is) and logs the count.
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
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my ( $D, $OUT );

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\n" );
    $OUT = "$d/mail.out";
    spit( "$d/sendmail", "#!$^X\nlocal \$/; my \$m = <STDIN>; open my \$w, '>>', '$OUT' or exit 1; print {\$w} \$m; close \$w;\n" );
    chmod 0755, "$d/sendmail";
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
    my $rule = sub { my ($id) = @_;
        "  - id: $id\n    type: notify\n    name: $id\n    recipients: [{\"fixed\":[\"$id\@example.org\"]}]\n"
        . "    from: news\@news.example\n    unsubscribe: false\n" };
    spit( "$d/lazysite/forms/handlers.conf", "handlers:\n" . $rule->('zz55-mail') . $rule->('zz55-bell') );
    $Lazysite::Handlers::DOCROOT = $d;
    $D = $d;
    return $d;
}

sub queue {
    my ( $rule, $n ) = @_;
    for ( 1 .. $n ) {
        my $r = Lazysite::Handlers::deliver( $rule, { post => "p$_" }, origin => 'form', source => 'form:c', actor => 'zz9member' );
        die 'not queued' unless $r->{ok} && $r->{queued};
    }
}

sub files_in {
    my ($sub) = @_;
    opendir my $dh, "$D/lazysite/notify/$sub" or return ();
    return sort grep { /\.json\z/ } readdir $dh;
}

sub rules_in {
    my ($sub) = @_;
    return sort map { JSON::PP::decode_json( slurp("$D/lazysite/notify/$sub/$_") )->{rule} } files_in($sub);
}

subtest 'deleting a rule removes its unsent entries, and says how many' => sub {
    site();
    queue( 'zz55-mail', 3 );
    queue( 'zz55-bell', 3 );
    # A held message (a fold), a failed record and the sent ledger: only the
    # held one is unsent.
    make_path( "$D/lazysite/notify/folds", "$D/lazysite/notify/failed" );
    spit( "$D/lazysite/notify/folds/" . ( 'a' x 24 ) . '.json', '{"rule":"zz55-mail","channel":"email","recipient":{"key":"k","address":"x@example.org"},"events":[]}' );
    spit( "$D/lazysite/notify/failed/1-" . ( 'b' x 16 ) . '.json', '{"rule":"zz55-mail","id":"old","failed":"gave up"}' );
    spit( "$D/lazysite/notify/ledger.jsonl", "{\"rule\":\"zz55-mail\"}\n" );

    my $r = Lazysite::Handlers::action_handler_delete( 'zz55-mail', caps => { manage_notifications => 1, manage_forms => 1 } );
    ok( $r->{ok}, 'the rule is deleted' ) or diag explain $r;
    is( $r->{outbox_removed}, 4, 'the result says 4 were removed (3 queued and 1 held)' );
    is_deeply( [ rules_in('outbox') ], [ ('zz55-bell') x 3 ], 'only the other rule\'s entries remain' );
    is( scalar( () = files_in('folds') ), 0, 'the held message went too' );
    is( scalar( () = files_in('failed') ), 1, 'the failed record is history and stays' );
    like( slurp("$D/lazysite/notify/ledger.jsonl"), qr/zz55-mail/, 'so does the sent ledger' );
};

subtest 'a rule with nothing queued says none' => sub {
    site();
    my $r = Lazysite::Handlers::action_handler_delete( 'zz55-bell', caps => { manage_notifications => 1, manage_forms => 1 } );
    ok( $r->{ok}, 'deleted' );
    is( $r->{outbox_removed}, 0, 'zero removed, stated' );
};

subtest 'a file handler\'s delete is untouched by the outbox' => sub {
    site();
    spit( "$D/lazysite/forms/handlers.conf", "handlers:\n  - id: store\n    type: file\n    name: Store\n" );
    my $r = Lazysite::Handlers::action_handler_delete( 'store', caps => { manage_forms => 1 } );
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    ok( !exists $r->{outbox_removed}, 'no outbox count on a handler that never queues' );
};

subtest 'entries stranded by an earlier delete are not sent, and the job gives them up' => sub {
    site();
    queue( 'zz55-mail', 3 );
    queue( 'zz55-bell', 1 );
    # The rule goes the way it did before the fix: out of handlers.conf alone.
    spit( "$D/lazysite/forms/handlers.conf", "handlers:\n  - id: zz55-bell\n    type: notify\n    name: b\n"
        . "    recipients: [{\"fixed\":[\"zz55-bell\@example.org\"]}]\n    from: news\@news.example\n    unsubscribe: false\n" );
    make_path("$D/lazysite/notify/folds");
    spit( "$D/lazysite/notify/folds/" . ( 'c' x 24 ) . '.json', '{"rule":"zz55-mail","channel":"email","recipient":{"key":"k","address":"x@example.org"},"events":[]}' );

    my $log = "$D/job.err";
    open my $save, '>&', \*STDERR or die;
    open STDERR, '>', $log or die;
    my $r = Lazysite::Outbox::run( docroot => $D, actor => 'jobs' );
    open STDERR, '>&', $save or die;
    ok( $r->{ok}, 'the job ran' ) or diag explain $r;
    is( $r->{detail}{orphans_cleared}, 4, 'the job reports 4 cleared' );
    my $mail = slurp($OUT);
    unlike( $mail, qr/zz55-mail\@example\.org/, 'nothing was sent for the rule that is gone' );
    like( $mail, qr/zz55-bell\@example\.org/, 'the live rule\'s entry was sent' );
    is( scalar( () = files_in('outbox') ), 0, 'the outbox is empty' );
    is( scalar( () = files_in('folds') ), 0, 'and so are the held messages' );
    is( scalar( () = files_in('failed') ), 4, 'they are kept with the failed ones, as a given-up notification is (SM1071)' );
    my $audit = slurp("$D/lazysite/logs/audit.log");
    like( $audit, qr/failed .*no rule 'zz55-mail'/, 'and the audit says why' );
    like( slurp($log), qr/cleared 4 notification\(s\) queued for rules that no longer exist/, 'the log names the count' );
};

done_testing();

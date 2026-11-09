#!/usr/bin/perl
# Ruling 206 (items 10, 11 and 14 of the 0.16.9 fault survey): A DAMAGED SEND
# RECORD SENDS NOTHING, AND THE QUEUE WAITS FOR THE REPAIR.
#
#   10. notify/suppressed.jsonl: an undecodable line was skipped, so the person
#       whose stop it recorded was mailed again.
#   11. notify/ledger.jsonl: a dropped line lost its "sent", so that notice went
#       twice - and the prune rewrote the ledger without it.
#   14. notify/status.json: an undecodable status read as {} and was written over.
#
# For 10 and 11 the run now sends nothing, says which store and `lazysite check`,
# keeps every queued entry and leaves the damaged file as found; once the line is
# repaired the same entries go. For 14 the run still sends and the status file
# is left as found. An absent store is a fresh site and sends as before.
#
# No network: the transport is the Form SMTP extension's sendmail method, and
# sendmail is a stub that appends what it is handed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my ( $D, $OUT );

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/notify" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\n" );
    $OUT = "$d/mail.out";
    spit( "$d/sendmail", "#!$^X\nlocal \$/; my \$m = <STDIN>;\n"
            . "open my \$w, '>>', '$OUT' or exit 1; print {\$w} \"--MESSAGE--\\n\", \$m; close \$w;\n" );
    chmod 0755, "$d/sendmail";
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: desk\n    type: notify\n    name: Desk\n"
            . "    recipients: [{\"fixed\":[\"desk\@news.example\"]}]\n"
            . "    from: news\@news.example\n    unsubscribe_path: /account\n" );
    $Lazysite::Handlers::DOCROOT = $d;
    $D = $d;
    return $d;
}

sub queue {
    my $r = Lazysite::Handlers::deliver( 'desk', { comment => $_[0] }, origin => 'form', source => 'form:c',
        actor => 'someone' );
    ok( $r->{ok} && $r->{queued}, 'an event is queued' ) or diag explain $r;
    return;
}

sub run_job {
    my $err = '';
    my $r;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $r = Lazysite::Outbox::run( docroot => $D, actor => 'jobs' );
        close STDERR;
    }
    return ( $r, $err );
}

sub sent   { return scalar grep { length } split /--MESSAGE--\n/, slurp($OUT) }
sub queued { opendir my $dh, "$D/lazysite/notify/outbox" or return 0; return scalar grep { /\.json\z/ } readdir $dh }

subtest 'absent stores: a fresh site sends' => sub {
    site();
    queue('one');
    my ( $r, $err ) = run_job();
    ok( $r->{ok}, 'the run is ok' ) or diag explain $r;
    is( sent(),   1, 'one message went' ) or diag $err, slurp("$D/lazysite/logs/audit.log");
    is( queued(), 0, 'and the queue is empty' );
};

for my $case (
    [ 'suppressed.jsonl', 'the unsubscribe store', qr/unsubscribe record \(line 2\)/ ],
    [ 'ledger.jsonl',     'the notification ledger', qr/ledger record \(line 2\)/ ],
    )
{
    my ( $file, $what, $logged ) = @$case;
    subtest "a line in $file that is not a record: nothing is sent and the queue is kept" => sub {
        site();
        my $store = "$D/lazysite/notify/$file";
        my $good  = $file eq 'ledger.jsonl'
            ? qq({"c":"email","e":"old","k":"x","p":"y","r":"desk","s":"sent","t":) . time . "}\n"
            : qq({"p":"000000000000000000000000","r":"desk","t":1}\n);
        my $damaged = $good . "{\"torn\n" . $good;
        spit( $store, $damaged );
        queue('one');
        queue('two');
        my ( $r, $err ) = run_job();
        ok( !$r->{ok}, 'the run is refused' );
        like( $r->{error}, qr/\Q$what\E \(lazysite\/notify\/\Q$file\E\) cannot be read, so nothing was sent/,
            'naming the store' );
        like( $r->{error}, qr/the queue is kept\. `lazysite check --docroot <docroot>` names the fault/,
            'and the check' );
        is( sent(),   0, 'nothing was sent' );
        is( queued(), 2, 'both entries are still queued' );
        is( slurp($store), $damaged, 'the damaged store is byte-identical' );
        like( $err, qr/cannot tell - lazysite\/notify\/\Q$file\E holds a line that is not/, 'the log names it' );
        like( $err, $logged, 'and the line' );

        spit( $store, $good );
        ($r) = run_job();
        ok( $r->{ok}, 'once repaired, the run is ok' ) or diag explain $r;
        is( sent(),   2, 'the kept entries go' );
        is( queued(), 0, 'and leave the queue' );
    };
}

subtest 'an undecodable status file is left as found, and the run still sends' => sub {
    site();
    my $status = "$D/lazysite/notify/status.json";
    spit( $status, '{"desk": {"sent": 1' );
    queue('one');
    my ( $r, $err ) = run_job();
    ok( $r->{ok}, 'the run is ok' ) or diag explain $r;
    is( sent(), 1, 'the notice went' );
    is( slurp($status), '{"desk": {"sent": 1', 'the status file is byte-identical' );
    like( $err, qr/cannot tell - lazysite\/notify\/status\.json does not decode/, 'the log names it' );
};

done_testing();

#!/usr/bin/perl
# SM1122 (0.15.9 walk, X3 / F-2): A SENT OUTBOX ENTRY IS KEPT AS `sent`.
#
# The field report: "a sent outbox entry is deleted rather than kept as `sent`.
# Listing by rule shows nothing, and by id says not-found." Three events were
# listed queued; after the next tick all three were delivered; then
# notify-outbox-list&rule=zz59-mail returned "entries":[] and a lookup by id
# answered 404 not-found. SM1105 showed an entry as sent from the ledger, but
# only while its FILE was there - it assumed the unlink had failed. The job
# removes an entry after a send, which is the normal case, so the list had
# nothing to show. This drives the normal path: the send succeeds and the file
# is removed. The ledger (kept $LEDGER_DAYS days) is what the list now reads.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $SENT = 0;
local $Lazysite::Outbox::MAIL_SENDER = sub { $SENT++; return 1 };

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: zz59-mail\n    type: notify\n    name: m\n"
    . "    recipients: [{\"fixed\":[\"a\@example.org\",\"b\@example.org\"]}]\n"
    . "    from: news\@news.example\n    unsubscribe: false\n    per_recipient_hour: 10\n" );
$Lazysite::Handlers::DOCROOT = $d;
my @ids;
for ( 1 .. 3 ) {
    my $r = Lazysite::Handlers::deliver( 'zz59-mail', { post => "p$_" }, origin => 'form', source => 'form:c', actor => 'zz9member' );
    die 'not queued' unless $r->{ok} && $r->{queued};
    push @ids, $r->{queued};
}
is_deeply( [ map { $_->{state} } @{ Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz59-mail' )->{entries} } ],
    [ ('queued') x 3 ], 'before the job: three queued' );

my $run = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
ok( $run->{ok}, 'the job ran' ) or diag explain $run;
is( $SENT, 6, 'every event went to both recipients' );
my @left = glob("$d/lazysite/notify/outbox/*.json");
is( scalar @left, 0, 'the normal path: the entry files are removed' );

my $l = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz59-mail' );
is( scalar @{ $l->{entries} }, 3, 'the list still shows the three, from the ledger' ) or diag explain $l;
is_deeply( [ sort map { $_->{id} } @{ $l->{entries} } ], [ sort @ids ], '...by their event ids' );
my ($first) = grep { $_->{id} eq $ids[0] } @{ $l->{entries} };
is( $first->{state}, 'sent', 'each is sent' );
is( $first->{rule}, 'zz59-mail', 'with its rule' );
ok( $first->{sent_at} && $first->{sent_at} > time - 600, 'and when it was sent' );
is_deeply( $first->{recipients}, { email => { sent => 2 } }, 'and how many recipients it went to, by channel and outcome' )
    or diag explain $first;
ok( !$l->{waiting}, 'sent entries are not waiting' );

my $one = Lazysite::Outbox::outbox_list( docroot => $d, id => $ids[1] );
ok( $one->{ok}, 'a lookup by id finds it' ) or diag explain $one;
is( $one->{entry}{state}, 'sent', '...as sent' );
is( $one->{entry}{id}, $ids[1], '...the right one' );

my $none = Lazysite::Outbox::outbox_list( docroot => $d, id => '0123456789abcdef' );
is( $none->{kind}, 'not-found', 'an id the ledger never saw is still not found' );

my $other = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz59-other' );
is( scalar @{ $other->{entries} }, 0, 'another rule sees none of them' );
my $hid = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz59-mail', may_see => sub { 0 } );
is( scalar @{ $hid->{entries} }, 0, 'a caller who may not see the rule is shown none' );

my $states = Lazysite::Outbox::rule_states($d);
is( $states->{'zz59-mail'}{queued}, 0, 'the rule row does not count them as queued' );
ok( !$states->{'zz59-mail'}{waiting}, '...nor as waiting' );

# Past the ledger's window nothing remains to show.
is( scalar @{ Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz59-mail', now => time + ( $Lazysite::Outbox::LEDGER_DAYS + 1 ) * 86400 )->{entries} }, 0,
    'past the ledger window the list has none' );

done_testing();

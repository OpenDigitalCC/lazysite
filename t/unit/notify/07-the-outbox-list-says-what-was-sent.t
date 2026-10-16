#!/usr/bin/perl
# SM1105 (0.15.6 test plan, R2): THE OUTBOX LIST SAYS WHAT HAPPENED TO AN ENTRY.
#
# The field report: "the rule's counters show sent 3. Inconsistency:
# notify-outbox-list for that rule still listed the three as queued with job
# 'refused' after they were sent." An entry the job has sent but could not
# remove (the unlink failed: a directory the job's account may read and not
# write) stays in the outbox, and the list showed it as queued - the ledger,
# which is what stops it going twice, knew better. The list now reads the
# ledger: such an entry is `sent`, is not counted as waiting, and the failed
# removal is logged. The job block carries refused_at, so a refusal is dated.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir repo_root run_cmd);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/auth" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: zz56-bell\n    type: notify\n    name: b\n    channels: bell\n"
    . "    recipients: [{\"accounts\":[\"zz56-bell\"]}]\n    unsubscribe: false\n"
    . "    per_recipient_hour: 10\n" );
run_cmd( $^X, repo_root() . '/tools/lazysite-users.pl', '--docroot', $d, 'add', 'zz56-bell', 'pw-123456789' );
$Lazysite::Handlers::DOCROOT = $d;
for ( 1 .. 3 ) {
    my $r = Lazysite::Handlers::deliver( 'zz56-bell', { post => "p$_" }, origin => 'form', source => 'form:c', actor => 'zz9member' );
    die 'not queued' unless $r->{ok} && $r->{queued};
}

my $before = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz56-bell' );
is_deeply( [ map { $_->{state} } @{ $before->{entries} } ], [ ('queued') x 3 ], 'before the job: three queued' );

# The job sends them but cannot remove the entries.
my $out = "$d/lazysite/notify/outbox";
chmod 0555, $out;
my $log = "$d/job.err";
open my $save, '>&', \*STDERR or die;
open STDERR, '>', $log or die;
my $run = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
open STDERR, '>&', $save or die;
chmod 0755, $out;
ok( $run->{ok}, 'the job ran' ) or diag explain $run;

my $after = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz56-bell' );
is_deeply( [ map { $_->{state} } @{ $after->{entries} } ], [ ('sent') x 3 ],
    'after the job: the entries it sent are listed as sent, not queued' ) or diag explain $after;

my $states = Lazysite::Outbox::rule_states($d);
is( $states->{'zz56-bell'}{queued}, 0, 'the rule\'s row counts none of them as queued' );
ok( !$states->{'zz56-bell'}{waiting}, 'and does not say it is waiting' );

open my $lg, '<', $log or die;
local $/;
my $logged = <$lg>;
like( $logged, qr/could not remove a sent notification/, 'the failed removal is logged' );

# A second run does not send them again, and removes them once it can.
my $run2 = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
ok( $run2->{ok}, 'a second run' );
my $final = Lazysite::Outbox::outbox_list( docroot => $d, rule => 'zz56-bell' );
is( scalar @{ $final->{entries} }, 0, 'the sent entries are gone once the directory can be written' );

done_testing();

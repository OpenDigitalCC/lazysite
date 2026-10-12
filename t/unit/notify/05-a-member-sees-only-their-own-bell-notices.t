#!/usr/bin/perl
# SM1020 (SM1010 F3): THE BELL HOLDS A NOTICE ADDRESSED TO ONE MEMBER AND SHOWS
# IT ONLY TO THEM.
#
# A notify rule with `channels: bell` writes one notice per recipient account,
# addressed with `to`. The bell's reader had no filter on `to`, so every holder
# of `notifications` would have seen every member's notices. Now an addressed
# notice reaches its addressee only; a broadcast is unchanged; and marking one
# read is refused for a notice the reader cannot see.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root site_tempdir run_cmd);
use Lazysite::Handlers         ();
use Lazysite::Outbox           ();
use Lazysite::Notify           ();
use Lazysite::Manager::Notices ();
use Lazysite::Data::Tables     qw(apply_schema insert_row);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\nplugins:\n  - plugins/data.pl\n" );
spit( "$d/lazysite/db/tables/subscriptions.yaml",
    "title: Subscriptions\ntimestamps: true\nfields:\n  post:\n    type: text\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: followers\n    type: notify\n    name: New comment\n"
        . "    channels: bell\n"
        . '    recipients: [{"owners_of":{"table":"subscriptions","where":{"post":"post"}}}]' . "\n"
        . "    unsubscribe_path: /account/following\n" );
run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, 'add', $_, 'pw-123456789' ) for qw(ann bob op);
$Lazysite::Handlers::DOCROOT = $d;
apply_schema( $d, 'subscriptions' );
insert_row( $d, 'subscriptions', { post => 'p1' }, actor => $_ ) for qw(ann bob);

Lazysite::Notify::notify( $d, { type => 'submission', message => 'A broadcast for the operators' } );
Lazysite::Handlers::deliver( 'followers', { post => 'p1', comment => 'hi' }, origin => 'form',
    source => 'form:comment', actor => 'someone' );
my $r = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
ok( $r->{ok}, 'the job ran' ) or diag explain $r;

$Lazysite::Manager::Notices::DOCROOT = $d;
sub seen_by { return [ map { $_->{message} } @{ Lazysite::Manager::Notices::action_notices( $_[0] )->{notices} } ] }

my $ann = seen_by('ann');
is( scalar( grep { /New comment/ } @$ann ), 1, 'ann sees her notice' );
my ($annotice) = grep { ( $_->{to} // '' ) eq 'ann' } @{ Lazysite::Manager::Notices::action_notices('ann')->{notices} };
ok( $annotice, 'addressed to her' );
is( scalar( grep { /New comment/ } @{ seen_by('bob') } ), 1, 'bob sees his - one, not ann\'s too' );
is( scalar( grep { /New comment/ } @{ seen_by('op') } ), 0,
    'an operator holding the bell sees neither member\'s notice' )
    or diag('SM1010 F3: the reader had no filter on to.');
is( scalar( grep { /broadcast/ } @{ seen_by('op') } ), 1, 'and still sees the broadcast' );

my $mark = Lazysite::Manager::Notices::action_notices_seen( 'op', id => $annotice->{id} );
is( $mark->{kind}, 'not-found', 'marking another member\'s notice read is refused as not found' );

like( do { local ( @ARGV, $/ ) = "$d/lazysite/logs/audit.log"; <> },
    qr/notify:followers -> bell \|  \| ok \| daemon \| account ann/, 'and each bell notice is an audit row' );

done_testing();

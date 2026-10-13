#!/usr/bin/perl
# SM1072 (SM1010 R3, Q5 as ruled): A NOTIFICATION RULE SAYS WHAT ITS QUEUE HOLDS,
# AND THE OUTBOX IS SHOWN IN THE MANAGER.
#
# Q5 was ruled as the brief recommended: delivery is queued only, and a site
# whose daemon is not running shows "waiting for the scheduler" on the
# handler's row rather than sending inline. R3 found the row showed nothing -
# no waiting, no last outcome - and the outbox and notify/failed/ were visible
# only on the filesystem.
#
# Here, the readers behind both: Lazysite::Outbox::rule_states (the row's
# counts, its last run and "waiting"), and outbox_list (the outbox: queued,
# retrying, held and failed events; with an id, who it resolves to and what was
# decided for each), with its may_see filter - the caller's domain rule, which
# t/integration/247 drives through both doors.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root site_tempdir run_cmd);
use Lazysite::Handlers     ();
use Lazysite::Outbox       ();
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:utf8', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my ( $D, $FAIL );

sub site {
    my (%rule) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables", "$d/lazysite/daemon" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\nplugins:\n  - plugins/data.pl\n" );
    $FAIL = "$d/fail-for";
    spit( "$d/sendmail", "#!$^X\n" . <<"MOCK" );
local \$/; my \$m = <STDIN>;
my (\$to) = \$m =~ /^To: (\\S+)/m;
if ( open my \$f, '<', '$FAIL' ) { my \$bad = <\$f>; chomp \$bad; exit 1 if \$bad eq \$to }
open my \$w, '>>', '$d/mail.out' or exit 1; print {\$w} "--MESSAGE--\\n", \$m; close \$w;
MOCK
    chmod 0755, "$d/sendmail";
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
    my %r = ( recipients => '[{"accounts":["ann","bob","zz9member"]}]', unsubscribe_path => '/account/following',
        per_recipient_hour => 1, %rule );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: followers\n    type: notify\n    name: Followers\n"
            . join( '', map { "    $_: $r{$_}\n" } sort keys %r ) );
    my $users = "$root/tools/lazysite-users.pl";
    for my $u (qw(ann bob zz9member)) {
        run_cmd( $^X, $users, '--docroot', $d, 'add', $u, 'pw-123456789' );
        run_cmd( $^X, $users, '--docroot', $d, 'set', $u, 'email', "$u\@example.net" );
    }
    $Lazysite::Handlers::DOCROOT = $d;
    $D = $d;
    return $d;
}

sub comment {
    my (%f) = @_;
    my $r = Lazysite::Handlers::deliver( 'followers', {%f}, origin => 'form', source => 'form:comment',
        actor => 'zz9member' );
    ok( $r->{ok} && $r->{queued}, 'an event is queued' ) or diag explain $r;
    return $r->{queued};
}
sub run_job { my (%o) = @_; return Lazysite::Outbox::run( docroot => $D, actor => 'jobs', %o ) }
sub runs    { spit( "$D/lazysite/daemon/scheduler-runs.json", JSON::PP::encode_json( { 'notify-outbox' => {@_} } ) ) }
sub state_of { return ( Lazysite::Outbox::rule_states( $D, $_[0] ) || {} )->{followers} || {} }
sub listing  { return Lazysite::Outbox::outbox_list( docroot => $D, @_ ) }

subtest 'a queued event: counted on the row, and waiting only when the scheduler is not taking it' => sub {
    site();
    comment( post => 'p1', comment => 'hello' );
    my $t = time;
    my $s = state_of( $t + 10 );
    is( $s->{queued}, 1, 'one queued' );
    ok( !$s->{waiting}, 'a fresh event is not called waiting' );

    like( state_of( $t + 600 )->{waiting}, qr/^waiting for the scheduler: the notify-outbox job has never run/,
        'ten minutes on, with no run record: waiting, and the job never ran' );

    runs( last_run => $t + 570, outcome => 'ok' );
    ok( !state_of( $t + 600 )->{waiting}, 'the job ran half a minute ago: not waiting' );

    runs( last_run => $t - 300, outcome => 'ok' );
    like( state_of( $t + 600 )->{waiting}, qr/last ran 15 minutes ago - is the daemon running\?/,
        'the job last ran fifteen minutes ago: waiting, and says when' );

    runs( last_run => $t - 300, outcome => 'refused', refusal_reason => 'jobs lacks manage_notifications' );
    like( state_of( $t + 600 )->{waiting}, qr/refuses the notify-outbox job - jobs lacks manage_notifications/,
        'the job is refused: waiting, and says why' );
};

subtest 'the row says what the last run did, and keeps the last failure' => sub {
    site();
    spit( $FAIL, 'bob@example.net' );
    comment( post => 'p1', comment => 'one' );
    run_job();
    my $s = state_of();
    is( $s->{queued},   1, 'the entry is kept for a retry' );
    is( $s->{retrying}, 1, 'and counted as retrying' );
    is( $s->{last}{sent},   1, 'last run: ann was sent' );
    is( $s->{last}{failed}, 1, 'last run: one failure' );
    like( $s->{last}{problem}, qr/^account bob - will retry: /, 'naming whom, and why' );
    ok( $s->{last}{problem_at}, 'and when' );

    unlink $FAIL;
    run_job( now => time + 3600 );
    $s = state_of( time + 3600 );
    is( $s->{queued}, 0, 'the retry went' );
    is( $s->{last}{sent}, 1, 'last run: bob was sent' );
    like( $s->{last}{problem}, qr/^account bob/, 'the last failure is kept until another replaces it' );
};

subtest 'held and failed are counted' => sub {
    site();
    comment( post => 'p1', comment => 'one' );
    run_job();
    comment( post => 'p1', comment => 'two' );
    run_job( now => time + 10 );
    is( state_of()->{held}, 2, 'a held message for each recipient past the cap' );

    comment( post => 'p1', comment => 'three' );
    spit( "$D/lazysite/forms/handlers.conf", "handlers: []\n" );
    run_job( now => time + 20 );
    my $s = ( Lazysite::Outbox::rule_states($D) || {} )->{followers};
    is( $s->{failed}, 3, 'the rule has gone: its entry and both held messages are counted as failed' );
    is( $s->{held},   0, 'and nothing is still held' );
};

subtest 'the outbox lists queued, retrying, held and failed' => sub {
    site();
    spit( $FAIL, 'bob@example.net' );
    my $id = comment( post => 'p1', comment => 'one' );
    run_job();
    my $l = listing();
    ok( $l->{ok}, 'it lists' ) or diag explain $l;
    my ($e) = @{ $l->{entries} };
    is( $e->{id},    $id,        'the event' );
    is( $e->{state}, 'retrying', 'retrying after the transport failed' );
    is( $e->{actor}, 'zz9member', 'who caused it' );
    is( $e->{fields}{comment}, 'one', 'and what it carries' );
    like( $e->{last_error}, qr/./, 'with the last error' );

    my $one = listing( id => $id );
    ok( $one->{ok}, 'one event, by id' ) or diag explain $one;
    my %who = map { $_->{who} => $_->{channels}{email} } @{ $one->{recipients}{list} };
    is_deeply( \%who, { 'account ann' => 'sent', 'account bob' => 'pending' },
        'who it resolves to, and what was decided for each - the actor left out' );

    unlink $FAIL;
    spit( "$D/lazysite/forms/handlers.conf", "handlers: []\n" );
    run_job( now => time + 3600 );
    $l = listing();
    ($e) = @{ $l->{entries} };
    is( $e->{state}, 'failed', 'given up: listed as failed' );
    like( $e->{reason}, qr/no rule 'followers'/, 'with the reason' );
};

subtest 'a held message is listed with its recipient' => sub {
    site();
    comment( post => 'p1', comment => 'one' );
    run_job();
    comment( post => 'p1', comment => 'two' );
    run_job( now => time + 10 );
    my @h = @{ listing()->{held} };
    is( scalar(@h), 2, 'one per recipient' );
    my ($ann) = grep { $_->{recipient} eq 'account ann' } @h;
    is( $ann->{events},  1,       'holding one event' );
    is( $ann->{state},   'held',  'held' );
    is( $ann->{channel}, 'email', 'for the email channel' );
};

subtest 'may_see decides what a caller is shown' => sub {
    site();
    my $id = comment( post => 'p1', comment => 'one' );
    my $none = listing( may_see => sub {0} );
    is( scalar @{ $none->{entries} }, 0, 'a rule the caller may not see: none of its events' );
    my $one = listing( id => $id, may_see => sub {0} );
    is( $one->{kind}, 'not-found', 'and its event by id is not found, not forbidden' );
    my $seen;
    listing( may_see => sub { $seen = $_[0]; 1 } );
    is( $seen->{id}, 'followers', 'may_see is asked with the rule\'s handler' );
    is( listing( rule => 'other' )->{entries}->@*, 0, 'rule narrows the list' );
    is( listing( id => 'nope' )->{kind}, 'invalid', 'an id that is not an event id is refused' );
};

done_testing();

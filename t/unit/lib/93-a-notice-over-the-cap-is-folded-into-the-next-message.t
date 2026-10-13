#!/usr/bin/perl
# SM1071 (SM1010 R1, Q7 as ruled): A NOTICE OVER THE CAP IS FOLDED INTO THE NEXT
# MESSAGE, NOT DROPPED.
#
# Q7 was ruled as the brief recommended: per event, one message per recipient per
# hour per rule, and the events past the cap folded into the next message. Phase
# 1 built the cap as a refusal: the second comment within the hour was audited
# and never reached anyone. Now it is held, every later one while something is
# held joins it in order, and when the recipient's hour moves on the job sends
# ONE message carrying them all - counted against the cap like any other.
#
# What else is held to: a held event is audited as held (neither sent nor
# refused); a retry of the same entry does not fold it twice; a recipient under
# the cap is not held up by somebody else's fold; a cap of 0 still sends
# nothing; a fold whose rule has gone is given up and audited; past the fold's
# size, an event is refused and says so.
#
# No network: the transport is the Form SMTP extension's sendmail method, and
# sendmail is a stub that appends what it is handed.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root site_tempdir run_cmd);
use Lazysite::Handlers     ();
use Lazysite::Outbox       ();
use Lazysite::Data::Tables qw(apply_schema insert_row);

binmode Test::More->builder->$_, ':utf8' for qw(output failure_output todo_output);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:utf8', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my ( $D, $OUT, $FAIL );

sub site {
    my (%rule) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables", "$d/lazysite/notify-templates" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\nplugins:\n  - plugins/data.pl\n" );
    $OUT  = "$d/mail.out";
    $FAIL = "$d/fail-for";
    spit( "$d/sendmail", "#!$^X\n" . <<"MOCK" );
local \$/; my \$m = <STDIN>;
my (\$to) = \$m =~ /^To: (\\S+)/m;
if ( open my \$f, '<', '$FAIL' ) { my \$bad = <\$f>; chomp \$bad; exit 1 if \$bad eq \$to }
open my \$w, '>>', '$OUT' or exit 1; print {\$w} "--MESSAGE--\\n", \$m; close \$w;
MOCK
    chmod 0755, "$d/sendmail";
    spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
    spit( "$d/lazysite/db/tables/subscriptions.yaml",
        "title: Subscriptions\ntimestamps: true\nfields:\n  post:\n    type: text\n" );
    my %r = ( recipients => '[{"owners_of":{"table":"subscriptions","where":{"post":"post"}}}]',
        unsubscribe_path => '/account/following', template => 'comment', per_recipient_hour => 1,
        channels => 'email,bell', %rule );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: followers\n    type: notify\n    name: Followers\n"
            . join( '', map { "    $_: $r{$_}\n" } sort keys %r ) );
    spit( "$d/lazysite/notify-templates/comment.email.tt",
        "Subject: New comment on [% fields.post %]\n\n[% actor %] wrote: [% fields.comment %]\n" );
    spit( "$d/lazysite/notify-templates/comment.bell.tt", "[% actor %]: [% fields.comment %]" );
    my $users = "$root/tools/lazysite-users.pl";
    for my $u (qw(ann bob zz9member)) {
        run_cmd( $^X, $users, '--docroot', $d, 'add', $u, 'pw-123456789' );
        run_cmd( $^X, $users, '--docroot', $d, 'set', $u, 'email', "$u\@example.net" );
    }
    $Lazysite::Handlers::DOCROOT = $d;
    apply_schema( $d, 'subscriptions' );
    insert_row( $d, 'subscriptions', { post => 'p1' }, actor => $_ ) for qw(ann zz9member);
    insert_row( $d, 'subscriptions', { post => 'p2' }, actor => 'bob' );
    $D = $d;
    return $d;
}

sub comment {
    my (%f) = @_;
    my $r = Lazysite::Handlers::deliver( 'followers', {%f}, origin => 'form', source => 'form:comment',
        actor => 'zz9member' );
    ok( $r->{ok} && $r->{queued}, "the comment '$f{comment}' is queued" ) or diag explain $r;
    return $r;
}

sub run_job { my (%o) = @_; return Lazysite::Outbox::run( docroot => $D, actor => 'jobs', %o ) }
sub messages { return grep { length } split /--MESSAGE--\n/, slurp($OUT) }
sub to_ann   { return grep { /^To: ann\@/m } messages() }
sub audit    { return grep { /\| notify \|/ } split /\n/, slurp("$D/lazysite/logs/audit.log") }
sub folds    { opendir my $dh, "$D/lazysite/notify/folds" or return (); return grep { /\.json\z/ } readdir $dh }
sub ann_bell { return grep { /"to":"ann"/ } split /\n/, slurp("$D/lazysite/logs/notices.jsonl") }

subtest 'the events past the cap reach the recipient in the next message, in order' => sub {
    site();
    my $t0 = time;
    comment( post => 'p1', comment => 'first' );
    run_job( now => $t0 );
    is( scalar( to_ann() ), 1, 'the first comment is sent' );

    comment( post => 'p1', comment => 'second' );
    comment( post => 'p1', comment => 'third' );
    my $r = run_job( now => $t0 + 60 );
    ok( $r->{ok}, 'the job ran' ) or diag explain $r;
    is( scalar( to_ann() ), 1, 'within the hour, nothing more is sent' );
    is( scalar( () = folds() ), 2, 'one held message for ann on each channel' );
    my @held = grep { /\| held \| daemon \| account ann - held: / } audit();
    is( scalar(@held), 4, 'each held event is one row per channel, said as held' );
    ok( ( grep { /the per-recipient cap \(1 an hour/ } @held ), 'the first names the cap' );
    ok( !( grep { /\| failed \| daemon \| account ann/ } audit() ), 'and none is a refusal' );

    run_job( now => $t0 + 1800 );
    is( scalar( to_ann() ), 1, 'still nothing while the hour lasts' );

    $r = run_job( now => $t0 + 3700 );
    ok( $r->{ok}, 'the job ran an hour on' ) or diag explain $r;
    my @m = to_ann();
    is( scalar(@m), 2, 'ann has ONE more message, not two' );
    like( $m[1], qr/zz9member wrote: second.*zz9member wrote: third/s, 'carrying both comments, in order' );
    like( $m[1], qr/^Subject: New comment on p1 \(and 1 more\)$/m, 'the Subject says one more is folded in' );
    is( scalar( () = $m[1] =~ /To stop these messages:/g ), 1, 'with one unsubscribe line' );
    like( $m[1], qr{^List-Unsubscribe: <https://news\.example/cgi-bin/lazysite-auth\.pl\?action=unsubscribe&t=v1\.}m, 'and the header' );
    is( scalar( () = folds() ), 0, 'the held messages are gone' );
    ok( ( grep { /\| ok \| daemon \| account ann - the held message, folding 2 events/ } audit() ),
        'the send is audited as the held message' );
    my @bell = ann_bell();
    is( scalar(@bell), 2, 'the bell folds the same way: one notice, then one more' );
    like( $bell[1], qr/2 updates: zz9member: second \/ zz9member: third/, 'carrying both' );
};

subtest 'the folded message counts against the cap' => sub {
    site();
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    comment( post => 'p1', comment => 'two' );
    run_job( now => $t0 + 10 );
    run_job( now => $t0 + 3700 );
    is( scalar( to_ann() ), 2, 'the held message went' );
    comment( post => 'p1', comment => 'three' );
    run_job( now => $t0 + 3800 );
    is( scalar( to_ann() ), 2, 'and the next comment within its hour is held again' );
    is( scalar( () = folds() ), 2, 'in a new fold' );
};

subtest 'while something is held, a later event joins it rather than overtaking it' => sub {
    site( channels => 'email' );
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    comment( post => 'p1', comment => 'two' );
    run_job( now => $t0 + 10 );
    # The hour has moved on, and a third comment is queued before the job runs:
    # the cap would allow it alone, but 'two' is waiting ahead of it.
    comment( post => 'p1', comment => 'three' );
    run_job( now => $t0 + 3700 );
    my @m = to_ann();
    is( scalar(@m), 2, 'one more message, not two' );
    like( $m[1], qr/wrote: two.*wrote: three/s, 'with the held comment first' );
};

subtest 'a retry of the same entry does not fold it twice' => sub {
    site( channels => 'email' );
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    spit( $FAIL, 'nobody@example.net' );
    comment( post => 'p1', comment => 'two' );
    # Run it twice before the hour: the ledger holds it as folded the first time.
    run_job( now => $t0 + 10 );
    run_job( now => $t0 + 20 );
    my ($fold) = folds();
    my $f = slurp("$D/lazysite/notify/folds/$fold");
    is( scalar( () = $f =~ /"comment":"two"/g ), 1, 'the event is in the fold once' );
};

subtest 'a recipient under the cap is not held up by another\'s fold' => sub {
    site( channels => 'email' );
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    comment( post => 'p1', comment => 'two' );
    run_job( now => $t0 + 10 );
    comment( post => 'p2', comment => 'for bob' );
    run_job( now => $t0 + 20 );
    ok( ( grep { /^To: bob\@/m } messages() ), 'bob is sent his at once' );
};

subtest 'a cap of 0 sends nothing and holds nothing' => sub {
    site( per_recipient_hour => 0, channels => 'email' );
    comment( post => 'p1', comment => 'one' );
    run_job();
    is( scalar( to_ann() ), 0, 'nothing is sent' );
    is( scalar( () = folds() ), 0, 'and nothing is held to send later' );
    ok( ( grep { /\| failed \| daemon \| account ann - the per-recipient cap \(0/ } audit() ),
        'it is a refusal naming the cap, as before' );
};

subtest 'a held message whose rule has gone is given up, and says so' => sub {
    site( channels => 'email' );
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    comment( post => 'p1', comment => 'two' );
    run_job( now => $t0 + 10 );
    spit( "$D/lazysite/forms/handlers.conf", "handlers: []\n" );
    run_job( now => $t0 + 3700 );
    is( scalar( to_ann() ), 1, 'nothing more is sent' );
    is( scalar( () = folds() ), 0, 'the fold is no longer waiting' );
    ok( -d "$D/lazysite/notify/failed", 'it is kept with the failed entries' );
    ok( ( grep { /\| failed \| daemon \| account ann - a held message is not sent: no rule 'followers'/ } audit() ),
        'and the audit says why' );
};

subtest 'past the fold\'s size, an event is refused and says so' => sub {
    site( channels => 'email' );
    no warnings 'once';
    local $Lazysite::Outbox::MAX_FOLDED = 2;
    my $t0 = time;
    comment( post => 'p1', comment => 'one' );
    run_job( now => $t0 );
    comment( post => 'p1', comment => $_ ) for qw(two three four);
    run_job( now => $t0 + 10 );
    ok( ( grep { /\| failed \| daemon \| account ann - the held message already folds 2 events/ } audit() ),
        'the third held event is refused, by name' );
    run_job( now => $t0 + 3700 );
    my @m = to_ann();
    like( $m[-1], qr/two.*three/s, 'the held message carries the two it holds' );
    unlike( $m[-1], qr/four/, 'and not the refused one' );
};

done_testing();

#!/usr/bin/perl
# SM1020 (SM1010 phase 1): THE NOTIFY-OUTBOX JOB SENDS WHAT A RULE QUEUED, ONCE
# EACH.
#
# The worked case of the brief: a comment on a followed post. The followers are
# the owners of `subscriptions` rows for the post; the commenter follows it too
# and is left out (notify_actor is off); a fixed address is added. Each gets one
# message, rendered from the rule's template with an RFC 2047 Subject, an
# unsubscribe line and a List-Unsubscribe header (ruled: per rule, default on),
# and each is one audit row naming the account or address.
#
# And what the engine guards, by ruling, is technical: a where whose field the
# event lacks matches nobody; the per-recipient cap the operator set refuses the
# next; a retry after a transport failure sends only to whoever did not get it;
# a ledger that will not open stops the run rather than risk sending twice.
#
# No network: the transport is the Form SMTP extension's sendmail method, and
# sendmail is a stub that appends what it is handed.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root site_tempdir run_cmd);
use Lazysite::Handlers     ();
use Lazysite::Outbox       ();
use Lazysite::Data::Tables qw(apply_schema insert_row);

binmode Test::More->builder->$_, ':utf8' for qw(output failure_output todo_output);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

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
    my %r = ( recipients => '[{"owners_of":{"table":"subscriptions","where":{"post":"post"}}},'
            . '{"fixed":["desk@news.example"]}]',
        unsubscribe_path => '/account/following', template => 'comment', from => 'news@news.example',
        %rule );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: followers\n    type: notify\n    name: Followers\n"
            . join( '', map { "    $_: $r{$_}\n" } sort keys %r ) );
    spit( "$d/lazysite/notify-templates/comment.email.tt",
        "Subject: Nouveau commentaire — [% fields.post %]\n\n"
            . "[% actor %] wrote on [% fields.post %]:\n\n[% fields.comment %]\n" );
    my $users = "$root/tools/lazysite-users.pl";
    for my $u (qw(ann bob carl zz9member)) {
        run_cmd( $^X, $users, '--docroot', $d, 'add', $u, 'pw-123456789' );
        run_cmd( $^X, $users, '--docroot', $d, 'set', $u, 'email', "$u\@example.net" ) unless $u eq 'carl';
    }
    $Lazysite::Handlers::DOCROOT = $d;
    apply_schema( $d, 'subscriptions' );
    insert_row( $d, 'subscriptions', { post => 'p1' }, actor => $_ ) for qw(ann bob carl zz9member);
    insert_row( $d, 'subscriptions', { post => 'p2' }, actor => 'ann' );
    $D = $d;
    return $d;
}

sub comment {
    my (%f) = @_;
    my $r = Lazysite::Handlers::deliver( 'followers', {%f}, origin => 'form', source => 'form:comment',
        actor => 'zz9member' );
    ok( $r->{ok} && $r->{queued}, 'the comment is queued' ) or diag explain $r;
    return $r;
}

sub run_job { my (%o) = @_; return Lazysite::Outbox::run( docroot => $D, actor => 'jobs', %o ) }

sub messages { return grep { length } split /--MESSAGE--\n/, slurp($OUT) }
sub to_list  { return sort { $a cmp $b } map { /^To: (\S+)/m ? $1 : '?' } messages() }
sub audit { return grep { /\| notify \|/ } split /\n/, slurp("$D/lazysite/logs/audit.log") }
sub outbox { opendir my $dh, "$D/lazysite/notify/outbox" or return (); return grep { /\.json\z/ } readdir $dh }

subtest 'the followers each get one message, and the commenter does not' => sub {
    site();
    comment( post => 'p1', comment => 'Très bien écrit.' );
    my $r = run_job();
    ok( $r->{ok}, 'the job ran' ) or diag explain $r;
    is_deeply( [ to_list() ], [qw(ann@example.net bob@example.net desk@news.example)],
        'ann, bob and the desk - not zz9member, who wrote it, and not carl, who has no address' );
    my @a = audit();
    is( scalar( grep { /\| ok \| daemon \| account (?:ann|bob)\b/ } @a ), 2, 'an ok audit row per account' );
    is( scalar( grep { /\| ok \| daemon \| address desk\@news\.example/ } @a ), 1, 'and one naming the address' );
    is( scalar( grep { /failed .*account carl - the account has no address/ } @a ), 1,
        'carl is a failed row saying why' );
    ok( !( grep { /zz9member/ } @a ), 'the commenter appears in no notify row' );
    is( scalar( () = outbox() ), 0, 'the entry is done and gone' );

    my ($m) = grep { /^To: ann\@/m } messages();
    like( $m, qr/^Subject: =\?UTF-8\?B\?[A-Za-z0-9+\/=]+\?=/m, 'the Subject is RFC 2047-encoded' );
    require MIME::Base64;
    my ($b64) = $m =~ /^Subject: =\?UTF-8\?B\?([^?]+)\?=/m;
    my $subj = MIME::Base64::decode_base64($b64);
    utf8::decode($subj);
    like( $subj, qr/\ANouveau commentaire — p1/, 'and decodes to what the template said' );
    like( $m, qr{^List-Unsubscribe: <https://news\.example/account/following>$}m, 'a List-Unsubscribe header' );
    like( $m, qr{To stop these messages: https://news\.example/account/following}, 'and the link in the body' );
    like( $m, qr/zz9member wrote on p1/,        'the template rendered the event' );
    like( $m, qr/^From: news\@news\.example$/m, 'from the rule\'s address' );
};

subtest 'a where whose field the event lacks matches nobody - never everybody' => sub {
    site();
    comment( comment => 'no post named' );
    run_job();
    is_deeply( [ to_list() ], ['desk@news.example'], 'only the fixed address' );
};

# SM1071 (SM1010 R1): past the cap the next is HELD for the next message, not
# refused - t/unit/lib/93 follows it to that message.
subtest 'the per-recipient cap holds the next back, and says so' => sub {
    site( per_recipient_hour => 1 );
    comment( post => 'p1', comment => 'one' );
    comment( post => 'p1', comment => 'two' );
    run_job();
    is( scalar( grep { $_ eq 'ann@example.net' } to_list() ), 1, 'ann gets one, not two' );
    ok( ( grep { /\| held \| daemon \| account ann - held: the per-recipient cap/ } audit() ),
        'the second is a held row naming the cap' );
};

subtest 'notify_actor sends to the commenter too' => sub {
    site( notify_actor => 'true' );
    comment( post => 'p1', comment => 'mine' );
    run_job();
    ok( ( grep { $_ eq 'zz9member@example.net' } to_list() ), 'the commenter is written to' );
};

subtest 'a retry after a transport failure sends only to whoever did not get it' => sub {
    site();
    spit( $FAIL, "bob\@example.net" );
    comment( post => 'p1', comment => 'retry' );
    my $r = run_job();
    is_deeply( [ to_list() ], [qw(ann@example.net desk@news.example)], 'bob\'s send failed' );
    is( scalar( () = outbox() ), 1, 'the entry is kept for a retry' );
    unlink $FAIL;
    run_job( now => time + 10 );
    is( scalar( () = outbox() ), 1, 'not before its back-off' );
    run_job( now => time + 3600 );
    is_deeply( [ to_list() ], [qw(ann@example.net bob@example.net desk@news.example)],
        'the retry reached bob - and ann and the desk were not sent twice' );
    is( scalar( () = outbox() ), 0, 'and the entry is done' );
};

subtest 'a ledger that will not open stops the run' => sub {
    plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;
    site();
    make_path("$D/lazysite/notify");
    spit( "$D/lazysite/notify/ledger.jsonl", '' );
    chmod 0000, "$D/lazysite/notify/ledger.jsonl";
    comment( post => 'p1', comment => 'x' );
    my $r = run_job();
    ok( !$r->{ok}, 'the run refuses' );
    like( $r->{error}, qr/could send twice/, 'saying why' );
    is( scalar( () = messages() ), 0, 'and nothing was sent' );
    chmod 0644, "$D/lazysite/notify/ledger.jsonl";
};

subtest 'unsubscribe on with no absolute site address fails the entry, visibly' => sub {
    site();
    spit( "$D/lazysite/lazysite.conf", "site_name: T\nplugins:\n  - plugins/data.pl\n" );
    comment( post => 'p1', comment => 'x' );
    run_job();
    is( scalar( () = messages() ), 0, 'nothing was sent' );
    ok( ( grep { /failed .*base_url/ } audit() ), 'and the audit says what to set' );
};

done_testing();

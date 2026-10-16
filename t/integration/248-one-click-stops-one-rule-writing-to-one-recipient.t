#!/usr/bin/perl
# SM1073 (SM1010 R4): ONE CLICK STOPS ONE RULE WRITING TO ONE RECIPIENT, WITH NO
# SIGN-IN.
#
# Ruled 2026-10-12 (SM1010), "Per rule, default on": each rule's messages carry
# an unsubscribe link and a List-Unsubscribe header unless the rule turns it
# off. Phase 1 pointed both at a page the operator had to write, and the engine
# recorded no refusal: the outbox job wrote to everyone it resolved, however
# often they asked to stop.
#
# End to end, through the real pieces: the outbox job mails the followers; the
# link in ann's message is followed through lazysite-auth.pl (the auth CGI, as
# SM1034 Q1 ruled for the session-less unsubscribe):
#
#   * GET shows a confirmation and changes nothing (mail scanners fetch links);
#   * POST stops it, and is audited; a second POST changes nothing and says so;
#   * a mail client's RFC 8058 one-click POST does the same;
#   * a token changed to name another recipient or another rule is refused,
#     audited, and stops nobody;
#   * the next event reaches bob and not ann, and ann's refusal is audited;
#   * ann still gets another rule's messages - the link stops its own rule only;
#   * a message held by the cap (SM1071) for ann is not sent once she stopped.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper             qw(repo_root site_tempdir run_cmd env_passthrough);
use Lazysite::Handlers     ();
use Lazysite::Outbox       ();
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:utf8', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables", "$d/lazysite/auth" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://news.example\nplugins:\n  - plugins/data.pl\n" );
spit( "$d/sendmail", "#!$^X\n" . <<"MOCK" );
local \$/; my \$m = <STDIN>;
open my \$w, '>>', '$d/mail.out' or exit 1; print {\$w} "--MESSAGE--\\n", \$m; close \$w;
MOCK
chmod 0755, "$d/sendmail";
spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );
spit( "$d/lazysite/forms/handlers.conf", "handlers:\n"
        . "  - id: followers\n    type: notify\n    name: Comments you follow\n"
        . "    recipients: [{\"accounts\":[\"ann\",\"bob\"]}]\n    per_recipient_hour: 2\n"
        . "  - id: digest\n    type: notify\n    name: Site news\n"
        . "    recipients: [{\"accounts\":[\"ann\"]}]\n" );
my $users = "$root/tools/lazysite-users.pl";
for my $u (qw(ann bob)) {
    run_cmd( $^X, $users, '--docroot', $d, 'add', $u, 'pw-123456789' );
    run_cmd( $^X, $users, '--docroot', $d, 'set', $u, 'email', "$u\@example.net" );
}
$Lazysite::Handlers::DOCROOT = $d;

my $clock = time;
sub event {
    my ( $rule, $text ) = @_;
    my $r = Lazysite::Handlers::deliver( $rule, { comment => $text }, origin => 'form', source => 'form:c', actor => '' );
    ok( $r->{queued}, "an event for $rule is queued" ) or diag explain $r;
    $clock += 10;
    my $j = Lazysite::Outbox::run( docroot => $d, actor => 'jobs', now => $clock );
    ok( $j->{ok}, 'the job ran' ) or diag explain $j;
    return;
}
sub messages { return grep { length } split /--MESSAGE--\n/, slurp("$d/mail.out") }
sub to       { my ($who) = @_; return grep { /^To: \Q$who\E\@/m } messages() }
sub audit    { return split /\n/, slurp("$d/lazysite/logs/audit.log") }

# The auth CGI, as the web server runs it.
sub auth {
    my ( $method, $query, $body ) = @_;
    $body //= '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => $method,
        QUERY_STRING   => $query,
        REDIRECT_URL   => '/cgi-bin/lazysite-auth.pl',
        CONTENT_LENGTH => length $body,
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => '192.0.2.77',
        HTTP_HOST      => 'news.example',
    );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-auth.pl" );
    print {$w} $body;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($status) = ( $out // '' ) =~ /^Status: (\d+)/m;
    return { status => $status // 0, out => $out // '' };
}

event( 'followers', 'first' );
my ($ann) = to('ann');
ok( $ann, 'ann has the first message' );
my ($link)  = $ann =~ m{^List-Unsubscribe: <(https://news\.example/cgi-bin/lazysite-auth\.pl\?([^>]+))>$}m;
my ($query) = $ann =~ m{^List-Unsubscribe: <https://news\.example/cgi-bin/lazysite-auth\.pl\?([^>]+)>$}m;
ok( $link, 'with a one-click link in its header' ) or diag $ann;
like( $ann, qr/^List-Unsubscribe-Post: List-Unsubscribe=One-Click$/m, 'and the RFC 8058 pair' );
like( $ann, qr/To stop these messages: \Q$link\E/, 'and the same link in the body' );
my ($bob) = to('bob');
my ($bob_query) = $bob =~ m{^List-Unsubscribe: <https://news\.example/cgi-bin/lazysite-auth\.pl\?([^>]+)>$}m;
isnt( $bob_query, $query, 'bob\'s link is not ann\'s' );

subtest 'GET asks, and changes nothing' => sub {
    my $r = auth( 'GET', $query );
    is( $r->{status}, 200, 'answered' );
    like( $r->{out}, qr/Stop these messages\?/, 'asking to confirm' );
    like( $r->{out}, qr/Comments you follow/, 'naming the rule' );
    like( $r->{out}, qr/<form method="post"/, 'with a form that posts' );
    like( $r->{out}, qr/^Referrer-Policy: no-referrer\r?$/m, 'and no Referer for the token to leak by' );
    like( $r->{out}, qr/^Cache-Control: no-store\r?$/m, 'not cached' );
    ok( !-e "$d/lazysite/notify/suppressed.jsonl", 'nothing was recorded' );
};

subtest 'a token changed to name another recipient or rule stops nobody' => sub {
    my ($ann_t) = $query =~ /t=(v1\.[^&]+)/;
    my ($bob_t) = $bob_query =~ /t=(v1\.[^&]+)/;
    my ( undef, $rule, $ap, $amac ) = split /\./, $ann_t;
    my ( undef, undef, $bp ) = split /\./, $bob_t;
    for my $case ( [ "v1.$rule.$bp.$amac", 'ann\'s MAC on bob' ], [ "v1.digest.$ap.$amac", 'ann\'s MAC on another rule' ] ) {
        my $r = auth( 'POST', "action=unsubscribe&t=$case->[0]", 'List-Unsubscribe=One-Click' );
        is( $r->{status}, 400, "$case->[1]: refused" );
        like( $r->{out}, qr/not valid/, '...saying the link is not valid' );
    }
    ok( !-e "$d/lazysite/notify/suppressed.jsonl", 'nothing was recorded' );
    is( scalar( grep { /\| unsubscribe \| notify \| 192\.0\.2\.77 \| denied \| ui \| the link is not valid/ } audit() ), 2,
        'and each refusal is audited' );
};

subtest 'POST stops it, once, and is audited' => sub {
    my $r = auth( 'POST', $query, 'confirm=1' );
    is( $r->{status}, 200, 'answered' );
    like( $r->{out}, qr{<h1>Unsubscribed</h1>}, 'the first POST says Unsubscribed' );
    like( $r->{out}, qr/no more messages from \S+Comments you follow/, 'saying so' );
    my @a = grep { /\| unsubscribe \| notify:followers \|/ } audit();
    is( scalar(@a), 1, 'one audit row' );
    like( $a[0], qr/\| ok \| ui \| recipient [0-9a-f]{24}$/, 'naming the recipient\'s hash, never an address' );

    $r = auth( 'POST', $query, 'List-Unsubscribe=One-Click' );
    is( $r->{status}, 200, 'a mail client\'s one-click POST of the same link is answered the same' );
    # SM1106 (0.15.6 R3): "a repeat POST shows the same 'Unsubscribed' page, not
    # 'already stopped'" - the repeat is the GET's answer, still 200.
    like( $r->{out}, qr{<h1>Already stopped</h1>}, 'and the repeat says it is already stopped, not "Unsubscribed" again' );
    unlike( $r->{out}, qr/Unsubscribed/, '...and does not claim to have just stopped it' );
    like( $r->{out}, qr/Comments you follow/, '...naming the rule' );
    my @lines = split /\n/, slurp("$d/lazysite/notify/suppressed.jsonl");
    is( scalar(@lines), 1, 'and recorded nothing more' );
    ok( ( grep { /\| ok \| ui \| recipient [0-9a-f]{24} - already stopped$/ } audit() ), 'the repeat is audited as such' );
    like( auth( 'GET', $query )->{out}, qr/already stopped/, 'GET now says it is already stopped' );
};

subtest 'the next event reaches bob, and not ann' => sub {
    event( 'followers', 'second' );
    is( scalar( to('bob') ), 2, 'bob has the second message' );
    is( scalar( to('ann') ), 1, 'ann does not' );
    ok( ( grep { /\| notify \| notify:followers -> email \|.*\| failed \| daemon \| account ann - unsubscribed:/ } audit() ),
        'ann\'s refusal is audited, saying why' );
};

subtest 'it stops its own rule only' => sub {
    event( 'digest', 'news' );
    is( scalar( to('ann') ), 2, 'ann still gets another rule\'s message' );
};

subtest 'a message held by the cap is not sent after the stop' => sub {
    # bob's link stops bob; bob has a message held for him first.
    event( 'followers', 'third' );     # bob: 3rd in the hour -> held (cap 2)
    ok( ( grep { /account bob - held:/ } audit() ), 'bob\'s third is held' );
    my $r = auth( 'POST', $bob_query, 'List-Unsubscribe=One-Click' );
    is( $r->{status}, 200, 'bob stops it' );
    $clock += 3700;
    Lazysite::Outbox::run( docroot => $d, actor => 'jobs', now => $clock );
    is( scalar( to('bob') ), 2, 'the held message is not sent' );
    ok( ( grep { /account bob - a held message is not sent: unsubscribed/ } audit() ), 'and the audit says why' );
};

subtest 'a store of stops that will not open sends nothing' => sub {
    plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;
    my $before = scalar messages();
    chmod 0000, "$d/lazysite/notify/suppressed.jsonl";
    Lazysite::Handlers::deliver( 'digest', { comment => 'more news' }, origin => 'form', source => 'form:c', actor => '' );
    my $j = Lazysite::Outbox::run( docroot => $d, actor => 'jobs', now => $clock + 7200 );
    chmod 0644, "$d/lazysite/notify/suppressed.jsonl";
    ok( !$j->{ok}, 'the run refuses' );
    like( $j->{error} // '', qr/someone who said stop/, 'saying why' );
    is( scalar messages(), $before, 'and nothing was sent' );
};

done_testing;

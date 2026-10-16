#!/usr/bin/perl
# SM957 / SM1097: the bell is the one indicator of a new submission, asked of a
# browser.
#
# SM957 gave the Submissions menu entry an unread-count bubble beside the bell.
# The 0.15.5 test plan (2026-10-16): "the menu's submission bubble does not say
# which form has the new submission, and the bell shows the same events: two
# indicators for one thing." The release manager ruled "bell stays", so the
# bubble is gone (SM1097) and this test, which pinned it, now pins its absence
# and keeps what the bell itself must still do: its badge counts every unread
# notice, moves when a notice is followed - from the panel or from a
# Submissions row - and is not there for an account the bell refuses. And the
# mark is a POST: the bell sent it as a GET, which the API refuses, so until
# n265 no mark it made was kept.
#
# The layout is RENDERED (every grant, so the count element exists), its head
# scripts and its menu and bell markup are loaded headless, and `fetch` is a stub
# put in front of the layout's own wrapper, recording what the page sent.
use strict;
use warnings;
use Test::More;
use Template;
use File::Temp ();
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

chomp( my $browser = `sh -c 'command -v chromium || command -v chromium-browser' 2>/dev/null` );
plan skip_all => 'no chromium on this host: the Submissions count was NOT checked in a browser '
    . '(install chromium to restore this)'
    unless length $browser;

my $tt  = Template->new( ABSOLUTE => 1, EVAL_PERL => 0 );
my $out = '';
$tt->process(
    File::Spec->catfile( repo_root(), qw(starter lazysite manager layout.tt) ),
    { page_title => 'T',
        site_name        => 'Demo',
        request_uri      => '/manager/files',
        enabled_plugins  => {},
        auth_user        => 'op',
        authenticated    => 1,
        content          => '',
        lazysite_version => '0.0.0',
        manager_caps => { map { $_ => 1 } qw(read_submissions notifications manage_content) },
    },
    \$out
) or die 'TT: ' . $tt->error;

my ($head)  = $out            =~ m{<head>(.*?)</head>}s;
my @scripts = ( $head // '' ) =~ m{(<script>.*?</script>)}sg;
my ($nav)   = $out            =~ m{(<nav class="mg-nav".*?</nav>)}s;
my ($bell)  = $out =~ m{(<div class="mg-notif" id="mg-notif">.*?</div>\s*</div>)}s;
ok( scalar @scripts,                     'the layout head scripts' );
ok( $nav, 'the menu' );
unlike( $out, qr/mg-nav-subs-count|mg-nav-count/, 'SM1097: no submission bubble anywhere in the layout' );
ok( $bell,                               'the bell' ) or done_testing(), exit;

my $FILE    = 'lazysite/forms/submissions/contact.jsonl';
my %NOTICES = (
    ok             => 1,
    unread         => 2,
    unread_by_type => { submission => 1, 'reset-request' => 1 },
    notices        => [
        { id => 'aaaaaaaaaaaa', type => 'submission', read => JSON::PP::false, ts => time() - 60,
            message => 'New form submission: contact',
            url     => "/manager/submission?file=$FILE&id=1111111111111111" },
        { id => 'bbbbbbbbbbbb', type => 'submission', read => JSON::PP::true, ts => time() - 120,
            message => 'New form submission: contact',
            url     => "/manager/submission?file=$FILE&id=2222222222222222" },
        { id => 'cccccccccccc', type => 'reset-request', read => JSON::PP::false, ts => time() - 30,
            message => 'a reset was asked for' },
    ],
);

# Scratch for the pages and browser profiles - not a docroot; nothing of the
# engine runs here.
my $dir = File::Temp->newdir;

# One page per scenario. `act` runs once the bell has loaded its notices.
sub scenario {
    my ( $name, $answer, $act ) = @_;
    my $json = encode_json($answer);
    my $page = File::Spec->catfile( $dir, "$name.html" );
    open my $o, '>', $page or die $!;
    print {$o} "<!doctype html><html><head><title>pending</title>\n<script>\n",
        "window.SENT = [];\n",
        "window.fetch = function (u, init) {\n",
        "  u = String(u); init = init || {};\n",
        "  window.SENT.push({ url: u, method: (init.method || 'GET').toUpperCase() });\n",
        "  var body = /action=notices(&|\$)/.test(u) ? $json\n",
        "           : /action=notices-seen/.test(u) ? { ok: 1, unread: 0 } : { ok: 1, token: 't' };\n",
        "  return Promise.resolve(new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } }));\n",
        "};\n</script>\n",
        @scripts, "\n</head><body>\n$nav\n$bell\n",
        "<script>\n",
        "window.addEventListener('click', function (e) { e.preventDefault(); });\n",
        "function report(r) {\n",
        "  var c = document.getElementById('mg-notif-badge');\n",
        "  r.count = c ? (c.hidden ? 'hidden' : c.textContent) : 'absent';\n",
        "  r.bubble = document.getElementById('mg-nav-subs-count') ? 'present' : 'absent';\n",
        "  r.bell = document.getElementById('mg-notif') ? 'present' : 'gone';\n",
        "  return r;\n}\n",
        "window.addEventListener('load', function () { setTimeout(function () {\n",
        "  var r = { before: report({}).count };\n",
        "  try { $act } catch (e) { r.threw = String(e); }\n",
        "  setTimeout(function () {\n",
        "    report(r);\n",
        "    r.seen = window.SENT.filter(function (s) { return /notices-seen/.test(s.url); });\n",
        "    document.title = JSON.stringify(r);\n",
        "  }, 200);\n",
        "}, 300); });\n</script>\n</body></html>\n";
    close $o;
    my $dom = `timeout 60 \Q$browser\E --headless=new --no-sandbox --disable-gpu --user-data-dir=\Q$dir/profile-$name\E --virtual-time-budget=5000 --dump-dom file://\Q$page\E 2>/dev/null`;
    my ($title) = $dom =~ m{<title>([^<]*)</title>};
    return undef unless defined $title && $title ne 'pending';
    $title =~ s/&quot;/"/g;
    $title =~ s/&lt;/</g;
    $title =~ s/&gt;/>/g;
    $title =~ s/&amp;/&/g;
    return eval { decode_json($title) } // { raw => $title };
}

my $none = scenario( 'none', \%NOTICES, '' );
plan skip_all => 'chromium did not render the page' unless $none;

is( $none->{before}, '2', 'the bell counts every unread notice - the submission and the reset request' )
    or diag explain $none;
is( $none->{bubble}, 'absent', 'and the menu draws no second count' );

my $panel = scenario( 'panel', \%NOTICES,
    "window.mgToggleNotif(); document.querySelector('[data-notif-open=\"aaaaaaaaaaaa\"]').click();" );
is( $panel->{count}, '1', 'following the notice from the bell moves the bell count' ) or diag explain $panel;
is_deeply( [ map { [ $_->{method}, $_->{url} =~ /(id=\w+)/ ] } @{ $panel->{seen} } ], [ [ 'POST', 'id=aaaaaaaaaaaa' ] ],
    'and marks THAT notice, as a POST - the API refuses a write sent as a GET' );

my $row = scenario( 'row', \%NOTICES, "window.mgNoticeFollowed('$FILE', '1111111111111111');" );
is( $row->{count}, '1', 'opening that row from the Submissions page moves it too' ) or diag explain $row;
is_deeply( [ map { [ $_->{method}, $_->{url} =~ /(id=\w+)/ ] } @{ $row->{seen} } ], [ [ 'POST', 'id=aaaaaaaaaaaa' ] ],
    'marking the notice whose link names that store and row' );

my $other = scenario( 'other', \%NOTICES, "window.mgNoticeFollowed('$FILE', '9999999999999999');" );
is( $other->{count}, '2', 'a row no notice names marks nothing' ) or diag explain $other;
is( scalar @{ $other->{seen} }, 0, 'and sends nothing' );

my $all = scenario( 'all', \%NOTICES, "window.mgToggleNotif(); document.querySelector('[data-notif-all]').click();" );
is( $all->{count}, 'hidden', 'mark all read clears the bell' ) or diag explain $all;

my $refused = scenario( 'refused', { ok => 0, kind => 'forbidden', error => 'no' }, '' );
is( $refused->{before}, 'absent', 'no notifications grant: no bell badge' ) or diag explain $refused;
is( $refused->{bubble}, 'absent', 'and no bubble' );
is( $refused->{bell}, 'gone', 'and no bell, as before' );

my $zero = scenario( 'zero', { ok => 1, unread => 0, unread_by_type => {}, notices => [] }, '' );
is( $zero->{before}, 'hidden', 'nothing unread: the bell badge is hidden, not a 0' );

done_testing();

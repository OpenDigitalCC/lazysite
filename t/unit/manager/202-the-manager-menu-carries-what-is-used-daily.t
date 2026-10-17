#!/usr/bin/perl
# SM957: the manager menu carries what an operator uses daily.
#
# The release manager (2026-10-07): "submissions are found by navigating to
# extension config. they should be easier to find, maybe on the menu. handlers
# doesnt need to be on the menu as it isn't every day used." Ruled: M1-M7,
# Handlers off the menu, an unread count on Submissions.
#
# THE MENU IS ASKED OF THE REAL LAYOUT, rendered, for an account holding every
# grant and for one holding none - its groups, their entries in order, what each
# links to, and which are locked with what reason. A menu read as template text
# would pass with both branches of every IF present at once.
#
# And three things that have to agree with it: the command palette (the other
# list of manager pages), the one submissions viewer (moved, not copied - the old
# address redirects), and the viewer's order (newest first).
use strict;
use warnings;
use Test::More;
use Template;
use File::Temp ();
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript qw(extract_function page_source);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";

my @EVERY = qw(manage_config manage_domains manage_users manage_content manage_nav
    manage_themes manage_layouts audit manage_data manage_connectors manage_forms
    read_submissions notifications);

sub render {
    my (%v) = @_;
    my $tt  = Template->new( ABSOLUTE => 1, EVAL_PERL => 0 );
    my $out = '';
    $tt->process(
        $layout,
        { page_title => 'T',
            site_name        => 'Demo',
            request_uri      => '/manager/files',
            enabled_plugins  => { data => 1, stats => 1 },
            auth_user        => 'me',
            authenticated    => 1,
            content          => 'BODY',
            lazysite_version => '0.0.0',
            manager_caps     => {},
            %v,
        },
        \$out
    ) or die 'TT: ' . $tt->error;
    return $out;
}

# The nav as data: [ group, label, element, href, class, title, html ] per entry.
sub menu {
    my ($html) = @_;
    my ($nav)  = $html =~ m{(<nav class="mg-nav".*?</nav>)}s or return;
    my ( $group, @e ) = ('');
    for my $line ( split /\n/, $nav ) {
        if ( $line =~ m{<div class="mg-nav-group">([^<]*)</div>} ) { $group = $1; next }
        next unless $line =~ m{^\s*<(a|span)\b([^>]*)>(.*)</\1>\s*$};
        my ( $tag, $attrs, $inner ) = ( $1, $2, $3 );
        ( my $label = $inner ) =~ s/<[^>]*>.*?<\/[^>]*>//g;
        $label                 =~ s/&amp;/&/g;
        $label                 =~ s/&#?\w+;//g;
        $label                 =~ s/^\s+|\s+$//g;
        my ($href)  = $attrs =~ /href="([^"]*)"/;
        my ($class) = $attrs =~ /class="([^"]*)"/;
        my ($title) = $attrs =~ /title="([^"]*)"/;
        push @e, { group => $group, label => $label, tag => $tag, href => $href // '',
            class => $class // '', title => $title // '', html => $line };
    }
    return @e;
}

# The palette's destinations as rendered: [label, url] pairs.
sub palette {
    my ($html) = @_;
    my ($list) = $html =~ /window\.MG_DESTINATIONS = \[(.*?)\n  \];/s or return;
    my @d;
    while ( $list =~ /\{ label: '([^']*)',\s*url: '([^']*)' \}/g ) { push @d, [ $1, $2 ] }
    return @d;
}

my @SHAPE = (
    [ Site   => 'Submissions',        '/manager/submissions' ],
    [ Site   => 'Files',              '/manager/files' ],
    [ Site   => 'Navigation',         '/manager/nav' ],
    [ Site   => 'Visitor statistics', '/manager/stats' ],
    [ Setup  => 'Appearance',         '/manager/appearance' ],
    [ Setup  => 'Extensions',         '/manager/plugins' ],
    [ Setup  => 'Connectors',         '/manager/connectors' ],
    [ Setup  => 'Data tables',        '/manager/data' ],
    [ Setup  => 'Domains',            '/manager/domains' ],
    [ Access => 'Users',              '/manager/users' ],
    [ Access => 'Groups',             '/manager/groups' ],
    [ Access => 'Address lists',      '/manager/address-lists' ],    # SM1138
    [ Access => 'Sessions & keys',    '/manager/sessions' ],
    [ System => 'Site settings',      '/manager' ],
    [ System => 'Cache',              '/manager/cache' ],
    [ System => 'Backups',            '/manager/backups' ],
    [ System => 'Audit log',          '/manager/audit' ],
);

subtest 'every grant: the ruled groups, entries and order, every one a link' => sub {
    my $html = render( manager_caps => { map { $_ => 1 } @EVERY } );
    my @m    = menu($html);
    is_deeply( [ map { [ $_->{group}, $_->{label}, $_->{href} ] } @m ], \@SHAPE,
        'Site, Setup, Access, System - in the ruled order' )
        or diag explain [ map { "$_->{group} / $_->{label} -> $_->{href}" } @m ];
    is( scalar( grep { $_->{class} =~ /mg-nav-locked/ } @m ), 0, 'nothing is locked' );
    my ($nav) = $html =~ m{(<nav class="mg-nav".*?</nav>)}s;
    unlike( $nav, qr{/manager/handlers|>Handlers}, 'Handlers is OFF the menu (ruling, M5)' );
    unlike( $nav, qr{/manager/plugin-config|Extension (?:Manager|Config)},
        'and the two extension entries are one, "Extensions" (M4)' );
    unlike( $m[0]{html}, qr{mg-nav-count|mg-nav-subs-count},
        'SM1097: Submissions carries no bubble - the bell is the one indicator of a new submission' );
};

subtest 'no grant: the same entries, the gated ones locked with their reasons' => sub {
    my $html = render( manager_caps => {} );
    my @m    = menu($html);
    is_deeply( [ map { [ $_->{group}, $_->{label} ] } @m ], [ map { [ @$_[ 0, 1 ] ] } @SHAPE ],
        'every entry is still there, in the same place (M7: locked, not hidden)' );
    my %locked = map { $_->{label} => $_ } grep { $_->{class} =~ /\bmg-nav-locked\b/ } @m;
    is_deeply( [ sort keys %locked ],
        [ sort 'Submissions', 'Files', 'Navigation', 'Appearance', 'Connectors',
            'Data tables', 'Domains', 'Audit log' ],
        'the capability-gated entries are the locked ones' );
    for my $l ( sort keys %locked ) {
        is( $locked{$l}{tag}, 'span', "$l: a span, not a link - this account cannot act on it" );
        like( $locked{$l}{title}, qr/This account does not hold the capability it needs; a user manager can grant it\.\z/,
            "$l: the reason says so" );
        like( $locked{$l}{html}, qr/<span class="mg-nav-lock" tabindex="0" role="img" aria-label="Not available to this account">/,
            "$l: and carries the focusable lock" );
    }
    like( $locked{Submissions}{title}, qr/\ARead what visitors have sent through the site's forms\./,
        'Submissions says what it is' );
    unlike( ( $html =~ m{(<nav class="mg-nav".*?</nav>)}s )[0], qr/mg-nav-subs-count/, 'and there is no count for an account that cannot read submissions' );
};

subtest 'a user manager without the grants is told which grant opens each' => sub {
    my @m = menu( render( manager_caps => { manage_users => 1 } ) );
    my ($s) = grep { $_->{label} eq 'Submissions' } @m;
    is( $s->{href}, '/manager/groups', 'Submissions, locked, points at the Groups page' );
    like( $s->{title}, qr/grant 'Read form submissions' to a group on the Groups page/,
        'naming the grant as the Groups page labels it' );
};

subtest 'with the notifications grant too, the entry still has no bubble (SM1097)' => sub {
    my $html = render( manager_caps => { read_submissions => 1 } );
    like( $html, qr{<a href="/manager/submissions"}, 'read_submissions alone: the link' );
    unlike( ( $html =~ m{(<nav class="mg-nav".*?</nav>)}s )[0], qr/mg-nav-subs-count/, 'and none without notifications' );
    my $h2 = render( manager_caps => { read_submissions => 1, notifications => 1 } );
    unlike( ( $h2 =~ m{(<nav class="mg-nav".*?</nav>)}s )[0], qr/mg-nav-subs-count/, 'nor with it - the bell carries that' );
};

subtest 'one entry lights for both extension pages' => sub {
    for my $uri (qw(/manager/plugins /manager/plugin-config)) {
        my ($x) = grep { $_->{label} eq 'Extensions' } menu( render( request_uri => $uri ) );
        like( $x->{html}, qr/class="active" aria-current="page"/, "$uri: Extensions is current" );
    }
};

subtest 'the palette lists exactly what the menu links to, in its order' => sub {
    for my $case ( [ 'every grant', { map { $_ => 1 } @EVERY } ], [ 'no grant', {} ] ) {
        my $html = render( manager_caps => $case->[1] );
        my @links = map { [ $_->{label}, $_->{href} ] } grep { $_->{tag} eq 'a' && $_->{class} !~ /mg-nav-locked/ } menu($html);
        my @pal = grep { $_->[1] =~ m{\A/manager} } palette($html);
        is_deeply( \@pal, \@links, "$case->[0]: palette and menu agree" )
            or diag explain { palette => \@pal, menu => \@links };
    }
};

# --- ONE viewer -------------------------------------------------------------
my $pc   = page_source("$root/starter/manager/plugin-config.md");
my $subs = page_source("$root/starter/manager/submissions.md");

subtest 'the viewer lives on the Submissions page and nowhere else' => sub {
    for my $fn ( qw(showSubmissionTable subsNode setSubsBody deleteSubmissionRow
        approveSubmissionRow confirmSubmissionRow bulkDeleteSubmissions downloadSubmissionsCsv) ) {
        ok( defined PageScript::try_extract( $subs, $fn ), "submissions.md has $fn" );
        ok( !defined PageScript::try_extract( $pc, $fn ), "plugin-config.md keeps no copy of $fn" );
    }
    like( $pc, qr{<a class="mg-btn mg-btn-sm" href="/manager/submissions">Submissions</a>},
        'the form handler row links to the page' );
    like( page_source("$root/starter/manager/handlers.md"), qr{/manager/submissions\?form='},
        'each form on Handlers links to its submissions' );
    like( page_source("$root/starter/manager/submission.md"), qr{'/manager/submissions\?store='},
        'and one submission links back to its store on the page' );
};

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed: the redirect, the boot and the order were NOT run', 3
        unless length $node && -x $node;
    my $dir = File::Temp->newdir;

    my $run = sub {
        my ($js) = @_;
        open my $o, '>', "$dir/t.js" or die $!;
        print {$o} $js;
        close $o;
        my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
        return eval { decode_json($raw) } || { error => $raw };
    };

    subtest 'the old address redirects to the page, carrying the store' => sub {
        my $fn = extract_function( $pc, 'redirectLegacySubmissions', 'plugin-config.md' );
        my $r  = $run->( $fn . <<'JS' );

var out = {};
function loc(s) { return { search: s, replace: function (u) { out[s] = u; } }; }
out.legacy = redirectLegacySubmissions(loc('?submissions=%2Flazysite%2Fforms%2Fsubmissions%2F'));
out.plain  = redirectLegacySubmissions(loc(''));
console.log(JSON.stringify(out));
JS
        ok( $r->{legacy}, '?submissions= is a redirect' ) or diag explain $r;
        is( $r->{'?submissions=%2Flazysite%2Fforms%2Fsubmissions%2F'},
            '/manager/submissions?store=%2Flazysite%2Fforms%2Fsubmissions%2F', 'to the page, the store unchanged' );
        ok( !$r->{plain} && !exists $r->{''}, 'and the configuration page itself is not redirected' );
    };

    subtest 'the address chooses a store, or every form' => sub {
        my $fn = extract_function( $subs, 'subsBoot', 'submissions.md' );
        my $r  = $run->( $fn . <<'JS' );

var CALLS = [];
function loadStore(d) { CALLS.push(['store', d]); }
function loadForms(w) { CALLS.push(['forms', w]); }
function showStatus(m) { CALLS.push(['status']); }
var out = {};
out.store = subsBoot('?store=%2Flazysite%2Fforms%2Fsubmissions%2F');
out.bad   = subsBoot('?store=%2F..%2Fetc%2F');
out.form  = subsBoot('?form=contact');
out.none  = subsBoot('');
out.calls = CALLS;
console.log(JSON.stringify(out));
JS
        is_deeply( $r->{calls}, [ [ 'store', '/lazysite/forms/submissions/' ], ['status'], [ 'forms', '' ],
                [ 'forms', 'contact' ], [ 'forms', '' ] ],
            'a valid store is read; a store with .. is refused and every form shown; ?form= is passed on' )
            or diag explain $r;
    };

    subtest 'newest first, and each row opens its own page' => sub {
        my $defs = join "\n", map { extract_function( $subs, $_, 'submissions.md' ) }
            qw(subsNode subsMessage setSubsBody showSubmissionTable);
        my $r = $run->( <<'DOM' . $defs . <<'JS' );
function Node(tag) { this.tag = tag; this.children = []; this.handlers = {}; this._text = null; }
Node.prototype.appendChild = function (c) {
  if (c.tag === '#fragment') { c.children.forEach(function (k) { this.children.push(k); }, this); }
  else this.children.push(c);
  return c;
};
Node.prototype.setAttribute = function () {};
Node.prototype.addEventListener = function (ev, fn) { this.handlers[ev] = fn; };
Object.defineProperty(Node.prototype, 'textContent', {
  get: function () { return this._text != null ? this._text : this.children.map(function (c) { return c.textContent; }).join(''); },
  set: function (v) { this.children = []; this._text = String(v); }
});
var BODY = new Node('div'), TITLE = new Node('strong');
var document = {
  createElement: function (t) { return new Node(t); },
  createTextNode: function (s) { var n = new Node('#text'); n._text = String(s); return n; },
  createDocumentFragment: function () { return new Node('#fragment'); },
  getElementById: function (id) { return id === 'subs-body' ? BODY : id === 'subs-title' ? TITLE : null; }
};
function walk(n, fn) { fn(n); n.children.forEach(function (c) { walk(c, fn); }); }
var API = '/api', subsFilter = 'all', subsCurrent = null, subsLoaded = null, FOLLOWED = [];
var window = { mgNoticeFollowed: function (f, id) { FOLLOWED.push([f, id]); } };
function deleteSubmissionRow() {} function confirmSubmissionRow() {} function approveSubmissionRow() {}
function setSubsFilter() {} function downloadSubmissionsCsv() {} function bulkDeleteSubmissions() {} function subsToggleAll() {}
DOM
var URLS = [];
var fetch = function (u) {
  URLS.push(u);
  return Promise.resolve({ json: function () { return Promise.resolve({ ok: 1, total: 2, shown: 2,
    file: 'lazysite/forms/submissions/contact.jsonl', columns: ['name'],
    rows: [ { _id: 'aaaaaaaaaaaaaaaa', name: 'older' }, { _id: 'bbbbbbbbbbbbbbbb', name: 'newer' } ] }); } });
};
showSubmissionTable('', 'contact');
setTimeout(function () {
  var names = [], opens = [];
  walk(BODY, function (n) {
    if (n.tag === 'tr' && n.children[2] && n.children[2].tag === 'td') names.push(n.children[2].textContent);
    if (n.tag === 'a' && n._text === 'Open') opens.push(n);
  });
  if (opens[0]) opens[0].handlers.click();
  console.log(JSON.stringify({ names: names, hrefs: opens.map(function (a) { return a.href; }),
    urls: URLS, followed: FOLLOWED }));
}, 0);
JS
        is_deeply( $r->{names}, [ 'newer', 'older' ], 'the newest row is first' ) or diag explain $r;
        like( $r->{urls}[0] // '', qr/action=form-submissions&form=contact\z/, 'a form is read by its name' );
        is( $r->{hrefs}[0],
            '/manager/submission?file=lazysite%2Fforms%2Fsubmissions%2Fcontact.jsonl&id=bbbbbbbbbbbbbbbb',
            'a row opens the page a notice links to - the store the server named, and the row' );
        is_deeply( $r->{followed}, [ [ 'lazysite/forms/submissions/contact.jsonl', 'bbbbbbbbbbbbbbbb' ] ],
            'and following it hands that row to the bell, which marks its notice read' );
    };
}

done_testing();

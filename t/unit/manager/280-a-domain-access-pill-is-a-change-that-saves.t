#!/usr/bin/perl
# SM1013: on the Domains page, adding or removing a group or user pill in the
# Access section is a change that Save posts.
#
# Reported by the release manager on 2026-10-12, upgrading a site to 0.15.4:
# "adding group to domains, then press save - message: Nothing had changed."
# The dirty map's reader, cfgValueOf(), recognised the token picker by a class
# called 'mg-token-box'; tokenPicker() draws it as '.mg-tokens'. So the picker
# read as '' when the sheet opened AND when Save was pressed, saveDomain skipped
# it as unchanged, and the change was thrown away with a message saying there
# was none.
#
# The page's own functions are run under node against a DOM just big enough to
# hold one picker, with post() stood in so the test sees what Save sends.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP   qw(decode_json);
use PageScript qw(extract_function page_source layout_js);
use TestHelper qw(repo_root site_tempdir);

my $page = repo_root() . '/starter/manager/domains.md';
my $src  = page_source($page);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my @fns = map { extract_function( $src, $_, $page ) }
    qw(tokenPill removeToken addToken cfgTrack cfgValueOf cfgMark saveDomain);
my @vars;
for my $v (qw(PICK_KEYS EDIT_KEYS CFG_PICKER_CLASS)) {
    my ($decl) = $src =~ /^(var \Q$v\E = .*?;)\s*$/ms;
    ok( $decl, "the page declares $v" ) or BAIL_OUT("no $v to run");
    push @vars, $decl;
}
# SM1014: the pills name a group through the layout's mgGroupLabel/mgGroupName.
my $page_js = join "\n", layout_js(qw(mgGroupLabel mgGroupName)), @vars, @fns;

my $dir = site_tempdir();

# Opens the sheet for one domain whose allowed_groups holds @$have, then runs
# the steps (JS text), presses Save, and returns what was posted, what the
# status said and what the dirty note said before Save.
sub run_sheet {
    my ( $have, $steps ) = @_;
    my $have_js = JSON::PP->new->encode($have);
    open my $js, '>', "$dir/t.js" or die "$dir/t.js: $!";
    print {$js} <<"JS";
// A DOM small enough to hold one token picker and nothing more.
function unesc(s) { return String(s).replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'); }
function El(tag, cls) {
  this.tag = tag; this.cls = {}; this.attrs = {}; this.children = []; this.parentNode = null;
  this.value = ''; var self = this;
  (cls || '').split(' ').filter(Boolean).forEach(function (c) { self.cls[c] = 1; });
  this.classList = {
    add: function (c) { self.cls[c] = 1; },
    remove: function (c) { delete self.cls[c]; },
    contains: function (c) { return !!self.cls[c]; }
  };
}
El.prototype.append = function (c) { c.parentNode = this; this.children.push(c); return c; };
El.prototype.remove = function () {
  var p = this.parentNode; if (!p) return;
  p.children.splice(p.children.indexOf(this), 1); this.parentNode = null;
};
El.prototype.getAttribute = function (k) { return this.attrs[k]; };
El.prototype.querySelectorAll = function (sel) {
  var c = sel.replace(/^\\./, ''), out = [];
  (function walk(n) { n.children.forEach(function (k) { if (k.cls[c]) out.push(k); walk(k); }); })(this);
  return out;
};
El.prototype.querySelector = function (sel) { return this.querySelectorAll(sel)[0] || null; };
El.prototype.closest = function (sel) {
  var c = sel.replace(/^\\./, ''), n = this;
  while (n && !n.cls[c]) n = n.parentNode;
  return n;
};
// Only the two fragments the picker inserts: a pill, and the empty note.
El.prototype.insertAdjacentHTML = function (pos, html) {
  var m = html.match(/class="mg-token" data-val="([^"]*)"/);
  if (m) {
    var pill = new El('span', 'mg-token'); pill.attrs['data-val'] = unesc(m[1]);
    pill.append(new El('button', 'mg-token-x'));
    this.append(pill); return;
  }
  if (/mg-tokens-empty/.test(html)) { this.append(new El('span', 'mg-tokens-empty')); return; }
  throw new Error('unexpected fragment: ' + html);
};

var HOST = 'a.example';
var ELS = {};
var row = new El('div');
var box = row.append(new El('div', 'mg-tokens'));
box.id = 'e-' + HOST + '-allowed_groups'; box.attrs['data-kind'] = 'groups';
var pick = row.append(new El('div', 'mg-tokens-pick'));
var select = pick.append(new El('select', 'mg-principal-pick'));
box.previousElementSibling = null; pick.previousElementSibling = box;
var name = new El('input'); name.id = 'e-' + HOST + '-site_name'; name.value = 'Site A';
var note = new El('div'); note.hidden = true; note.textContent = '';
ELS[box.id] = box; ELS[name.id] = name; ELS['cfg-dirty'] = note;
var document = { getElementById: function (id) { return ELS[id] || null; } };

function esc(x) { return String(x == null ? '' : x).replace(/&/g, '&amp;')
  .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
var POSTED = [], STATUS = [], REFUSE = null;
function post(action, obj) { POSTED.push({ action: action, body: obj }); return Promise.resolve(REFUSE || { ok: true }); }
function cfgStatus(m, k) { STATUS.push(m); }
function loadDomains() {}
function splitAppearance(v) { return { layout: v, theme: '' }; }

$page_js

// The sheet opens: draw the current pills, then take the originals as
// renderConfigSheet does.
var have = $have_js;
if (have.length) have.forEach(function (g) { box.insertAdjacentHTML('beforeend', tokenPill(g)); });
else box.insertAdjacentHTML('beforeend', '<span class="mg-tokens-empty">None yet.</span>');
var CFG_ORIG = {};
EDIT_KEYS.forEach(function (k) { cfgTrack(document.getElementById('e-' + HOST + '-' + k)); });
cfgMark();
function pillX(g) {
  return box.querySelectorAll('.mg-token').filter(function (p) { return p.attrs['data-val'] === g; })[0].children[0];
}
function addGroup(g) { select.value = g; addToken(select); }

$steps

var before = { note: note.hidden ? '' : note.textContent, dirty: !!box.cls['mg-dirty'],
               empty: !!box.querySelector('.mg-tokens-empty') };
saveDomain(HOST);
setTimeout(function () {
  console.log(JSON.stringify({ posted: POSTED, status: STATUS, before: before,
                               after: note.hidden ? '' : note.textContent }));
}, 0);
JS
    close $js;
    my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $got = eval { decode_json($raw) };
    diag("node said: $raw") unless $got;
    return $got || { posted => [], status => [$raw], before => {}, after => '' };
}

sub sets { [ map { $_->{body}{key} . '=' . $_->{body}{value} } @{ $_[0]{posted} } ] }

# --- a group is added -------------------------------------------------------
my $add = run_sheet( ['staff'], "addGroup('editors');" );
is( $add->{before}{note}, '1 change not saved',
    'adding a group counts as one unsaved change before Save' );
ok( $add->{before}{dirty}, 'and the picker marks itself changed' );
is_deeply( sets($add), ['allowed_groups=staff,editors'],
    'Save posts allowed_groups with the added group, and nothing else' );
is( $add->{posted}[0]{action}, 'domain-set',      'through domain-set' );
is( $add->{status}[-1],        'Saved a.example', 'and says it saved' );
is( $add->{after},             '', 'the saved sheet has nothing left unsaved' );

# --- a group is removed -----------------------------------------------------
my $rm = run_sheet( [ 'staff', 'editors' ], "removeToken(pillX('staff'));" );
is( $rm->{before}{note}, '1 change not saved', 'removing a group counts as a change' );
is_deeply( sets($rm), ['allowed_groups=editors'],
    'Save posts allowed_groups without the removed group' );

# --- the last group is removed ----------------------------------------------
my $last = run_sheet( ['staff'], "removeToken(pillX('staff'));" );
is_deeply( sets($last), ['allowed_groups='],
    'removing the last group posts an empty list' );
ok( $last->{before}{empty}, 'and the emptied picker says none is chosen' );

# --- nothing changes --------------------------------------------------------
my $none = run_sheet( ['staff'], '' );
is_deeply( sets($none), [], 'with no change, Save posts nothing' );
is( $none->{status}[-1], 'Nothing had changed.', 'and says so' );

# --- added and taken away again ----------------------------------------------
my $undo = run_sheet( ['staff'], "addGroup('editors'); removeToken(pillX('editors'));" );
is( $undo->{before}{note}, '', 'a group added and removed again leaves nothing unsaved' );
is_deeply( sets($undo), [], 'and Save posts nothing' );

# --- the same group twice ----------------------------------------------------
my $dup = run_sheet( ['staff'], "addGroup('staff');" );
is_deeply( sets($dup), [], 'adding a group already there is no change' );

# --- SM1014: the picker offers @name; allowed_groups stores the name ---------
my $at = run_sheet( ['staff'], "addGroup('\@editors');" );
is_deeply( sets($at), ['allowed_groups=staff,editors'],
    'a group picked as @editors is saved as editors' );
my $atdup = run_sheet( ['staff'], "addGroup('\@staff');" );
is_deeply( sets($atdup), [], 'and @staff is the staff already there' );

# --- SM1016: a refused save says why, and does not say Saved -----------------
my $no = run_sheet( ['staff'],
    "addGroup('\@ghost'); REFUSE = { ok: false, error: 'No group \@ghost on this site' };" );
is( $no->{status}[-1], 'No group @ghost on this site', 'a refused save shows the refusal' );
is( $no->{after},      '1 change not saved', 'and the change is still unsaved' );

done_testing();

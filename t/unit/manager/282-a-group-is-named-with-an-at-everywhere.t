#!/usr/bin/perl
# SM1014: a group is shown as @name wherever one is picked or shown beside
# people, and is accepted with or without the @.
#
# RULED by the release manager on 2026-10-12: "groups should be prefixed with
# something say @ so they can be distinguished from users, and this should be
# consistent anywhere a group is picked". Files and Data already offered
# `@staff`; Groups, Domains and the add-user form offered `staff`, so the same
# group read two ways, and on the Groups page a nested group and a person
# looked alike - and a person named like a group could not be added at all,
# because the bare name nested the group.
#
# STORAGE IS UNCHANGED, and this test holds that too: an ACL rule keeps
# `@staff`, while a group's member list, allowed_groups and the add-user
# group-add call carry the plain name.
#
# The pages' own functions are run under node with the layout's helpers.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP   qw(decode_json);
use PageScript qw(extract_function page_source layout_js);
use TestHelper qw(repo_root site_tempdir);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $root = repo_root();
my $dir  = site_tempdir();
my $layout
    = layout_js(qw(mgSetPrincipals mgGroupLabel mgGroupName mgPrincipalOptions mgPrincipalSelect));

sub fns {
    my ( $page, @names ) = @_;
    my $path = "$root/starter/manager/$page";
    my $src  = page_source($path);
    return join "\n", map { extract_function( $src, $_, $path ) } @names;
}

# Runs $js (which sets OUT) and returns OUT, decoded.
sub run_js {
    my ($js) = @_;
    open my $fh, '>', "$dir/t.js" or die "$dir/t.js: $!";
    print {$fh} $layout, "\n",
        "function escHtml(x) { return String(x == null ? '' : x).replace(/&/g, '&amp;')\n",
        "  .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\"/g, '&quot;'); }\n",
        "var esc = escHtml; var OUT = null;\n", $js,
        "\nPromise.resolve().then(function () { console.log(JSON.stringify(OUT)); });\n";
    close $fh;
    my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $got = eval { decode_json($raw) };
    diag("node said: $raw") unless defined $got;
    return $got;
}

# --- the layout: one picker, one way to name a group -------------------------
{
    my $o = run_js(<<'JS');
mgSetPrincipals(['alice'], ['staff']);
OUT = { all: mgPrincipalOptions(), groups: mgPrincipalOptions({ only: 'groups' }),
        plain: mgPrincipalOptions({ groupPrefix: '' }),
        label: [mgGroupLabel('staff'), mgGroupLabel('@staff')],
        name: [mgGroupName('@staff'), mgGroupName('staff'), mgGroupName(' @staff ')] };
JS
    like( $o->{all}, qr/<option value="\@staff">\@staff<\/option>/, 'a group is offered as @staff' );
    like( $o->{all}, qr/<option value="alice">alice<\/option>/, 'a person by their name' );
    unlike( $o->{groups}, qr/value="alice"/, 'a groups-only picker offers no person' );
    like( $o->{plain}, qr/value="\@staff"/,
        'there is no option left that names a group plainly' );
    is_deeply( $o->{label}, [ '@staff', '@staff' ], 'mgGroupLabel adds the @ once' );
    is_deeply( $o->{name}, [ 'staff', 'staff', 'staff' ],
        'mgGroupName takes the name with or without it' );
}

# --- the Groups page: a nested group is @name, a person is not ----------------
{
    my $js = fns( 'groups.md', qw(memberPillsHtml addMember) ) . <<'JS';
var allGroups = { editors: { members: [] }, staff: { members: [] } };
var BODIES = [], INPUT = { value: '' };
var document = { getElementById: function (id) { return id === 'add-editors' ? INPUT : null; } };
function apiCall(b) { BODIES.push(b); return Promise.resolve({ ok: true }); }
function refreshGroupMembers() {} function refreshGroupSummary() {}
var STATUS = []; function showStatus(m) { STATUS.push(m); }
mgSetPrincipals(['alice', 'staff'], ['editors', 'staff']);
var pills = memberPillsHtml(['alice', 'staff'], 'editors');
INPUT.value = '@staff'; addMember('editors');
INPUT.value = 'staff'; addMember('editors');
OUT = { pills: pills, bodies: BODIES };
setTimeout(function () { OUT.status = STATUS; console.log(JSON.stringify(OUT)); process.exit(0); }, 0);
JS
    open my $fh, '>', "$dir/g.js" or die;
    print {$fh} $layout, "\n",
        "function escHtml(x) { return String(x == null ? '' : x).replace(/&/g, '&amp;')\n",
        "  .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\"/g, '&quot;'); }\n",
        "var OUT = null;\n", $js;
    close $fh;
    my $raw = `\Q$node\E \Q$dir/g.js\E 2>&1`;
    my $o   = eval { decode_json($raw) } || do { diag("node said: $raw"); {} };
    like( $o->{pills}, qr/>\@staff<\/a>/, 'a nested group is shown as @staff' );
    like( $o->{pills}, qr/>alice<\/a>/,   'a person is shown by name' );
    like( $o->{pills}, qr/removeMember\('staff','editors'\)/,
        'and its x removes the stored name' );
    is_deeply(
        $o->{bodies},
        [ { action => 'group-nest', sub => 'staff', parent => 'editors' },
            { action => 'group-add', username => 'staff', group => 'editors' },
        ],
        '@staff nests the group, and staff adds the person of that name'
    );
    like( ( $o->{status} || [] )->[0] // '', qr/Nested group \@staff in \@editors\./,
        'and the page says which it did' );
}

# --- the add-user form ---------------------------------------------------------
{
    my $o = run_js( fns( 'users.md', qw(renderNewUserGroups addNewUserGroup addNewUserGroupFromInput) )
            . <<'JS' );
var allGroups = { editors: [], staff: [] };
var newUserGroups = ['staff'];
var TOKS = { innerHTML: '' }, PICK = { innerHTML: '', value: '' };
var document = { getElementById: function (id) {
  return id === 'new-group-tokens' ? TOKS : id === 'new-group-input' ? PICK : null; } };
function showStatus() {}
renderNewUserGroups();
var before = { toks: TOKS.innerHTML, pick: PICK.innerHTML };
PICK.value = '@editors'; addNewUserGroupFromInput();
OUT = { before: before, staged: newUserGroups };
JS
    like( $o->{before}{toks}, qr/>\@staff<button/, 'a staged group is shown as @staff' );
    like( $o->{before}{pick}, qr/<option value="\@editors">\@editors<\/option>/,
        'the group picker offers @editors' );
    is_deeply( $o->{staged}, [qw(staff editors)], 'and stages the plain name group-add takes' );
}

# --- the Domains page --------------------------------------------------------
{
    my $o = run_js( fns( 'domains.md', 'tokenPill' ) . <<'JS' );
OUT = { g: tokenPill('staff', 'groups'), u: tokenPill('alice', 'users') };
JS
    like( $o->{g}, qr/data-val="staff">\@staff</,
        'an allowed group is shown as @staff and holds the name it stores' );
    like( $o->{u}, qr/data-val="alice">alice</, 'a locked user is shown by name' );
}

done_testing();

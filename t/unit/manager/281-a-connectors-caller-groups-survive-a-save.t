#!/usr/bin/perl
# SM1013 (the same defect on a second page): a connector's caller groups are
# what Save posts.
#
# Found checking every manager page for a picker its save does not read, after
# the Domains page's Access pickers were found never to save. callersField()
# draws the caller groups as checkboxes (f-<id>-cg-<group>) when the group list
# can be read, and as a text box (f-<id>-callers) when it cannot; saveConnector
# read only the text box. With the groups known - the ordinary case - every
# save posted `callers: []`, dropping the connector's caller groups, and said
# "Saved".
#
# callersField() and callersValue() are run under node: what the first draws is
# parsed into a DOM of inputs, boxes are ticked, and the second reads it back.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP   qw(decode_json);
use PageScript qw(extract_function page_source);
use TestHelper qw(repo_root site_tempdir);

my $page = repo_root() . '/starter/manager/connectors.md';
my $src  = page_source($page);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $page_js = join "\n",
    map { extract_function( $src, $_, $page ) } qw(callersField callersValue check field);

like( extract_function( $src, 'saveConnector', $page ), qr/callers:\s*callersValue\(f\)/,
    'saveConnector posts what callersValue reads' );

my $dir = site_tempdir();

# Draws the field for a connector whose callers are @$have, with the site's
# groups $groups (undef: the list could not be read), runs $steps, and returns
# what callersValue reads back.
sub read_back {
    my ( $groups, $have, $steps ) = @_;
    my $enc = JSON::PP->new;
    my ( $g_js, $h_js ) = ( $enc->encode( [ $groups // 0 ] ), $enc->encode($have) );
    open my $js, '>', "$dir/t.js" or die "$dir/t.js: $!";
    print {$js} <<"JS";
function escHtml(x) { return String(x == null ? '' : x).replace(/&/g, '&amp;')
  .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
var GROUPS = $g_js\[0] || null;
$page_js

var f = 'f-c1-';
var html = callersField(f, $h_js);
// The inputs the field drew, as a DOM of id -> element.
var ELS = {}, ORDER = [];
html.replace(/<input([^>]*)>/g, function (all, attrs) {
  var id = (attrs.match(/id="([^"]*)"/) || [])[1];
  var el = { id: id, checked: / checked/.test(attrs),
             value: (attrs.match(/value="([^"]*)"/) || [, ''])[1] };
  ELS[id] = el; ORDER.push(el); return all;
});
var document = {
  getElementById: function (id) { return ELS[id] || null; },
  querySelectorAll: function (sel) {
    var p = sel.match(/^input\\[id\\^="([^"]*)"\\]\$/)[1];
    return ORDER.filter(function (e) { return e.id.indexOf(p) === 0; });
  }
};
function tick(g, on) { ELS[f + 'cg-' + g].checked = on; }
$steps
console.log(JSON.stringify(callersValue(f)));
JS
    close $js;
    my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $got = eval { decode_json($raw) };
    diag("node said: $raw") unless $got;
    return $got || [$raw];
}

is_deeply( read_back( [qw(editors staff)], ['staff'], '' ), ['staff'],
    'with the groups known, an unchanged connector keeps its caller group' );
is_deeply( read_back( [qw(editors staff)], ['staff'], "tick('editors', true);" ),
    [qw(editors staff)], 'a ticked group is added' );
is_deeply( read_back( [qw(editors staff)], ['staff'], "tick('staff', false);" ),
    [], 'an unticked group is removed' );
is_deeply( read_back( [qw(editors staff)], [qw(gone staff)], '' ), [qw(staff gone)],
    'a caller group the site no longer has is kept, as the page says it is' );
is_deeply( read_back( undef, [qw(staff editors)], '' ), [qw(staff editors)],
    'with the group list unreadable, the typed names are read' );

done_testing();

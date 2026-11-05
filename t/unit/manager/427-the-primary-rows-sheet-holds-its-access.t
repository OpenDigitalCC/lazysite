#!/usr/bin/perl
# SM1333 (ruling 78): the Domains page shows the primary's row, and its sheet
# holds the primary's ACCESS only - the groups allowed and the users locked,
# with Save - and none of a domain's other fields or tools. Its other settings
# are the site's own (Config, Appearance), which every other domain inherits; a
# Delete or a content folder on that sheet would offer what the server refuses.
#
# The page's own functions are run under node, as t/unit/manager/280 runs them.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use PageScript qw(extract_function page_source layout_js);
use TestHelper qw(repo_root site_tempdir);

my $page = repo_root() . '/starter/manager/domains.md';
my $src  = page_source($page);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my @fns = map { extract_function( $src, $_, $page ) }
    qw(esc label tokenPill tokenPicker editField editSection sec primarySettingsHtml domainSettingsHtml);
my @vars;
for my $v (qw(LABELS EDIT_SECTIONS EDIT_HINTS CREATE_HINTS EDIT_OPTIONS PICK_KEYS PRIMARY_HINTS)) {
    my ($decl) = $src =~ /^(var \Q$v\E = .*?;)\s*$/ms;
    ok( $decl, "the page declares $v" ) or BAIL_OUT("no $v to run");
    push @vars, $decl;
}
my $js_src = join "\n", layout_js(qw(mgGroupLabel mgGroupName)),
    'function mgPrincipalSelect() { return "<select></select>"; }',
    'var DOMAINS = [];', 'var NEW_HOST = "__new__";', @vars, @fns,
    'var row = { host: "(default)", is_primary: 1, allowed_groups: "agents", locked_users: "", content_root: "" };',
    'process.stdout.write(domainSettingsHtml(row, false));';

my $dir = site_tempdir();
open my $js, '>', "$dir/t.js" or die $!;
print {$js} $js_src;
close $js;
my $html = `"$node" "$dir/t.js" 2>&1`;
is( $? >> 8, 0, 'the primary\'s sheet renders' ) or diag($html);

like( $html, qr/id="e-\(default\)-allowed_groups"/, 'groups allowed to manage' );
like( $html, qr/id="e-\(default\)-locked_users"/,   'users locked' );
like( $html, qr/id="e-\(default\)-locked_groups"/,  'groups locked (SM1334)' );
like( $html, qr/data-val="agents"/,                  'holding the row\'s own groups' );
like( $html, qr/Grants add|As on any domain, a group reaches the domains that name it/,
    'the hint says how a grant on the primary adds' );
like( $html, qr/id="cfg-save-\(default\)"/, 'and Save' );
for my $k (qw(content_root site_url site_name appearance nav_file lang maintenance)) {
    unlike( $html, qr/id="e-\(default\)-\Q$k\E"/, "no $k field" );
}
unlike( $html, qr/Delete domain|Export site|Danger zone/, 'no domain tools or delete' );

done_testing();

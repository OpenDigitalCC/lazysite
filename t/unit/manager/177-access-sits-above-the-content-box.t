#!/usr/bin/perl
# SM848: in the editor Files opens, Access sits ABOVE the content box.
#
# Who may read a file is a fact an operator wants before editing it, not after.
# The section sat below a content box that grows with the page, so a protected
# file's access state was the thing a person scrolled past - the SM635 shape,
# where the row that most needs to say "held back" is the one nobody reads.
#
# It moves above Metadata rather than just above Content: the splitter between
# Metadata and Content resizes exactly those two, and a section wedged between
# them would put a third thing inside the drag.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $src = PageScript::page_source( repo_root() . '/starter/manager/edit.md' );

# The editor pane's markup only: each id's position in it.
my ($pane) = $src =~ /(<div id="ed-editor-pane".*?<div id="ed-pane-switch")/s;
ok( $pane, 'the editor pane is found' ) or do { done_testing(); exit };
my %at;
while ( $pane =~ /\bid="(ed-[a-z-]+)"/g ) { $at{$1} //= $-[0] }

for my $id (qw(ed-perms-section ed-meta-section ed-vsplit ed-content-section)) {
    ok( defined $at{$id}, "$id is in the editor pane" );
}

cmp_ok( $at{'ed-perms-section'} // 1e9, '<', $at{'ed-content-section'} // -1,
    'Access comes before the content box' );
cmp_ok( $at{'ed-perms-section'} // 1e9, '<', $at{'ed-meta-section'} // -1,
    'and before Metadata, so it is not inside the splitter\'s pair' );

# The splitter still sits between exactly the two panes it resizes.
my ($between) = $pane =~ /id="ed-meta-section".*?(<div id="ed-vsplit".*?)<details id="ed-content-section"/s;
ok( defined $between, 'the splitter is still between Metadata and Content' );
unlike( $between // '', qr/<details\b/, 'with nothing else between them' );

like( $pane, qr/id="ed-perms-section"[^>]*ontoggle="loadEditorPerms\(\)"/,
    'the moved section still loads on first open' );

done_testing();

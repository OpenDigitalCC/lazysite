#!/usr/bin/perl
# SM678: there is ONE rights editor, and the Data page can use it.
#
# The Files page grew a chip editor for a file's ACL - a name, an r toggle, a w
# toggle, a remove. The Data page then needed the same thing, because a table's
# access IS an ACL: Lazysite::Data::Access keys it as
# lazysite/db/tables/<table>, and acl-get and acl-set reach it with the verbs a
# page's rule takes.
#
# So the Data page had a choice between a SECOND COPY of that markup and no
# editor at all, and it shipped with no editor at all - a panel that showed the
# rule and told the reader to run acl-set somewhere else. Both answers are
# wrong, and the second copy is the worse one: two editors over the same
# structure diverge the first time either is touched, and the divergence shows
# up as an ACL that one page can write and the other cannot read back.
#
# The test that matters is therefore about COUNT, not appearance. The chip
# markup must be emitted from exactly one place. A page that renders its own
# chips has forked the editor, whatever it looks like on the day.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root   = "$FindBin::Bin/../../..";
my $layout = "$root/starter/lazysite/manager/layout.tt";
my $files  = "$root/starter/manager/files.md";
my $data   = "$root/starter/manager/data.md";

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $L = slurp($layout);
my $F = slurp($files);
my $D = slurp($data);

# ---- the shared editor exists, and offers the whole job -------------------
# Reading an ACL into chips and reading chips back out are the two halves. A
# helper with only the first is a renderer, and every caller still has to write
# its own collector - which is where the duplication came back.
like( $L, qr/window\.mgRights\s*=/, 'the layout defines the shared rights editor' );
for my $m (qw(chip build toggle remove collect)) {
    like( $L, qr/\b\Q$m\E\s*:/, "mgRights offers $m()" );
}

# ---- exactly one place emits the chip markup -----------------------------
# `mg-chip-right` is the toggle button's class - the piece a fork could not
# avoid reproducing. Counting it across the three files is what makes this test
# fail if either page starts rendering its own again.
my $emitters = 0;
for my $pair ( [ layout => $L ], [ 'files.md' => $F ], [ 'data.md' => $D ] ) {
    my ( $name, $src ) = @{$pair};
    $emitters++ if $src =~ /class="mg-chip-right/;
}
is( $emitters, 1, 'the chip markup is emitted from exactly one place' );
like( $L, qr/class="mg-chip-right/, '...and that place is the shared layout' );

# ---- the Files page delegates, keeping its own call sites -----------------
# The extraction MOVED the implementation; it did not rename the calls. The
# page's own markup, CSS and tests still speak of chipHtml and buildRights.
like( $F, qr/function chipHtml\([^)]*\)\s*\{\s*return mgRights\.chip\(/,
    'files.md delegates chipHtml to the shared editor' );
like( $F, qr/function buildRights\([^)]*\)\s*\{\s*return mgRights\.build\(/,
    'files.md delegates buildRights to the shared editor' );

# ---- the Data page EDITS, rather than describing ------------------------
# The alert box this replaces ended by telling the operator to "edit the rule
# on this key with acl-set". That is a remedy on a command line they may not
# have and, on a hosted instance, are not the person for. A panel that cannot
# change what it displays sends its reader somewhere else to finish.
like( $D, qr/mgRights\.build\(/,  'data.md renders the rule with the shared editor' );
like( $D, qr/mgRights\.collect\(/, 'data.md reads the chips back out of it' );
like( $D, qr/action=' \+ action/, 'data.md posts the rule back' );
like( $D, qr/data-table-acl-remove/,
    'data.md clears a rule rather than storing an empty one' );

# SM687: the same CONTROL, not one that resembles it. An operator who has
# learned the Files expander has learned this one, and a second implementation
# would be a second thing to keep in step.
like( $D, qr/class="mg-chev"/,   'the Data listing expands from the same chevron' );
like( $D, qr/class="mg-perms-row"/,  '...into the same row' );
like( $D, qr/class="mg-perms-card"/, '...holding the same card' );
like( $D, qr/mg-rights-add/,     '...with the same principal picker' );
unlike( $D, qr/table-acl-panel/,
    'and the modal it replaced is gone, not left orphaned in the markup' );
unlike( $D, qr/with acl-set/,
    'data.md no longer sends the operator to a command line' );
unlike( $D, qr/window\.alert\(/, 'the rule is not shown in an alert box' );

# ---- the control is not offered to someone the verb refuses -------------
# This page is gated on manage_data. acl-get and acl-set are gated on
# manage_content. Those do not have to travel together, so the button was on
# offer to people every call behind it would refuse.
like( $D, qr/CAN_ACL/, 'data.md knows whether the reader may touch a rule' );
# The EXPANDER is for everyone - it holds the exports, which belong to anyone
# who can see this page. What is gated is the ACL FETCH inside it: acl-get needs
# manage_content, and asking anyway would put a refusal in front of a
# manage_data holder reaching for an export.
like( $D, qr/if \(CAN_ACL\) loadTableAcl\(/,
    'the rule is fetched only for a reader whose grant can read it' );
unlike( $D, qr/CAN_ACL \? '<a href="#" class="mg-chev"/,
    'but the expander itself is not gated - it carries the exports' );
like( $D, qr/action=whoami/, '...and it asks, rather than assuming' );

done_testing();

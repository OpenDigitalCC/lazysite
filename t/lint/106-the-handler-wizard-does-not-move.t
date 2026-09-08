#!/usr/bin/perl
# SM639/SM640: the add-handler form is rendered where it is used.
#
# THE BLOCKER BOTH FILINGS RECORDED. There was one wizard node after the whole
# handler list, and opening the form MOVED it into whichever group was being
# added to:
#
#     var group = document.getElementById('mg-handler-group-' + type);
#     if (group) group.appendChild(wizard);
#
# That relocation is why the handler section could not join the shared config
# modal (SM640) and why the forms plugin stayed inline (SM639): a modal is
# destroyed on close, and it would take the moved node with it. Both filings
# said the same thing - converting it needs the wizard to stop moving DOM.
#
# It does not move now: one slot per group, rendered in place. This test holds
# THAT property, not the markup, because the property is what unblocks them.
use strict;
use warnings;
use Test::More;
use FindBin;

my $page = "$FindBin::Bin/../../starter/manager/plugin-config.md";
plan skip_all => "no $page" unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
my ($js) = $src =~ /<script>(.*)<\/script>/s;
ok( $js, 'the page script was found' ) or BAIL_OUT('no script');
$js =~ s{//[^\n]*}{}g;    # a description of the old behaviour is not the behaviour

unlike( $js, qr/appendChild\(\s*wizard\s*\)/,
    'the wizard is not appended into a group' )
    or diag( 'Moving the node is what kept this section out of the shared '
        . 'config modal: a modal destroyed on close takes a moved node with '
        . 'it. Render the slot where it is used instead.' );

unlike( $js, qr/getElementById\(\s*'add-handler-wizard'\s*\)/,
    'there is no single shared wizard node to move' );

# SM772: a handler type the plugin declares is configurable the day it is
# offered. The step-2 form draws three types by hand; every other type must
# fall through to the schema renderer, and the save must read that renderer
# back - or a type added to the plugin (the field found `connector`) shows in
# the list with no way to say what it needs.
like( $js, qr/else\s+html\s*\+=\s*renderSchemaFields\(\s*type\s*,\s*d\s*\)/,
    'a type without a hand-drawn renderer renders from its declared schema' );
like( $js, qr/function renderSchemaFields\s*\(/, 'and the schema renderer exists' );
like( $js, qr/schemaFieldsFor\(\s*type\s*\)\.forEach/, 'and the save reads the schema fields back' );

like( $js, qr/id="add-handler-wizard-'\s*\+\s*type/,
    'each group renders its own slot' )
    or diag('One slot per group is what makes the move unnecessary.');

like( $js, qr/querySelectorAll\('\.mg-handler-wizard'\)/,
    'and closing clears every slot' )
    or diag( 'With one slot per group, closing only the one you know about '
        . 'leaves another open behind you.' );

done_testing();

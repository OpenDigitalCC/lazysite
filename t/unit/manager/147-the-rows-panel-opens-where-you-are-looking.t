#!/usr/bin/perl
# SM680: a watched user pressed Rows and did not see it happen.
#
# #rows-panel was a display:none block BELOW the table list, so opening it
# revealed content underneath whatever the user was looking at - off-screen on a
# page with several tables, or a short window. The control worked exactly as
# built and the person did not know it had.
#
# That is observation, not inference, which is the strongest evidence this
# project gets and the hardest to argue with.
#
# It is the same objection SM640 answered on the Plugin Config page: a table's
# rows are a DIFFERENT SUBJECT from the list of tables, not more detail about
# one entry in it - and the panel carries its own pager, filter and editor,
# which is an application nested inside a listing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $src = do {
    open my $fh, '<', repo_root() . '/starter/manager/data.md' or die $!;
    local $/;
    <$fh>;
};

subtest 'the panel is an overlay, not a block below' => sub {
    like( $src, qr/id="rows-panel" class="mg-rows-modal"/,
        'the panel carries the modal class' );
    like( $src, qr/\.mg-rows-modal \{[^}]*position:fixed/,
        'which is fixed over the page' )
        or diag( 'A block that merely has a border is still below the fold.' );
    like( $src, qr/\.mg-rows-sheet \{[^}]*overflow:auto/,
        'and scrolls INSIDE itself' )
        or diag( 'Otherwise a long table scrolls the page underneath, which is '
            . 'the confusion being fixed.' );

    unlike( $src, qr/id="rows-panel"[^>]*margin-top:18px/,
        'the old below-the-listing placement is gone' );
};

subtest 'closing asks before discarding an unsaved row' => sub {
    my ($fn) = $src =~ /function closeRows\(\) \{(.*?)\n\}/s;
    ok( defined $fn, 'there is a close handler' ) or return;

    like( $fn, qr/mgDirtyGuard\.isDirty/,
        'it asks the dirty guard by its REAL method name' )
        or diag( 'A page once guessed isSet: the method was undefined, the '
            . 'guard never fired, and unsaved edits vanished silently.' );
    like( $fn, qr/unsaved/i, 'and warns before discarding' );
};

subtest 'the panel CONTENT is untouched' => sub {
    # Moving where it renders must not disturb what it renders. The pager, the
    # import control and the editor entry point all still exist.
    like( $src, qr/id="rows-pager"/,      'the pager survives' );
    like( $src, qr/id="import-file"/,     'the CSV import survives' );
    like( $src, qr/onclick="openEditor\(null\)"/, 'and Add a row survives' );
};

done_testing();

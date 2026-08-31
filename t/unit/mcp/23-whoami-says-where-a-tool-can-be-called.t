#!/usr/bin/perl
# SM653: whoami reports the two classes of tool separately.
#
# WHAT THE FIELD AGENT MEASURED. A themes-only grant was offered 26 content
# tools by tools/list that it could not call anywhere it would think to try:
# they are reachable ONLY on theme and layout paths, through the path-aware
# override. The listing now says so in each tool's description - that is the
# first remedy, and it is for a reader that reads.
#
# This is the second, for a reader that COUNTS. whoami answered one flat list,
# so an agent comparing "what I hold" against "what I can call" saw 26 tools it
# would be refused on every ordinary path with nothing to separate them.
#
# DERIVED FROM THE RULE THAT DECIDES CALLABILITY, never a second list of names:
# a hand-kept list would be another place to update and would be wrong the
# first time a tool gained a capability. That is the same argument as SM662,
# and this test exists to hold the derivation rather than the answer.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

my $mcp = "$FindBin::Bin/../../../lazysite-mcp.pl";
plan skip_all => "no $mcp" unless -f $mcp;
my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };

subtest 'the split is derived, not listed' => sub {
    like( $src, qr/sub _tool_classes/, 'there is a classifier' );
    # SCOPED TO THE CLASSIFIER'S OWN BODY. The first version of this matched
    # /_tool_classes.*?_path_only_for/s across the whole file, and
    # _path_only_for is DEFINED further down - so it matched the definition
    # rather than any call, and passed with the call removed. A test that
    # cannot fail is worse than no test, and sabotage is what found it.
    my ($classifier) = $src =~ /(sub _tool_classes\b.*?\n\})/s;
    ok( $classifier, 'the classifier body was located' );
    like( $classifier, qr/_path_only_for\s*\(/,
        'and it asks the same rule that decides callability' )
        or diag( 'A second list of tool names would be another place to keep '
            . 'in step, and would be wrong the first time a tool gained a '
            . 'capability - which is how the map in SM654 went wrong three '
            . 'times in one afternoon.' );
    unlike( $src, qr/my \@PATH_ONLY_TOOLS\s*=/,
        'no hand-kept list of path-only tool names' );
};

subtest 'whoami answers both, and keeps the flat list' => sub {
    like( $src, qr/tools_by_reach/, 'whoami reports the classes' );
    like( $src, qr/anywhere\s*=>/,  'the tools callable on any path' );
    like( $src, qr/path_only\s*=>/, 'and the ones callable only on theme/layout paths' );
    like( $src, qr/tools\s*=>\s*_tool_names\(\$caps\)/,
        'the whole list is still reported unchanged' )
        or diag( 'An existing reader must not have to change to keep getting '
            . 'what it already got - the split is an addition, not a '
            . 'replacement.' );
};

subtest 'and it says what path_only MEANS' => sub {
    like( $src, qr/callable on theme and layout\s*'?\s*\.?\s*'?\s*paths only/i,
        'the note explains where they work' )
        or diag( 'A field named path_only, with no sentence, is a puzzle for '
            . 'the agent reading it - and the agent is the whole audience of '
            . 'this response.' );
    like( $src, qr/hold the capability/i,
        'and how to widen it' );
};

done_testing();

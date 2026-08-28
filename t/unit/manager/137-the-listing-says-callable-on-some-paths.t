#!/usr/bin/perl
# SM653: `tools/list` offered every path_aware tool to a themes-only grant.
#
# Enforcement was never wrong - tools/call refuses read_file on /index.md for
# that grant, measured by the site agent in the same minute as the listing. The
# defect is what the grant was TOLD it could do: the shared _tool_callable is
# asked without a path at listing time, so the theme/layout override applies
# unconditionally and the tool is advertised.
#
# The listing could answer "yes" or "no" and the truth is "yes, on some paths" -
# a third case it had no vocabulary for. Picking either side makes it worse:
# withholding recreates SM210 inverted and hides capability the grant has.
#
# THE ANSWER IS IN THE DESCRIPTION, not a new annotation. A client that does not
# know a new hint ignores it silently, and the reader here is a language model
# reading descriptions. One place to maintain, per the release manager.
#
# WHAT THIS TEST GUARDS is that the note is DERIVED from the same rule that
# decides callability. A hand-kept list of "the path-only tools" would be a
# sixth place to update (SM662) and would be wrong the first time a tool gained
# a capability - so the test asks the rule, and compares.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
plan skip_all => 'mcp missing' unless -f $mcp;

# Load the script's tables without running it as a CGI.
our %TOOLS;
{
    local $/;
    open my $fh, '<', $mcp or die $!;
    my $src = <$fh>;
    close $fh;
    ok( $src =~ /sub _path_only_for/, 'the derived predicate exists' )
        or BAIL_OUT('SM653 note has no rule to derive from');
    like( $src, qr/_path_only_for\(\s*\$name,\s*\$TOOLS\{\$name\},\s*\$caps\s*\)/,
        'and the listing calls it' );

    # The note must be built from the tool's OWN declared capability, not a
    # literal - otherwise it names the wrong capability for some tools and
    # nobody notices, because it reads plausibly either way.
    my ($block) = $src =~ /_path_only_for\( \$name, \$TOOLS\{\$name\}, \$caps \) \) \{(.*?)\n        \}/s;
    ok( defined $block, 'the note block was found' ) or BAIL_OUT('cannot read it');
    like( $block, qr/\$TOOLS\{\$name\}\{cap\}/,
        'the note names the tool\'s own capability, not a hardcoded one' )
        or diag( 'A literal here is right for most tools and wrong for some, '
            . 'which is the kind of wrong that survives review.' );
    like( $block, qr/theme and layout paths/,
        'and says which paths it IS callable on' );
}

# THE REAL SUB, lifted out of the script and compiled here.
#
# A local copy would be a second implementation of the rule this filing is
# against, and the test would pass with the shipped one deleted. lazysite-mcp.pl
# cannot simply be require'd - it runs as a CGI on load - so the sub's text is
# extracted and evaluated. If it stops being extractable the test fails rather
# than silently falling back to a copy.
my $po;
{
    local $/;
    open my $fh, '<', $mcp or die $!;
    my $src = <$fh>;
    close $fh;
    my ($sub) = $src =~ /(sub _path_only_for \{.*?\n\})/s;
    ok( defined $sub, 'the predicate was extracted from the script' )
        or BAIL_OUT('cannot test the real rule, and will not test a copy');
    $po = eval "package SM653Real; $sub; \\&_path_only_for"
        or BAIL_OUT("could not compile the extracted sub: $@");
}
sub _po { return $po->(@_) }

# The predicate itself: a themes-only grant, against the real tool table.
subtest 'the predicate answers the third case' => sub {
    my $themes_only = { mcp => 1, manage_themes => 1 };
    my $content     = { mcp => 1, manage_content => 1, manage_themes => 1 };

    # A path_aware tool whose own capability the caller lacks: path-only.
    my $t = { path_aware => 1, cap => 'manage_content' };
    ok( _po( 'read_file', $t, $themes_only ),
        'a path_aware tool the grant lacks the capability for is path-only' );

    # The same tool, for a grant that HOLDS the capability: not path-only, even
    # though the flag is set. This is the assertion that fails if the note is
    # driven by the flag alone rather than by the rule.
    ok( !_po( 'read_file', $t, $content ),
        'and is NOT path-only for a grant that holds it outright' );

    # No flag: never path-only, whatever else is true.
    ok( !_po( 'x', { cap => 'manage_content' }, $themes_only ),
        'a tool without path_aware is never annotated' );

    # A grant with neither theme capability never sees the override at all.
    ok( !_po( 'read_file', $t, { mcp => 1, manage_data => 1 } ),
        'and a grant with no theme/layout capability is not annotated' );
};

package main;

done_testing();

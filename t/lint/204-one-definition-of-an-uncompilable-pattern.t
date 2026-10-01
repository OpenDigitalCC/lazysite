#!/usr/bin/perl
# SM921: WHICH `pattern` SHAPES A BROWSER REFUSES IS ONE JUDGEMENT, IN ONE PLACE.
#
# The ruling that put the check in two surfaces said so explicitly: validate_page
# REFUSES an uncompilable pattern and `lazysite check` WARNS about one, and "the
# enumerable-shapes test then has two callers, so it must be ONE helper with a lint
# that both use it - a second copy of this judgement is the ADR 0001 shape and would
# drift".
#
# ADR 0001 tolerates a copy only where a module cannot be loaded, which is true of
# the render path and NOT true here: Lazysite::Validate is a module, and the check
# tool already requires Lazysite::Paths and Lazysite::Private. So there is no excuse
# for a second list, and the drift this prevents is the expensive kind - the
# characters were established by measurement against node's `v` flag, and a copy
# made from memory would be the filing's own list, which missed `/` and `|`.
#
# WHAT THIS HOLDS:
#   - the reserved-character list exists exactly once in the tree;
#   - both callers reach it by calling the helper by name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or return '';
    local $/;
    return scalar <$fh>;
}

my $validate = slurp('lib/Lazysite/Validate.pm');
ok( length $validate, 'Lazysite::Validate is present' )
    or BAIL_OUT('no lib/Lazysite/Validate.pm');

like( $validate, qr/sub \s+ html_pattern_problem/x,
    'the helper is defined in Lazysite::Validate' );
like( $validate, qr/%CLASS_RESERVED/,
    'and the reserved-character list is named, so this test can find a copy of it' );

# THE LIST, ONCE. Any other file that spells out the same set of characters as a
# Perl list is a second copy of the judgement, whatever it is called.
my @sources = grep { -f "$root/$_" } qw(
    lib/Lazysite/Validate.pm
    tools/lazysite-check.pl
    tools/lazysite-validate.pl
    lazysite-processor.pl
    lazysite-mcp.pl
    lazysite-manager-api.pl
    lib/Lazysite/Manager/Common.pm
);
my @carriers;
for my $f (@sources) {
    my $src = slurp($f);
    push @carriers, $f if $src =~ /CLASS_RESERVED/ || $src =~ /qw<\s*\(\s*\)\s*\{/;
}
is_deeply( \@carriers, ['lib/Lazysite/Validate.pm'],
    'exactly one file carries the reserved-character list' )
    or diag( 'A second copy drifts from the first. The list was measured against '
        . "node's `v` flag; a copy written from memory would be the filing's own "
        . 'list, which missed / and |.' );

# BOTH CALLERS CALL IT. A surface that stopped calling the helper would pass the
# test above by having no list at all - and would check nothing.
my $check = slurp('tools/lazysite-check.pl');
like( $check, qr/Lazysite::Validate::html_pattern_problem\s*\(/,
    'lazysite-check calls the helper rather than deciding for itself' );
like( $check, qr/require\s+Lazysite::Validate/,
    'and loads the module it calls into' );
like( $validate, qr/html_pattern_problem\s*\(\s*\$pat\s*\)/,
    'validate_content runs the same helper over a form field pattern' );

# The refusal and the warning are DIFFERENT severities, which is the ruling. If
# validate ever pushes this to warnings, a bad pattern stops being refused where an
# author would see it and the ruling is quietly reversed.
like( $validate, qr/uncompilable-pattern/,
    'validate_content gives the finding its own kind' );
my ($block) = $validate =~ /(uncompilable-pattern.{0,200})/s;
like( $block // '', qr/message/, 'with a message' );
my ($context) = $validate =~ /(.{200}uncompilable-pattern)/s;
like( $context // '', qr/\$issues/,
    'pushed to ISSUES, not warnings - validate_page REFUSES, which is the ruling' );

done_testing();

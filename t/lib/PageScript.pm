package PageScript;
# SM684: pull a named function out of a manager page, and FAIL when it is not
# there.
#
# THE DEFECT THIS EXISTS TO PREVENT. Six tests extracted a JavaScript function
# from a page with a regex pinned to its exact signature:
#
#     my ($fn) = $src =~ /(function renderHistory\(panel, entries\).*?\n\})/s;
#
# SM683 gave `renderHistory` a third argument. The regex stopped matching, the
# assertions behind it sat inside a SKIP block, and the suite reported sixteen
# tests with five skipped and looked healthy. Adding a parameter to a function
# is a normal, correct thing to do; the test did not object to it, it just
# stopped watching.
#
# Two rules follow, and this module exists to make both automatic:
#
#   1. MATCH THE NAME, NOT THE SIGNATURE. Parameters change. A test that breaks
#      when they do is a test nobody can maintain; a test that goes quiet when
#      they do is worse.
#   2. A FAILED EXTRACTION IS A FAILURE. It dies here, naming the function and
#      the file, rather than returning undef for a caller to skip on. A caller
#      that wants to tolerate absence must say so explicitly with `try_extract`.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(extract_function try_extract page_source);

# The page's source, front matter stripped. Dies if it is not there, because a
# test naming a page that does not exist is a broken test, not a skip.
sub page_source {
    my ($path) = @_;
    open my $fh, '<', $path
        or die "PageScript: cannot read $path: $!\n";
    local $/;
    my $src = <$fh>;
    close $fh;
    $src =~ s/\A---\n.*?\n---\n//s;
    return $src;
}

# The body of `function NAME(...)`, whatever its parameters.
#
# Matched to the first line that closes at column 0 - the house style for these
# pages - which is the same boundary the hand-written regexes used. What
# changes is that the parameter list is `[^)]*` rather than a literal, and that
# no match is fatal.
sub try_extract {
    my ( $src, $name ) = @_;
    return undef unless defined $src && defined $name;
    my ($fn) = $src =~ /(function \Q$name\E\([^)]*\).*?\n\})/s;
    return $fn;
}

sub extract_function {
    my ( $src, $name, $where ) = @_;
    my $fn = try_extract( $src, $name );
    return $fn if defined $fn;
    die "PageScript: no function '$name' in "
        . ( $where // 'the page' )
        . ". If it was renamed, update the test; if it was deleted, that is\n"
        . "the regression. This dies rather than returning undef because the\n"
        . "defect it exists to prevent was a test that skipped its own\n"
        . "assertions when an extraction stopped matching (SM684).\n";
}

1;

#!/usr/bin/perl
# SM965 (SM869 adversarial review, n270): a form prefill value and the form
# outcome banner cannot spell a `::: include` block.
#
# SM964 removed render_template's SECOND include pass, so a value reaching the
# page through the template stash can no longer become an include. This is the
# OTHER one: the form prefill (`prefill:x`) and the outcome banner
# (`?form=NAME&outcome=...`) are placed into the page body by convert_fenced_form
# BEFORE the FIRST include pass (process_md). SM869 made those sinks neutralise
# `[%` and the five HTML characters with `_tt_inert(_esc_html(...))` - but NOT
# CR/LF, which is what the stash copy encodes (`_esc_query_value`) for exactly
# this reason. A `?x=<newline-include>` value therefore spells a block the FIRST
# include pass resolves.
#
# VISITOR-CONTROLLED and reflected: the value rides in the query string. REACH
# (measured): `_resolve_include` confines to the request content root and its
# private twin and excludes lazysite/, so a value can pull any file under the
# content root that is not a published page (an unpublished .txt, a draft, a raw
# partial, a .md source) but NOT lazysite/, NOT an absolute path outside the
# docroot, NOT `..`. The fixture proves the positive before the fix and the
# boundary throughout.
#
# ONE PAYLOAD CLASS, not a working exploit: a line break, the fence word, a
# path, the closer. The assertion is the reader's - the named file is absent.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub enc  { my $s = shift; $s =~ s/([^A-Za-z0-9\-_.~])/sprintf( '%%%02X', ord $1 )/ge; return $s }

my $SECRET_TEXT = 'UNPUBLISHED-SECRET-TEXT';

my $docroot = site_tempdir();
setup_minimal_site($docroot);
# A file present under the docroot that is NOT a published page.
spit( "$docroot/unpublished-secret.txt", "$SECRET_TEXT\n" );
# And one inside the lazysite/ management tree, which the reach must never touch.
spit( "$docroot/lazysite/tree-secret.txt", "LAZYSITE-TREE-SECRET\n" );

spit(
    "$docroot/ta.md",
    "---\ntitle: TA\nform: apply\nquery_params:\n  - x\n---\n\n"
        . ":::form\nnote | Note | textarea prefill:x\ncode | Code | prefill:x\n:::\n"
);
spit( "$docroot/ban.md",
    "---\ntitle: Ban\nform: apply\n---\n\n::: form\nname | Name |\n:::\n" );

# The include payload a visitor supplies through the query string.
sub payload { my ($target) = @_; return "a\n::: include\n$target\n:::\n" }

# --- B: the form prefill textarea and input attribute -----------------------
{
    my $qs = 'x=' . enc( payload('/unpublished-secret.txt') );
    my $html = run_processor( $docroot, '/ta', QUERY_STRING => $qs ) // '';

    # The value IS rendered into both fields (canary - so the negative is a
    # finding and not an empty prefill). The literal 'a' prefix proves it.
    like( $html, qr/<textarea[^>]*>a/, 'canary: the textarea carries the value' );
    like( $html, qr/<input[^>]*name="code"[^>]*value="a/,
        'canary: the input carries the value' );

    # BEFORE (measured, n270 tip): the textarea value pulled the file in.
    TODO: {
        local $TODO = 'SM965: _tt_inert does not neutralise CR/LF, so a prefill '
            . 'value spells a block for the first include pass';
        unlike( $html, qr/\Q$SECRET_TEXT\E/,
            'B: a prefill value cannot name a file to include' );
    }
}

# --- C: the form outcome banner ---------------------------------------------
{
    my $qs = 'form=apply&outcome=' . enc( payload('/unpublished-secret.txt') );
    my $html = run_processor( $docroot, '/ban', QUERY_STRING => $qs ) // '';
    like( $html, qr/class="form-status form-status-error"/,
        'canary: the outcome banner is rendered' );
    TODO: {
        local $TODO = 'SM965: the outcome banner value is placed before the '
            . 'first include pass and its CR/LF is not neutralised';
        unlike( $html, qr/\Q$SECRET_TEXT\E/,
            'C: an outcome banner value cannot name a file to include' );
    }
}

# --- The reach boundary holds (independent of the fix) ----------------------
for my $target ( '/lazysite/tree-secret.txt', '../../../../etc/hostname' ) {
    my $qs = 'x=' . enc( payload($target) );
    my $html = run_processor( $docroot, '/ta', QUERY_STRING => $qs ) // '';
    unlike( $html, qr/LAZYSITE-TREE-SECRET|\broot:/,
        "the include reach excludes lazysite/ and traversal ($target)" );
}

# --- The display is preserved: a multi-line value still shows its lines ------
# The fix encodes CR/LF as &#10;/&#13;, which a browser renders as the line
# breaks the visitor typed - so a genuine multi-line prefill is not mangled.
{
    my $qs = 'x=' . enc("line one\nline two");
    my $html = run_processor( $docroot, '/ta', QUERY_STRING => $qs ) // '';
    like( $html, qr/line one.*line two/s,
        'a genuine multi-line value still carries both lines' );
}

done_testing();

#!/usr/bin/perl
# SM1252: A STEPPED FORM LEAVES THE MARKDOWN PASS AS A SINGLE-STEP ONE DOES.
#
# A multi-step form's output began with the chrome stylesheet's <link>, and the
# Markdown pass takes <form> for block HTML but not <link>. So it wrapped the
# head of the form in a paragraph - `<p><link ...><form ...>` hidden inputs
# `</p>` - and left `<p></form>` at the end; a browser turns those into empty
# <p> elements inside the form, which space every stepped form oddly (reported
# from the lazysite.io design kit, 2026-10-22, K-1).
#
# Rendered end to end, under a layout and without one, beside a single-step
# form as the control: no <p> opens or closes between <form and </form>, and
# none hugs the form's start.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site setup_test_site run_processor);

my %form = (
    stepped => "name | Name | required\n--- step: Contact ---\nemail | Email | required email\n"
        . "submit | Send\n",
    single => "name | Name | required\nemail | Email | required email\nsubmit | Send\n",
);

for my $site ( [ 'no layout', \&setup_minimal_site ], [ 'a layout', \&setup_test_site ] ) {
    my ( $where, $setup ) = @$site;
    for my $kind (qw(stepped single)) {
        my $d = tempdir( CLEANUP => 1 );
        $setup->($d);
        open my $fh, '>', "$d/apply.md" or die $!;
        print {$fh} "---\ntitle: Apply\nform: apply\n---\n\nIntro.\n\n::: form\n$form{$kind}:::\n\nAfter.\n";
        close $fh;
        my $out = run_processor( $d, '/apply' );

        my ($f) = $out =~ m{(<form method="POST".*?</form>)}s;
        ok( defined $f, "$where, $kind: the form rendered" ) or next;
        like( $f, qr/data-multistep/, "$where, $kind: it is the stepped form" ) if $kind eq 'stepped';
        like( $out, qr{<link rel="stylesheet" href="/assets/lazysite-chrome\.css},
            "$where, $kind: and still links the step stylesheet" ) if $kind eq 'stepped';
        unlike( $f, qr{</?p>}, "$where, $kind: no paragraph opens or closes inside the form" );
        unlike( $out, qr{<p>\s*(?:<link\b[^>]*>\s*)?<form method="POST"},
            "$where, $kind: and none wraps its start" );
        like( $out, qr{<p>After\.</p>}, "$where, $kind: the text after it is its own paragraph" );
    }
}

done_testing();

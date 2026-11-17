#!/usr/bin/perl
# SM923 limit 1: A LONG FORM HAS SECTIONS.
#
# A 31-field form was one undifferentiated run of fields. A `--- section: Heading | intro ---`
# line inside a `:::form` now groups the fields after it under a heading, rendered as a
# <fieldset class="lsf-section"> with a <legend> and an optional intro the fieldset is
# described by. It is presentation only:
#
#   * the section adds no name to the post and nothing to the rules the handler is held to
#     (the .rules sidecar is identical with and without it);
#   * a section ends at the next section, the next step, the submit button or the end;
#   * it nests inside a step;
#   * the heading and intro are escaped, and a `[% %]` in them is shown, not run;
#   * validate_page does not read the delimiter line as a field with an unknown rule.
#
# Sabotage: take the `section` branch out of _render_form - the fieldset assertions fail and
# the delimiter is read as a field (a stray input named "--- section: ...").
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir);
use Lazysite::Validate ();

my $d = site_tempdir();
load_processor($d);
make_path("$d/lazysite/forms");
{ no warnings "once"; $main::LAZYSITE_DIR = "$d/lazysite"; }

sub render {
    my ( $body, $name ) = @_;
    local $ENV{REDIRECT_URL} = '/apply';
    my $side = "$d/lazysite/forms/$name.rules";
    unlink $side;
    my $html = main::_render_form( $body, { form => $name } );
    my $rules;
    if ( -e $side ) {
        open my $fh, '<', $side or die "$side: $!";
        local $/;
        $rules = JSON::PP::decode_json(<$fh>);
    }
    return ( $html, $rules );
}

sub names { my ($h) = @_; return [ $h =~ /<(?:input|textarea|select)\b[^>]*\bname="([^"]+)"/g ] }

my $plain = "name | Your name | required\nemail | Email | required email\nnote | Note | textarea\nsubmit | Send\n";
my $sect  = "--- section: About you | Who you are. ---\nname | Your name | required\nemail | Email | required email\n"
    . "--- section: Anything else ---\nnote | Note | textarea\nsubmit | Send\n";

subtest 'a section is a fieldset with a legend and its intro' => sub {
    my ( $html, undef ) = render( $sect, 's1' );
    my @fs = $html =~ /<fieldset class="lsf-section"/g;
    is( scalar @fs, 2, 'two sections, two fieldsets' );
    like( $html, qr{<legend>About you</legend>}, 'the heading is the legend' );
    like( $html, qr{<legend>Anything else</legend>}, 'the second heading too' );
    like( $html, qr{<fieldset class="lsf-section" aria-describedby="(lsf-s1-sec1-intro)">}, 'the fieldset is described by its intro' );
    like( $html, qr{<p class="lsf-section-intro" id="lsf-s1-sec1-intro">Who you are\.</p>}, 'the intro carries that id' );
    unlike( $html, qr{lsf-s1-sec2-intro}, 'a section with no intro names none' );
    is( scalar( () = $html =~ m{</fieldset>}g ), 2, 'every fieldset is closed' );
    like( $html, qr{</fieldset>\s*<div class="form-field form-submit">}, 'the submit button is outside the last section' );
    unlike( $html, qr{name="--- section}, 'the delimiter is not read as a field' );
};

subtest 'what a handler receives does not change' => sub {
    my ( $h_plain, $r_plain ) = render( $plain, 's2' );
    my ( $h_sect,  $r_sect )  = render( $sect,  's2' );
    is_deeply( names($h_sect), names($h_plain), 'the same posted names, in the same order' );
    is_deeply( $r_sect, $r_plain, 'the same rules sidecar' );
    ok( $r_plain && @{ $r_plain->{fields} } == 3, 'control: the sidecar holds the three fields' );
};

subtest 'a section ends at the next step and nests inside one' => sub {
    my $body = "--- step: One ---\n--- section: A ---\nname | Name\n--- step: Two ---\nemail | Email\nsubmit | Go\n";
    my ( $html, undef ) = render( $body, 's3' );
    like( $html, qr{lsf-step.*?<fieldset class="lsf-section">.*?</fieldset>.*?</fieldset>.*?lsf-step}s,
        'the section sits inside step one and closes before step two' );
    is( scalar( () = $html =~ m{<fieldset}g ), scalar( () = $html =~ m{</fieldset>}g ), 'fieldsets balance' );
};

subtest 'a form with no section is rendered as before' => sub {
    my ( $html, undef ) = render( $plain, 's4' );
    unlike( $html, qr{lsf-section}, 'no section markup' );
    unlike( $html, qr{<fieldset}, 'no fieldset' );
};

subtest 'the heading and intro are escaped and inert' => sub {
    my ( $html, undef ) = render( "--- section: A <b>&</b> [% site_name %] | <i>x</i> ---\nname | N\n", 's5' );
    like( $html, qr{<legend>A &lt;b&gt;&amp;&lt;/b&gt; }, 'markup in the heading is text' );
    unlike( $html, qr{<b>}, 'no markup got through' );
    unlike( $html, qr{\[%\s*site_name}, 'a template tag does not survive as a tag' );
};

subtest 'validate_page reads the delimiter as a delimiter' => sub {
    my $page = "---\ntitle: T\nform: v\n---\n::: form\n--- section: A | one | two ---\nname | Name | required\n--- step ---\nsubmit | Go\n:::\n";
    my $r = Lazysite::Validate::validate_content( content => $page );
    my $all = join "\n", map { $_->{message} } @{ $r->{issues} || [] }, @{ $r->{warnings} || [] };
    unlike( $all, qr/unknown form rule|invalid-form-rule/, 'no complaint about the delimiter line' )
        or diag($all);
};

done_testing;

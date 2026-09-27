#!/usr/bin/perl
# SM871: a quoted rule value may contain a quote, written `\"`.
#
# THE FAULT, and its second half is the one that bites. The rule tokeniser
# matched `name:"([^"]*)"`, which cannot contain a quote at all - so
# `value:"before \" x"` stopped at the inner quote and the value became
# `before \`. The REMAINDER was then fed back through the same loop as further
# rules, and a leftover chunk still matches the valued rules, because those are
# matched with an unanchored regex rather than by equality. So a stray quote in
# a default could change a field's max, min, pattern or placeholder.
#
# Measured, and contrary to the filing's own headline example: it could NOT
# switch on `required`. The flags are compared with `eq`, so `required"` matches
# nothing and is silently dropped. The hazard is real; the example was wrong.
#
# The output was always safe - _esc_attr escapes whatever value survives, so the
# attribute closes and nothing is injected. What was wrong is that the field did
# not behave as written.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

my $docroot = site_tempdir();
setup_minimal_site($docroot);
load_processor($docroot);

sub render {
    my ($rules) = @_;
    return main::convert_fenced_form(
        "::: form\nroom | Room | $rules\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
}

subtest 'an escaped quote reaches the value instead of truncating it' => sub {
    my $out = render('value:"the \\"Old Barn\\" room"');

    # _esc_attr turns the quote into an entity, which is what keeps the
    # attribute closed. The point is that the WHOLE value is there.
    like( $out, qr/value="the &quot;Old Barn&quot; room"/,
        'the value carries both quotes and the words after them' )
        or diag( 'Before SM871 this rendered value="the \\", truncated at the '
            . 'first inner quote, and "Old Barn\\" room" became junk tokens.' );
    unlike( $out, qr/value="the \\"/,
        'and it is not the truncated form' );
};

subtest 'the remainder is no longer parsed as further rules' => sub {
    # max:5 is written by the author here and must still apply - the assertion
    # is that the VALUE is whole, not that the rule was lost.
    my $out = render('value:"a \\" b" max:5');
    like( $out, qr/value="a &quot; b"/, 'the value is whole' );
    like( $out, qr/maxlength="5"/,      'and the rule the author did write applies' );
};

subtest 'a leftover chunk could change a valued rule, and no longer can' => sub {
    # The defect in its sharpest form: the author wrote no max at all, and the
    # text after the truncation point supplied one.
    my $out = render('value:"a \\" max:5"');
    like( $out, qr/value="a &quot; max:5"/,
        'the whole literal is the value, max: included, because it is inside the quotes' );
    unlike( $out, qr/maxlength="5"/,
        'and no maxlength is invented from the inside of a literal' )
        or diag( 'This is the defect: the tokeniser truncated at the escaped '
            . 'quote and then read `max:5"` as a rule, so a default value '
            . 'silently capped the field.' );
};

subtest 'a regex escape in a pattern is left alone' => sub {
    # THE REGRESSION GUARD FOR THE FIX ITSELF. Unescaping every backslash -
    # rather than only \" - would turn \d into d and break every pattern in the
    # tree that uses one.
    my $out = render('pattern:"[0-9]\\d{3}"');
    like( $out, qr/pattern="\[0-9\]\\d\{3\}"/,
        'the backslash-d survives the unescape' )
        or diag( 'If this fails the fix unescaped too much: only \\" is an '
            . 'escape in a rule value.' );
};

subtest 'an unclosed quote is said out loud, and the other rules still apply' => sub {
    my $err = '';
    my $out;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $out = render('value:"never closed required');
    }
    like( $err, qr/unclosed quoted value/,
        'the log names the fault' );
    like( $err, qr/field=room/, 'and the field it is on' );
    like( $out, qr/ required/,
        'and `required` still applies, so a typo cannot quietly make a '
            . 'mandatory field optional' )
        or diag( 'Abandoning the rest of the line on a malformed value would '
            . 'weaken the form over a typo, which is worse than the fault.' );
};

done_testing();

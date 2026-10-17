#!/usr/bin/perl
# SM934 FV1-FV5: the rules a form DECLARES are the rules the server HOLDS it to.
#
# Measured in the handler before this was built: it performed exactly two content
# checks - uploads, and "not entirely blank" - and nothing else. `required`,
# `email`, `max:N` and `pattern:` reached the rendered HTML and stopped there, so
# they held for a visitor using a form and not at all for a direct POST, which is
# the traffic that needs them. A scanner put `' OR '1'='1'-- -` into a field
# declared `email` and it was stored.
#
# THE SIDECAR IN THIS TEST COMES FROM A REAL RENDER, and that is the point of the
# file's shape. A hand-written rules file would let the enforcement half pass
# against a spec the engine does not actually produce - which is the fixture
# fault this project keeps meeting (t/unit/plugins/08 and friends fed an empty
# user-agent to the classifier for a year because the fixture's key was `u` and
# the reader's was `ua`). So part 1 renders a page with a `:::form` block through
# the processor and asserts what was WRITTEN; part 2 enforces against that same
# file. If the two halves ever disagree about the schema, this file stops passing.
#
# WHY validate_fields IS LIFTED RATHER THAN POSTED TO. The handler is a CGI:
# loading it runs it. The sub is lifted the way t/unit/forms/30 lifts the rate
# limiter - one definition, no module to use - and `reject_user` is overridden so
# a refusal is an event this file can count rather than an exit.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site run_processor);

my $root = repo_root();
my $doc  = site_tempdir();
setup_test_site($doc);
make_path("$doc/lazysite/forms");

# A form the engine will accept: `key` in front matter names the form, and the
# .conf must exist or the handler refuses before any of this is reached.
open my $cf, '>', "$doc/lazysite/forms/enquiry.conf" or die $!;
print {$cf} "targets:\n  - handler: local-storage\n";
close $cf;

# One field per rule under test, plus the SM921 case: a pattern that is a VALID
# Perl regex and an INVALID HTML one. `(` and `)` unescaped inside a character
# class are syntax errors under the browser's `v` flag, so a browser ignores the
# attribute in full - and the server must too, or it refuses on a rule the
# visitor's browser never applied.
open my $pg, '>', "$doc/contact.md" or die $!;
print {$pg} <<'PAGE';
---
title: Enquiry
form: enquiry
---
:::form
name     | Your name      | required max:20
email    | Your email     | required email
website  | Your site      | url
quantity | How many       | number min:2 max:5
ref      | Reference      | pattern:[A-Z]{3}-[0-9]{4}
phone    | Phone          | tel
loose    | Loose          | pattern:[0-9 ()+.-]{4,10}
colour   | Colour         | required select:Red, Green, Blue
notes    | Notes          |
submit   | Send           |
:::
PAGE
close $pg;

my $html = run_processor( $doc, '/contact' );
like( $html, qr/<form /, 'the page rendered a form' ) or BAIL_OUT($html);

# --- part 1: what the render WROTE -------------------------------------------
my $rules_path = "$doc/lazysite/forms/enquiry.rules";
ok( -f $rules_path, 'rendering the form wrote its rules sidecar' )
    or do { done_testing(); exit };

my $spec = decode_json( do {
    open my $fh, '<', $rules_path or die $!;
    local $/;
    <$fh>;
} );
my %by = map { $_->{name} => $_ } @{ $spec->{fields} || [] };

subtest 'the sidecar records what the browser was told' => sub {
    is( $spec->{form}, 'enquiry', 'it names its form' );
    like( $spec->{note}, qr/do not edit/i,
        'and says it is derived, because it sits among files an operator maintains' );

    is( $by{name}{required}, 1,   'required is recorded' );
    is( $by{name}{max},      20,  'a declared max is recorded' );
    is( $by{name}{bound}, 'length', 'as a LENGTH bound on a text field' );
    is( $by{email}{type}, 'email', 'the email type is recorded' );
    is( $by{website}{type}, 'url', 'and url' );

    # The number field is the one where max means something else entirely.
    is( $by{quantity}{bound}, 'value',
        'on a number field max/min are VALUE bounds, not maxlength' )
        or diag( 'The render gives a number field `max=` and everything else '
            . '`maxlength=`. Recording one meaning for both would make the '
            . 'server enforce a length where the page enforced a magnitude.' );
    is( $by{quantity}{max}, 5, 'with its max' );
    is( $by{quantity}{min}, 2, 'and its min' );

    is( $by{ref}{pattern}, '[A-Z]{3}-[0-9]{4}', 'a declared pattern is recorded' );

    # SM921: `tel` is given a default pattern by the render. The sidecar must
    # carry that same default or the server would be looser than the page.
    ok( defined $by{phone}{pattern},
        "the tel default pattern is recorded, because the render applies one" )
        or diag( 'A tel field with no declared pattern still gets one in the '
            . 'HTML. If the sidecar omitted it the two would disagree.' );
    like( $html, qr/name="phone"[^>]*pattern="/,
        'and the page really does carry it - the parity is measured, not assumed' );

    # An undeclared max still reaches the browser as maxlength=1000.
    is( $by{notes}{max}, 1000,
        'a field with no declared max records the 1000 the render applies' );

    # A chooser gets `required` and nothing else: there is no maxlength or
    # pattern on a <select> to be parity with.
    is( $by{colour}{required}, 1, 'a required select is recorded' );
    ok( !exists $by{colour}{max}, 'but carries no max, as the render emits none' );
};

# --- part 2: enforcement, against that same file ------------------------------
my $src = do {
    open my $fh, '<', "$root/plugins/form-handler.pl" or die $!;
    local $/;
    <$fh>;
};
my ($sub) = $src =~ /^(sub validate_fields \{.*?^\})/ms
    or BAIL_OUT('could not lift validate_fields out of plugins/form-handler.pl');

# BOTH SUBS, because validate_fields refuses THROUGH reject_invalid and a stub
# written here would be a second definition of the thing under test. Lifting it
# is also what keeps this file honest about the reason codes: they come from the
# handler's own call, not from a copy in the fixture.
#
# This is not hypothetical tidiness. The first version of this file stubbed only
# reject_user; when reject_invalid was introduced the lifted validate_fields
# called an undefined sub, died inside the eval, and recorded no refusals - so
# every assertion would have passed vacuously. The guard below is what caught it.
my ($rej) = $src =~ /^(sub reject_invalid \{.*?^\})/ms
    or BAIL_OUT('could not lift reject_invalid out of plugins/form-handler.pl');

# SM1124: reject_invalid now refuses through `refuse`, which builds the message
# from the handler's %REFUSAL_SAID table - lifted too, so the wording asserted
# below is still the handler's own.
my ($refuse) = $src =~ /^(sub refuse \{.*?^\})/ms
    or BAIL_OUT('could not lift refuse out of plugins/form-handler.pl');
my ($rtext) = $src =~ /^(sub refusal_text \{.*?^\})/ms
    or BAIL_OUT('could not lift refusal_text out of plugins/form-handler.pl');
my ($table) = $src =~ /^(our %REFUSAL_SAID = \(.*?\n\);)/ms
    or BAIL_OUT('could not lift %REFUSAL_SAID out of plugins/form-handler.pl');

our @REJECTED;
{
    no strict 'refs';
    ## no critic
    eval "package FV;
        use strict; use warnings;
        use JSON::PP;
        our \$FORMS_DIR;
        our \$INVALID_REASON = '';
        sub reject_user { push \@main::REJECTED, [ \$_[0], \$INVALID_REASON ]; die \"USER\\n\" }
        $table
        $rtext
        $refuse
        $rej
        $sub
        1;
    " or BAIL_OUT("could not compile the lifted sub: $@");
}
# The lifted sub reads $FORMS_DIR from its own package, and `our` inside the
# eval binds it there. `no warnings 'once'` because this file assigns it and
# never reads it - which is also why the guard below exists rather than being
# left to a warning nobody reads.
{
    no warnings 'once';
    $FV::FORMS_DIR = "$doc/lazysite/forms";
}
unshift @INC, "$root/lib";    # the sub requires Lazysite::Validate by name

sub refusals;

# THE SUB IS REACHING THE SIDECAR. First, because every assertion below is
# satisfied by a validate_fields that returns immediately: `return unless
# defined $FORMS_DIR` and `return unless -f $path` are both early exits, and a
# lifted sub whose package variable never arrived would take one of them and
# refuse nothing, passing the whole file.
is( scalar @{ refusals( %{ { name => '' } } ) }, 1,
    'the lifted sub can see the rules file - a refusal happens at all' )
    or BAIL_OUT( 'validate_fields refused nothing on an empty required field, '
        . "so it is not reading $doc/lazysite/forms/enquiry.rules and every "
        . 'subtest below would pass vacuously.' );

sub refusals {
    my (%post) = @_;
    @REJECTED = ();
    eval { FV::validate_fields( 'enquiry', \%post ) };
    return [@REJECTED];
}

my %GOOD = (
    name     => 'Ada',
    email    => 'ada@example.com',
    website  => 'https://example.com',
    quantity => '3',
    ref      => 'ABC-1234',
    phone    => '01234 567890',
    loose    => '0123456',
    colour   => 'Red',
    notes    => 'hello',
);

# THE HANDLER ACTUALLY CALLS IT.
#
# Found by sabotage: deleting the call from the submission path left this whole
# file passing, because the lifted sub is invoked directly here and nothing
# exercised the call SITE. A validator nobody calls is exactly the shape SM934
# is about - `a declaration the code ignores` - so it is asserted, against the
# source, which is the only gate available while the handler is a CGI that runs
# when you load it.
#
# ORDER MATTERS AND IS PART OF THE ASSERTION: after the blank check (so an empty
# POST still gets the friendlier message) and before the spam assessment and
# delivery (so a refused submission is never stored, mailed or counted).
subtest 'the submission path calls it, in the right place' => sub {
    my ($call) = $src =~ /^(\s*validate_fields\( \$name, \\%form \);)/m;
    ok( $call, 'validate_fields is called on the submission path' )
        or diag( 'The sub can be perfect and unreachable. This is the assertion '
            . 'that a sabotage removing the call cannot pass.' );

    my $blank = index( $src, 'Please fill in the form before submitting' );
    my $call_at = index( $src, 'validate_fields( $name, \%form )' );
    my $spam  = index( $src, '_spam_assessment( \\%form, $conf )' );
    cmp_ok( $call_at, '>', $blank,
        'after the blank check, so an empty POST keeps its own message' );
    cmp_ok( $call_at, '<', $spam,
        'and before scoring and delivery, so a refusal is never stored' )
        if $spam >= 0;
};

subtest 'a good submission passes' => sub {
    my $r = refusals(%GOOD);
    is_deeply( $r, [], 'nothing refused' ) or diag explain $r;
};

subtest 'required is enforced, and names the field' => sub {
    my $r = refusals( %GOOD, email => '' );
    is( scalar @$r, 1, 'refused' );
    like( $r->[0][0], qr/'email'/, "and the message NAMES the field" )
        or diag( 'SM923: "invalid submission" sends somebody to the wrong '
            . 'place. The field and the rule are the message.' );
    is( $r->[0][1], 'field_required', 'with the rule as the reason code' );

    # A declared field absent from the post entirely is the same case.
    my %without = %GOOD;
    delete $without{email};
    is( scalar @{ refusals(%without) }, 1, 'a missing field counts as empty' );
};

subtest 'an optional declared field may be empty' => sub {
    # The complement of `required`, and the case that makes the required check
    # discriminating rather than "anything blank is refused". `notes` is
    # declared with no rules at all.
    is_deeply( refusals( %GOOD, notes => '' ), [],
        'a declared field with no `required` accepts an empty value' )
        or diag( 'Refusing every blank field would refuse a form that is '
            . 'working exactly as its author wrote it.' );
    my %without = %GOOD;
    delete $without{notes};
    is_deeply( refusals(%without), [], 'and so does omitting it entirely' );
};

subtest 'FV3: a field the form never declared cannot refuse anybody' => sub {
    my %extra = %GOOD;
    $extra{surprise} = '';
    is_deeply( refusals(%extra), [],
        'an undeclared empty field is not required' )
        or diag( 'required binds only on fields the form declares, so a '
            . 'visitor is never refused for a field they were not shown.' );
};

subtest 'email is enforced - the case the scanner exposed' => sub {
    for my $bad ( q{'}, q{' OR '1'='1'-- -}, 'not-an-address', 'a@b' ) {
        my $r = refusals( %GOOD, email => $bad );
        is( scalar @$r, 1, "refused: $bad" );
        is( $r->[0][1], 'field_email', 'as an email breach' );
    }
    is_deeply( refusals( %GOOD, email => 'a.b+c@sub.example.co.uk' ), [],
        'and a real address still passes' );
};

subtest 'max is a LENGTH on text and a VALUE on a number' => sub {
    my $r = refusals( %GOOD, name => 'x' x 21 );
    is( scalar @$r, 1, '21 characters in a max:20 text field is refused' );
    is( $r->[0][1], 'field_max', 'as a max breach' );
    is_deeply( refusals( %GOOD, name => 'x' x 20 ), [], 'exactly 20 passes' );

    # The same number in the same rule means something different here, which is
    # why `bound` is recorded rather than inferred.
    is_deeply( refusals( %GOOD, quantity => '5' ), [], 'quantity 5 passes' );
    is( refusals( %GOOD, quantity => '6' )->[0][1], 'field_max', '6 is refused' );
    is( refusals( %GOOD, quantity => '1' )->[0][1], 'field_min', '1 is refused' );
    is( refusals( %GOOD, quantity => 'seven' )->[0][1], 'field_number',
        'and a word in a number field is refused as a number' );
};

subtest 'pattern is enforced, ANCHORED as the browser anchors it' => sub {
    is_deeply( refusals( %GOOD, ref => 'ABC-1234' ), [], 'a matching value passes' );
    is( refusals( %GOOD, ref => 'abc-1234' )->[0][1], 'field_pattern',
        'a non-matching value is refused' );

    # The browser compiles ^(?:p)$ - a value that merely CONTAINS a match must
    # not pass, or the server is looser than the page it was rendered from.
    is( refusals( %GOOD, ref => 'xxABC-1234yy' )->[0][1], 'field_pattern',
        'and a value that only CONTAINS a match is refused too' )
        or diag( 'An unanchored match would accept the payload this filing came '
            . 'from through a pattern written to exclude it.' );
};

subtest 'FV2: a pattern the browser would IGNORE is ignored here too' => sub {
    # This is the hazard the ruling was written around, and it is SM921
    # inverted. `[0-9 ()+.-]` is a valid Perl character class and an invalid
    # HTML one: under the `v` flag `(`, `)` and a trailing `-` are syntax
    # errors, and the specification's answer to an uncompilable pattern is to
    # IGNORE THE ATTRIBUTE IN FULL. The browser therefore validated nothing on
    # this field. If the server compiled the same string as Perl and refused on
    # it, the visitor would be refused for a rule their browser never applied.
    require Lazysite::Validate;
    ok( length Lazysite::Validate::html_pattern_problem('[0-9 ()+.-]{4,10}'),
        'the fixture pattern really is one a browser cannot compile' )
        or diag( 'If this is empty the fixture has stopped exercising the case '
            . 'and every assertion below is vacuous.' );

    is_deeply( refusals( %GOOD, loose => 'anything at all' ), [],
        'so a value the pattern would reject is ACCEPTED' )
        or diag( 'Treating "cannot compile" as "nothing matches" would turn a '
            . 'form from accepting everything into accepting nobody, on one '
            . 'bad character.' );

    # And the form still works for everything else - the whole form must not be
    # taken out by one bad rule.
    is_deeply( refusals(%GOOD), [], 'and the rest of the form still validates' );
};

subtest 'no sidecar means no enforcement, not refuse-everybody' => sub {
    rename $rules_path, "$rules_path.away" or die $!;
    my $r = refusals( email => '', name => '' );
    is_deeply( $r, [],
        'a form with no rules file enforces nothing' )
        or diag( 'A form whose page has not been rendered since the upgrade '
            . 'must stay on the air. Refusing until a render happened would '
            . 'take working forms off live sites.' );
    rename "$rules_path.away", $rules_path or die $!;
};

done_testing();

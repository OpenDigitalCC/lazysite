#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- no form name in meta -> comment, no form tag ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | required\nsubmit | Send\n:::\n",
        {},
    );
    like(   $out, qr/form.*key required/i, 'comment mentions form key required' );
    unlike( $out, qr/<form\b/,              'no <form> tag rendered' );
}

# --- form with meta renders full form ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | required\nemail | Email | required email\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
    like( $out, qr/<form\b/,                 '<form> tag present' );
    # The form posts to the cgi-bin endpoint install.pl actually creates
    # (form-handler.pl, no lazysite- prefix - see UPGRADE.md rename).
    like(   $out, qr{action="/cgi-bin/form-handler\.pl"}, 'form action is the deployed handler name' );
    unlike( $out, qr{lazysite-form-handler},             'no stale lazysite- prefix on the action' );
    like( $out, qr/name="_ts"/,               'timestamp hidden field' );
    like( $out, qr/name="_tk"/,               'token hidden field' );
    like( $out, qr/name="_hp"/,               'honeypot field' );
    like( $out, qr/name="name"/,               'user-defined name field' );
    like( $out, qr/type="email"/,              'email type applied' );
    like( $out, qr/ required/,                 'required attribute present' );
    like( $out, qr/<button type="submit">Send<\/button>/,
          'submit button with label' );
    like( $out, qr/fetch\(form\.action/,       'JS fetch handler' );
    like( $out, qr/class="form-status"/,       'status live region' );
}

# --- new HTML5 field types + validation (date/tel/number/url/pattern) ---
{
    my $out = main::convert_fenced_form(
        "::: form\n"
      . "when   | Date      | required date\n"
      . "phone  | Phone     | tel\n"
      . "guests | Guests    | number min:1 max:20\n"
      . "site   | Website   | url\n"
      . "ref    | Reference | pattern:[A-Z]{3}\\d+\n"
      . "submit | Send\n:::\n",
        { form => 'booking' },
    );
    like(   $out, qr/type="date"/,                'date type applied' );
    like(   $out, qr/type="tel"[^>]*pattern=/,    'tel gets a default validation pattern' );
    like(   $out, qr/type="number"[^>]*min="1"/,  'number min value' );
    like(   $out, qr/type="number"[^>]*max="20"/, 'number max value (not maxlength)' );
    unlike( $out, qr/type="number"[^>]*maxlength=/, 'number field has no maxlength' );
    like(   $out, qr/type="url"/,                 'url type applied' );
    like(   $out, qr/pattern="\[A-Z\]\{3\}/,      'custom pattern applied' );
}

# --- quoted values carry spaces (placeholder / pattern with a space) ---
{
    my $out = main::convert_fenced_form(
        "::: form\n"
      . qq(fullname | Name  | required placeholder:"Your full name"\n)
      . qq(phone    | Phone | tel pattern:"[0-9 +()-]{7,20}"\n)
      . "submit | Send\n:::\n",
        { form => 'q' },
    );
    like( $out, qr/placeholder="Your full name"/, 'placeholder with spaces (quoted)' );
    like( $out, qr/pattern="\[0-9 /,              'pattern with a space (quoted)' );
}

# --- multi-word select options (select: takes the rest of the line) ---
{
    my $out = main::convert_fenced_form(
        "::: form\ndog | Dog | required select:No,Yes - one small to medium-sized dog\nsubmit | Go\n:::\n",
        { form => 'q' } );
    like( $out, qr/<option value="No">/, 'first select option intact' );
    like( $out, qr/<option value="Yes - one small to medium-sized dog">/,
        'multi-word select option renders whole (no truncation, no quotes needed)' );
}

# --- textarea rule renders <textarea> ---
{
    my $out = main::convert_fenced_form(
        "::: form\nmessage | Message | required textarea\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
    like(   $out, qr/<textarea\b/, 'textarea tag produced' );
    unlike( $out, qr/<input[^>]*name="message"/, 'no <input> for message' );
}

# --- select rule renders <select> with options ---
{
    my $out = main::convert_fenced_form(
        "::: form\ncolour | Colour | select:red,green,blue\nsubmit | Send\n:::\n",
        { form => 'c' },
    );
    like( $out, qr/<select\b/,                '<select> tag' );
    like( $out, qr/<option value="red">red/,  'option red' );
    like( $out, qr/<option value="green">green/, 'option green' );
    like( $out, qr/<option value="blue">blue/,   'option blue' );
}

# --- max rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | max:100\nsubmit | Send\n:::\n",
        { form => 'c' },
    );
    like( $out, qr/maxlength="100"/, 'maxlength applied' );
}

# --- form name sanitised: front-matter sanitisation strips / characters.
#     Because parse_yaml_front_matter has already sanitised the form name
#     before convert_fenced_form sees it, we simulate that here.
{
    my $bad = '../../../etc/evil';
    ( my $clean = $bad ) =~ s/[^a-zA-Z0-9_-]//g;
    my $out = main::convert_fenced_form(
        "::: form\nsubmit | Send\n:::\n",
        { form => $clean },
    );
    unlike( $out, qr{\.\./},                  'no traversal sequence in output' );
    like(   $out, qr/data-form="$clean"/,      'sanitised form name used' );
}

# --- SM098: single-page form is NOT multi-step (backward compatible) ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | required\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
    unlike( $out, qr/data-multistep/,      'no data-multistep on a single-step form' );
    unlike( $out, qr/class="lsf-step"/,    'no step fieldsets on a single-step form' );
    unlike( $out, qr/lsf-progress/,        'no progress indicator on a single-step form' );
}

# --- SM098: '--- step ---' delimiters produce a multi-step form ---
{
    my $out = main::convert_fenced_form(
        "::: form\n"
      . "name | Name | required\n"
      . "--- step: Contact details ---\n"
      . "email | Email | required email\n"
      . "phone | Phone | tel\n"
      . "--- step ---\n"
      . "message | Message | textarea required\n"
      . "submit | Send\n"
      . ":::\n",
        { form => 'apply' },
    );
    like( $out, qr/data-multistep="1"/,          'multi-step form marked with data-multistep' );
    my @steps = ( $out =~ /class="lsf-step"/g );
    is( scalar @steps, 3,                          'three step fieldsets rendered' );
    like( $out, qr/<legend>Contact details<\/legend>/, 'titled step gets a legend' );
    like( $out, qr/lsf-progress[^>]*>Step /,      'progress indicator present' );
    like( $out, qr/class="lsf-back"/,              'Back button present' );
    like( $out, qr/class="lsf-next"/,              'Next button present' );
    like( $out, qr/of 3</,                          'progress shows the step count' );
    # Progressive enhancement: every field is in the HTML (all steps present).
    like( $out, qr/name="name"/,                    'step 1 field present' );
    like( $out, qr/name="email"/,                   'step 2 field present' );
    like( $out, qr/name="message"/,                 'step 3 field present' );
    like( $out, qr/type="submit"/,                  'submit button present (final step)' );
    like( $out, qr/lsf-js/,                          'step-navigation script wires the js class' );
    like( $out, qr/reportValidity/,                 'per-step validation before advancing' );
    # The single hidden token/honeypot machinery is unchanged.
    like( $out, qr/name="_tk"/,                     'token field still present' );
    like( $out, qr/name="_hp"/,                     'honeypot still present' );
}

# --- SM098: a leading delimiter does not create an empty first step ---
{
    my $out = main::convert_fenced_form(
        "::: form\n--- step: One ---\na | A | required\n--- step: Two ---\nsubmit | Send\n:::\n",
        { form => 'x' },
    );
    my @steps = ( $out =~ /class="lsf-step"/g );
    is( scalar @steps, 2,   'leading delimiter does not spawn an empty first step' );
}

done_testing();

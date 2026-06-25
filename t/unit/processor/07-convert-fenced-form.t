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

done_testing();

#!/usr/bin/perl
# SM888 A5: a required checklist of ONE box carries `required`, so it cannot be
# submitted unticked.
#
# WHY IT WAS OMITTED, and why that was right until it was not. On a radio group
# the browser reads `required` as "one of the group"; on checkboxes it reads it
# as "this box". So marking every box in a multi-select required would demand
# that all of them be ticked, which is the opposite of what a multi-select
# means - and the renderer therefore left `required` off checkbox groups
# entirely.
#
# A GROUP OF ONE IS THE EXCEPTION, and the reasoning above is what makes it one:
# with a single box, "this box" and "one of the group" are the same box, so the
# browser's meaning is exactly the author's. Leaving it off there applied the
# general rule past its reason, and a field the author marked required submitted
# empty. The single-box case is most often a consent tick, so the case where an
# unticked box matters most was the case least enforced.
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
        "::: form\nagree | Agree | $rules\nsubmit | Send\n:::\n",
        { form => 'contact' },
    );
}

subtest 'one box, required, so the browser demands it' => sub {
    my $out = render('required checklist:I agree to the terms');
    like( $out, qr/type="checkbox"/, 'it is a checkbox' );
    my ($input) = $out =~ /(<input type="checkbox"[^>]*>)/;
    ok( defined $input, 'the input was found' ) or return;
    like( $input, qr/ required/,
        'and it carries required, so an unticked box fails in the browser' )
        or diag( 'Before SM888 A5 this rendered without required, so a field '
            . "the author marked required submitted empty.\n  got: $input" );
};

subtest 'more than one box keeps required off' => sub {
    # THE REASON THE RULE EXISTS. If required were applied per box here, the
    # browser would demand every option be ticked.
    my $out    = render('required checklist:Post,Email,Phone');
    my @inputs = $out =~ /(<input type="checkbox"[^>]*>)/g;
    is( scalar @inputs, 3, 'three boxes' );
    for my $i (@inputs) {
        unlike( $i, qr/ required/,
            'no box in a multi-select is individually required' )
            or diag( 'Applying required per box would demand all three, which '
                . 'is not what a multi-select means.' );
    }
};

subtest 'a single box that is NOT required stays optional' => sub {
    my $out = render('checklist:Add me to the list');
    my ($input) = $out =~ /(<input type="checkbox"[^>]*>)/;
    ok( defined $input, 'the input was found' ) or return;
    unlike( $input, qr/ required/,
        'required is not invented for a single box the author left optional' );
};

subtest 'the quantity variant behaves the same way' => sub {
    my $out = render('required checklist-qty:Chairs');
    my ($input) = $out =~ /(<input type="checkbox"[^>]*>)/;
    ok( defined $input, 'the input was found' ) or return;
    like( $input, qr/ required/,     'a single quantity box is required too' );
    like( $out,   qr/type="number"/, 'and still carries its quantity input' );
};

done_testing();

#!/usr/bin/perl
# SM1469 R1: validate_page knows `type:hidden` (no unknown-rule warning) and
# refuses a hidden field that has neither value: nor prefill:.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Validate ();

sub check {
    my ($rules) = @_;
    my $page = "---\ntitle: T\nform: f\n---\n\n::: form\nx | X | $rules\nsubmit | Send\n:::\n";
    return Lazysite::Validate::validate_content( content => $page );
}

my $r = check('type:hidden value:"spring"');
is( scalar @{ $r->{issues} },   0, 'a hidden field with value: has no issue' );
is( scalar @{ $r->{warnings} }, 0, 'and no unknown-rule warning' ) or diag explain $r->{warnings};

$r = check('type:hidden prefill:ref');
is( scalar @{ $r->{issues} }, 0, 'prefill: is a value too' );

$r = check('type:hidden');
is( scalar( grep { $_->{kind} eq 'invalid-form-rule' && $_->{message} =~ /hidden field 'x' has no value/ }
        @{ $r->{issues} } ), 1, 'no value: and no prefill: is refused' ) or diag explain $r;

$r = check('type:hidden value:');
is( scalar( grep { $_->{kind} eq 'invalid-form-rule' } @{ $r->{issues} } ), 1, 'an empty value: is no value' );

done_testing;

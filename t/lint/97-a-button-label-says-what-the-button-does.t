#!/usr/bin/perl
# SM699: the manager's button labels come from one vocabulary.
#
# The manager used 107 distinct labels, with Save/Update/Apply all meaning
# commit, Cancel/Close/Dismiss all meaning stop, and Delete/Remove/Clear all
# meaning destroy-or-not. An operator who learns one page has to relearn the
# next, and the difference between two of those words is sometimes a WARNING -
# so using them interchangeably removes a signal rather than adding a synonym.
#
# THIS TEST DOES NOT POLICE EVERY LABEL. Most of the 107 are correct and the
# choice between them needs judgement a regex cannot make: `Apply` is right for
# putting a prepared package into effect and wrong for saving a form; `Remove`
# is right for taking a row out of a list it can be put back into and wrong for
# destroying; `Update` is right for bringing an installed package to the
# catalogue version and wrong as a synonym for Save. What it DOES police is the
# short list of words the guide bans outright, so a reconciliation that has been
# made cannot quietly come undone.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root  = "$FindBin::Bin/../..";
my $guide = "$root/starter/manager/style-guide.md";
ok( -f $guide, 'the style guide is present' ) or BAIL_OUT("no $guide");

# Words with no remaining legitimate use in the manager, and what to use.
# A word earns a place here only once every occurrence has been reconciled -
# otherwise this is a failing test that documents a backlog, which nobody runs.
my %banned = (
    'Dismiss' => 'Close when nothing is lost; the actual opposite verb '
        . '(Deny, Reject) when the button DECIDES something',
);

my @found;
for my $f ( glob "$root/starter/manager/*.md" ) {
    ( my $name = $f ) =~ s{.*/}{};
    next if $name eq 'style-guide.md';   # the guide names them to ban them
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    while ( $src =~ /<button\b[^>]*>([^<]{1,40})<\/button>/g ) {
        my $label = $1;
        $label =~ s/^\s+|\s+$//g;
        push @found, "$name: '$label' - use " . $banned{$label}
            if $banned{$label};
    }
}

is( "@found", '', 'no manager page uses a banned label' )
    or diag( "Banned labels still emitted:\n  " . join( "\n  ", @found ) );

# The guide has to actually say so, or this test is enforcing a rule that
# exists only here - and the next person reads the guide, not the test.
my $g = do { open my $fh, '<', $guide or die $!; local $/; <$fh> };
for my $word ( sort keys %banned ) {
    like( $g, qr/\Q$word\E/,
        "the guide explains why '$word' is not used" )
        or diag( 'A ban with no published reason reads as an arbitrary '
            . 'preference, and the next author reinstates it.' );
}

# The specific case that prompted the ban: a button that WRITES an authority
# must not read like closing a notice. Groups pairs Grant with its real
# opposite now.
my $groups = "$root/starter/manager/groups.md";
if ( -f $groups ) {
    my $s = do { open my $fh, '<', $groups or die $!; local $/; <$fh> };
    if ( $s =~ /capDecide\(/ ) {
        like( $s, qr/capDecide\([^)]*false\)">Deny</,
            'the deny half of a capability decision says Deny' )
            or diag( 'capDecide(...,false) writes value:off - it denies a '
                . 'pending capability. Labelled Dismiss, an operator could '
                . 'decide an authority question without knowing they had.' );
    }
}

done_testing();

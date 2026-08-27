#!/usr/bin/perl
# SM427: a permission says what it grants, in full, where the decision is made.
# SM636: and the group list says which groups can be given to a person at all.
#
# SM421 ruled that PERMISSION IS THE CONTROL - where a capability is granted,
# every surface delivers it in full - which makes the GRANT the decision point.
# That only works if the person granting knows what they are granting, and the
# Groups grid gave them a two-word label.
#
# FACTS, NOT WARNINGS, per the filing's own instruction. "manage_forms lets this
# group choose where a form's submissions are delivered, including to an address
# or URL you have not pre-defined" is something an operator can weigh. "Warning:
# dangerous!" is not, and it teaches people to click past. That is why the
# assertions below check for the CONSEQUENCE being named rather than for any
# particular alarming word.
#
# THE SENTENCES ARE SERVED, NOT RESTATED. The Groups page already carries a
# hardcoded label list with a comment admitting it must match @CAP_KEYS; a
# second copy of the SENTENCES - the part that has to be right - would drift
# from Capabilities.pm the moment either changed. SM277 set this precedent in
# the very same API action and for the very same reason.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Capabilities ();

my $root = "$FindBin::Bin/../../..";
my $caps = Lazysite::Capabilities::describe()->{capabilities} || {};

# --- 1. every capability says what it grants --------------------------------
{
    my @silent = sort grep { !length( $caps->{$_}{grants} // '' ) } keys %$caps;
    is_deeply( \@silent, [],
        'every capability carries a plain-sentence statement of what it hands over' )
        or diag("silent: @silent");
    cmp_ok( scalar keys %$caps, '>=', 19, 'and there are capabilities to check' );
}

# --- 2. the sentences are sentences, not restated titles --------------------
# A `grants` that merely echoes the title adds nothing and would pass a
# presence check. It has to say something the label does not.
{
    my @echoes;
    for my $k ( sort keys %$caps ) {
        my ( $g, $t ) = ( $caps->{$k}{grants}, $caps->{$k}{title} );
        push @echoes, $k if lc( substr( $g, 0, 40 ) ) eq lc( substr( $t, 0, 40 ) );
        push @echoes, "$k (too short)" if length($g) < 60;
    }
    is_deeply( \@echoes, [], 'none merely repeats the title, or stops at a phrase' )
        or diag("@echoes");
}

# --- 3. the ones with a consequence NAME it ---------------------------------
# Chosen because each is a capability whose reach surprised somebody this
# month - the filings say so - and the sentence must carry the fact that
# surprised them, not a warning about it.
{
    like( $caps->{audit}{grants}, qr/whole instance|INSTANCE/i,
        'audit says the trail is instance-wide' );
    like( $caps->{audit}{grants}, qr/\bIP\b/,
        'and that entries carry a source IP' );
    like( $caps->{manage_forms}{grants}, qr/not.{0,20}pre-defined|nobody has pre-defined/i,
        'manage_forms says delivery can go somewhere nobody pre-defined' );
    like( $caps->{manage_forms}{grants}, qr/submitt|IP/i,
        'and that it reads what visitors sent' );
    like( $caps->{purge}{grants}, qr/instance-wide|other sites/i,
        'purge says the backup store reaches other sites' );
    like( $caps->{manage_config}{grants}, qr/switch|service/i,
        'manage_config says it reaches the service switches - the SM633 question' );
    like( $caps->{manage_data}{grants}, qr/no domain|any site/i,
        'manage_data says an unscoped table is reachable from any site here' );
    like( $caps->{manage_users}{grants}, qr/Manager UI only|no remote/i,
        'manage_users says it has no remote surface' );

    # And NOT alarm words - the instruction was facts an operator can weigh.
    my @shouty = sort grep { $caps->{$_}{grants} =~ /\b(?:WARNING|DANGER|CAUTION)\b/i }
        keys %$caps;
    is_deeply( \@shouty, [],
        'no sentence shouts - a warning teaches people to click past it' );
}

# --- 4. served, not restated ------------------------------------------------
{
    my $api = do { open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!; local $/; <$fh> };
    like( $api, qr/grants\s*=>\s*\\%grants/,
        'the API serves the sentences' );
    like( $api, qr/Lazysite::Capabilities::describe\(\)->\{capabilities\}/,
        'from Capabilities.pm, which stays the one source' );

    my $page = do { open my $fh, '<', "$root/starter/manager/groups.md" or die $!; local $/; <$fh> };
    like( $page, qr/CAP_GRANTS = d\.grants/,
        'the Groups page takes them from the response' );
    unlike( $page, qr/Choose where a form's submissions/,
        'and does NOT carry its own copy of the copy' );
}

# --- 5. SM636: the list says which groups can be given to a person ----------
{
    my $page = do { open my $fh, '<', "$root/starter/manager/groups.md" or die $!; local $/; <$fh> };
    # Bounded by the END OF THE ASSIGNMENT, not by the first semicolon: an HTML
    # ENTITY contains one (&#128230;), so a lazy match to `;` stopped inside the
    # backend badge and the role half was never examined - three assertions
    # passed on text that happened to sit before the cut.
    my ($b) = $page =~ /(var backend = \(info\.assignable === false\).*?<\/span>';\n)/s;
    ok( $b, 'the assignable marker is built' );
    like( $b, qr/backend/, 'a backend group is marked' );
    like( $b, qr/role/, 'and an assignable one is marked too - the absence of '
            . 'a badge stopped meaning anything once ten bundles shipped beside nine roles' );
    like( $b, qr/&#128100;|&#128230;/, 'with an icon, as asked' );
    like( $b, qr/Assign it from an account/,
        'and the role badge says where to actually do it' );
}

done_testing();

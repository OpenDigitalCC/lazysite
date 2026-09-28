package Lazysite::Egress;

# SM579 / X4: WHO MAY CAUSE THIS INSTANCE TO SEND SOMETHING OUTWARD.
#
# The three invocation modes were ruled on 2026-09-03 and described from the
# start as "the outbound policy for the whole programme". They were then
# written inside Lazysite::Manager::Connectors, which is where the first caller
# lived - so the policy was a connector's private business, and anything else
# wanting to send outward had two choices: reach into a manager module for a
# package variable, or grow its own copy.
#
# X4 (ruled 2026-09-28) is what forces this out. The Odoo extension's per-user
# proxy leg (SM747) must sit as "mode 2 INSIDE SM579's policy, not beside it",
# and there was no inside to sit in. The alternative the ruling refused was a
# second transport wearing the connector's name; the alternative it did not have
# to consider was a second copy of the mode rule, because two copies of one
# security decision is the shape SM662 had just finished removing from the
# control API's capability gate.
#
# WHAT BELONGS HERE: the two questions that are the same wherever something
# leaves this site - "may this caller cause this callee to be invoked", and
# "has this already happened too often" - and the vocabulary they are asked in.
#
# AN EARLIER VERSION OF THIS HEADER PUT CAPS OUTSIDE, and that was too broad a
# line. It said a cap "is counted from a call RECORD, so it belongs with
# whatever holds the records". The counting does. The DECISION does not: every
# caller needs the same answer to "which axis was breached, by how much, and
# what does the operator change", and SM579 says in its own words that SM747's
# per-identity cap "should be this one rather than a second implementation". So
# the split is: the caller counts, because only it knows its own records; this
# module decides and words the refusal.
#
# Still NOT here:
#
#   * the transport - what a user agent may follow, verify or read. That is
#     Lazysite::Fetch's SSRF guard for content-chosen destinations and the
#     connector's own agent for operator-chosen ones (SM790).
#   * the records themselves. Nothing here opens a file.
#   * credentials. Where a secret lives and how it reaches the wire is the
#     callee's business and differs per caller kind by design - a connector
#     holds one operator secret, the Odoo proxy holds none and replays the
#     visitor's own.
#
# The distinction is worth keeping because every one of those has a different
# owner, and a module that collected them all would be the "multipurpose tool"
# the release manager's boundary on SM579 forbids.
#
# THE MODE IS WHAT THE CALLER *IS*, NEVER WHAT IT ASKS FOR. The control API
# says `authenticated` because a session was verified; the form handler says
# `public` because anyone could have posted; the scheduler says `scheduled`
# because no human was present. A caller that could name its own mode would be
# choosing its own gate.
use strict;
use warnings;

# The vocabulary, declared once. Order matters only in messages, where it is
# the order a reader sees the three modes listed in.
our @MODES = qw(scheduled authenticated public);

sub modes { return @MODES }

sub is_mode {
    my ($m) = @_;
    return ( defined $m && grep { $_ eq $m } @MODES ) ? 1 : 0;
}

# may_invoke( %args ) -> ( $ok, $why )
#
#   mode      what the caller IS - one of @MODES
#   permits   the callee's own map, { scheduled => 1, public => 0, ... }
#   what      the noun for messages: 'connector', 'proxy'. Default 'callee',
#             which is deliberately ugly: a caller that forgets to say what it
#             is produces a message somebody wants to fix.
#   callers   groups the callee names as permitted callers (authenticated only)
#   groups    the caller's own groups
#   caps      the caller's capabilities
#   override  a capability that stands in for group membership, e.g.
#             manage_connectors. Omitted means no override exists, which is a
#             stricter callee rather than a broken one.
#   opt_in    the mode whose refusal carries the "it is opt-in" hint, and the
#             config key that turns it on. Default: public, modes.public.
#
# THE REFUSAL NAMES WHAT WOULD WORK, not only what did not (SM807). For a
# connector that exists to run on a timer, the word `scheduled` is the one that
# closes the question, and the reader should not have to open the store to find
# it.
sub may_invoke {
    my (%a)     = @_;
    my $mode    = $a{mode} // '';
    my $what    = $a{what} // 'callee';
    my $permits = ref $a{permits} eq 'HASH' ? $a{permits} : {};
    my $opt_in  = defined $a{opt_in}        ? $a{opt_in}  : 'public';

    return ( 0, "mode '$mode' is not one of " . join( ', ', @MODES ) )
        unless is_mode($mode);

    unless ( $permits->{$mode} ) {
        my @on = grep { $permits->{$_} } @MODES;
        return ( 0,
            "this $what does not permit $mode invocation"
                . ( $mode eq $opt_in
                ? " - $opt_in is opt-in, set modes.$opt_in on the $what"
                : '' )
                . ( @on
                ? ' (it permits: ' . join( ', ', @on ) . ')'
                : ' (it permits no mode at all)' ) );
    }

    # An authenticated caller is a known account, which is not the same as an
    # ADMITTED one: the callee still says which groups may call it. The
    # override capability is the operator's way past that, and it is checked
    # first because holding it makes the group question moot.
    if ( $mode eq 'authenticated' ) {
        my $caps     = ref $a{caps} eq 'HASH'     ? $a{caps}         : {};
        my @groups   = ref $a{groups} eq 'ARRAY'  ? @{ $a{groups} }  : ();
        my @admitted = ref $a{callers} eq 'ARRAY' ? @{ $a{callers} } : ();

        return ( 1, '' ) if defined $a{override} && $caps->{ $a{override} };

        my %in = map { $_ => 1 } @groups;
        return ( 1, '' ) if grep { $in{$_} } @admitted;

        return ( 0,
            "this account is in none of the groups the $what names as callers"
                . ( @admitted
                ? ' (' . join( ', ', @admitted ) . ')'
                : ' - and it names none' ) );
    }

    return ( 1, '' );
}

# within_caps( %args ) -> ( $ok, $why )
#
#   what   the noun for messages, as above
#   axes   an ordered list of { name, limit, used, window, setting }, MOST
#          SPECIFIC FIRST. The first breach is the one reported, because
#          "this recipient has had three already" tells an operator more than
#          "the site has sent sixty", and a refusal that reports the widest
#          axis sends them looking in the wrong place.
#
# THE COUNTING IS THE CALLER'S. Only it knows where its records are. What it
# passes here is the answer, and `used` has THREE states rather than two:
#
#   a number  - counted
#   undef     - COULD NOT COUNT, which is not zero
#
# An axis whose count could not be taken REFUSES. This is the release's own
# lesson applied to a cap: a counter that will not open must not read as "this
# has never happened", because that is the one reading that disables the control
# exactly when something is wrong. A cap honoured only while its record is
# readable is not a cap.
#
# A `limit` of undef means the caller declares NO cap on that axis, which is a
# different statement from a cap of zero: zero refuses everything, undef does
# not look. It is skipped, and the caller's own defaults decide whether that can
# happen - for a path that mails an address a stranger supplied, it must not.
sub within_caps {
    my (%a)  = @_;
    my $what = $a{what} // 'callee';
    my @axes = ref $a{axes} eq 'ARRAY' ? @{ $a{axes} } : ();

    for my $ax (@axes) {
        next unless ref $ax eq 'HASH';
        my $name    = $ax->{name}    // 'unnamed';
        my $window  = $ax->{window}  // 'hour';
        my $setting = $ax->{setting} // '';

        if ( !defined $ax->{used} ) {
            return ( 0,
                "this $what cannot tell how much of its $name cap is already "
                    . "used - the record would not open, so the cap cannot be "
                    . "honoured and nothing was sent (see the event log)" );
        }
        next unless defined $ax->{limit};

        if ( $ax->{used} >= $ax->{limit} ) {
            return ( 0,
                "this $what has reached its $name cap: $ax->{used} already in "
                    . "this $window and the cap is $ax->{limit}"
                    . ( length $setting ? " - raise $setting to allow more" : '' ) );
        }
    }
    return ( 1, '' );
}

1;

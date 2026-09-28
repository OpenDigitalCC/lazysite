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
# WHAT BELONGS HERE: the question "may this caller cause this callee to be
# invoked", and the vocabulary that question is asked in. Nothing else. In
# particular NOT:
#
#   * the transport - what a user agent may follow, verify or read. That is
#     Lazysite::Fetch's SSRF guard for content-chosen destinations and the
#     connector's own agent for operator-chosen ones (SM790).
#   * rate or spend caps. A cap is counted from a call RECORD, so it belongs
#     with whatever holds the records; SM579 still owns both as open rows.
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

1;

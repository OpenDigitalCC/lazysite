#!/usr/bin/perl
# SM618: two capabilities that return personal data described themselves as
# though they did not.
#
# Measured on edge 2026-08-26 under partner grants holding one capability each:
#
#   `audit`        - 93 pages of the WHOLE instance's trail, six distinct
#                    actors, 180 full IPv4 dotted-quads in 192 sampled entries,
#                    and origins `ui`/`cli`/`install`, which are the operator's
#                    own sessions. The reply says `scoped: false` itself.
#   `manage_forms` - live submission bodies: name, email, phone, message and
#                    the submitter's IP, under the grant an operator gives an
#                    agent so it can WIRE UP a form.
#
# Neither reach is a defect. The operator's ruling (2026-08-26) is that the
# trail stays instance-wide on `purge`'s SM577 precedent - an agent asked "what
# changed and who changed it" needs the whole trail. What was wrong is that
# `purge` says so in its own title and these two did not.
#
# `audit` is the sharper case because of its NEIGHBOUR. It sits beside
# `analytics`, which promises "sanitised, IP-anonymised" and keeps that promise.
# A pair where one declares anonymisation and the other declares nothing invites
# the inference that the trail read is at least as careful. It is the opposite.
#
# So these assertions are about the DECLARATION, not the behaviour: the title is
# what an operator reads at the moment of granting, and it is the only thing
# they read. t/unit/manager/114 pins the same property for `purge`; this is that
# test's sibling, and the three capabilities should be changed together or not
# at all.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Capabilities ();

my $map  = Lazysite::Capabilities::describe();
my $caps = $map->{capabilities};

# --- 1. audit says the trail is instance-wide, and says whose data is in it --
{
    my $t = $caps->{audit}{title};
    like( $t, qr/instance/i, 'the audit description says the trail is instance-wide' );
    like( $t, qr/not scoped|other site|OTHER/,
        'and that the grant authorising the read does not bound it' );

    # The two that make it a PERSONAL-DATA disclosure rather than a breadth
    # one. An operator can accept breadth and still want to know about these.
    like( $t, qr/\bIP\b/,     'and that entries carry a source IP' );
    like( $t, qr/raw/i,       'stated as raw rather than left to inference' );
    like( $t, qr/actor|who/i, 'and that entries name the actor' );

    # A-6 was the part that mattered most in the field report: `ui`, `cli` and
    # `install` are not partner traffic. A partner token holding one capability
    # reads the OPERATOR's own sessions, with the IP each came from.
    # SM659: the word changed, and that this test broke on it is the argument
    # for changing it. `operator` meant the app's full-access person HERE and
    # the shell user elsewhere, and an assertion on the bare word could not
    # tell which - so it passed while the ambiguity it was pinning was the
    # thing SM618 was trying to describe.
    like( $t, qr/sysop/i,
        'and that the SYSOP\'s own sessions are among them - named as the '
            . 'app principal, not as whoever happens to be at a shell' );
}

# --- 2. the pair no longer makes opposite promises in silence ----------------
# analytics was already right. The finding was about the CONTRAST, so the fix is
# only complete if the two are legible side by side - which is how
# describe-capabilities presents them.
{
    like( $caps->{analytics}{title}, qr/anonymis|sanitis/i,
        'analytics still declares its anonymisation' );
    like( $caps->{audit}{title}, qr/analytics/,
        'and audit points at it, so the difference is not left to be inferred' );
}

# --- 3. manage_forms says it reads submissions, not just wires them ----------
# The old title spent its words on the NOTIFICATION never carrying content,
# which reads as a statement about the grant. It is a statement about the bell.
{
    my $t = $caps->{manage_forms}{title};
    like( $t, qr/submitted|submission/i,
        'manage_forms says it reads what was submitted' );
    like( $t, qr/read_submissions/,
        'and names the least-privilege alternative for an agent that only processes leads' );
    like( $t, qr/\bIP\b/, 'and that a submission carries the submitter\'s IP' );
}

# --- 4. the declaration matches the gate, which is why it had to change ------
# This is the assertion that would have caught it originally: form-submissions
# is admitted by EITHER capability, so a title describing only the wiring
# understates the grant. If the gate is ever narrowed to read_submissions alone,
# this fails and the title above becomes wrong - deliberately coupled.
{
    my %under;
    for my $c ( Lazysite::Capabilities::action_keys() ) {
        push @{ $under{$_} }, $c for @{ $caps->{$c}{unlocks}{api} || [] };
    }
    # SM652 NARROWED THIS, and SM618's requirement survives the change. SM618's
    # point was that a capability must DECLARE the personal data it hands over;
    # it asserted both capabilities admitted the read because both did. Only
    # read_submissions does now - manage_forms is definition-only - so the
    # declaration is simpler rather than weaker, and the map must not advertise
    # a read manage_forms can no longer perform.
    my @admit = sort @{ $under{'form-submissions'} || [] };
    is_deeply( \@admit, ['read_submissions'],
        'form-submissions is admitted by read_submissions ALONE, and the map '
            . 'says so - manage_forms advertising it would be a claim the gate '
            . 'refuses' )
        or diag( explain $under{'form-submissions'} );
}

done_testing();

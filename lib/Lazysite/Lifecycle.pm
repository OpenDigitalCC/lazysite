package Lazysite::Lifecycle;

# SM222: one shape for "is this thing on, and is it working".
#
# THE WHOLE DESIGN IS THE DISAGREEMENT BETWEEN TWO ANSWERS. The configuration
# records INTENT - somebody switched this on. Observation records REALITY - it
# is running, or it is not. Everything interesting to an operator lives in the
# gap: a unit that is meant to be on and is not, or one that is off and still
# answering.
#
# Nothing in this system modelled that. A service reported enabled or not
# enabled, so an operator could not distinguish "off because I turned it off"
# from "off because it died" - the same word for opposite problems.
#
# EXEMPLAR-FIRST, following ADR 0009. The contract is defined here and the
# daemon is its first conforming consumer, because the daemon is the unit whose
# lifecycle is least ambiguous: it is a process, so "running" is a fact rather
# than an interpretation. The existing services - WebDAV, control API, MCP,
# OAuth, token exchange - migrate afterwards, one per SM, exactly as the plugins
# did. A contract extracted from one real consumer beats one designed in the
# abstract and retrofitted five times.
#
# WHAT THIS IS NOT, and SM222 is explicit: not a process supervisor. systemd
# keeps that job. This reports; it does not manage.
#
# THE VOCABULARY IS content-history's, not a new one. Lazysite::Git::health
# already derives `verdict` and `healthy` over exactly this problem and has been
# right about it since it shipped - `inconsistent` for config-says-on but
# broken, `degraded` for working-but-hurt. SM222's own text says that model is
# what proves the design, so generalising it is the honest move; a second
# vocabulary beside it would be the sixth place a reader learns one distinction
# (SM662's shape).
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(lifecycle_status verdicts is_verdict);

our $VERSION = '0.1';

# The closed set. A verdict outside it is a bug in the caller rather than a new
# state, and is_verdict exists so a caller can be TOLD that rather than quietly
# handing an operator a word nothing else understands.
#
#   off           desired off, and off. Nothing wrong.
#   starting      desired on, not answering yet. Transient by definition.
#   on            desired on, and on.
#   degraded      on and working, but something is wrong that will bite.
#   inconsistent  desired on, NOT on. The disagreement this exists to surface.
#   failed        tried and could not - distinct from inconsistent, which has
#                 not necessarily tried.
my @VERDICTS   = qw(off starting on degraded inconsistent failed);
my %IS_VERDICT = map { $_ => 1 } @VERDICTS;

sub verdicts   { return @VERDICTS }
sub is_verdict { return $_[0] && $IS_VERDICT{ $_[0] } ? 1 : 0 }

# Build the common shape.
#
# A caller passes what it KNOWS - the unit's name, whether config says on,
# whether it is observably running - and the verdict is DERIVED here, so two
# units cannot come to disagree about what `inconsistent` means by each
# deciding for themselves. That is the failure this contract exists to prevent,
# one level up from the one it reports.
#
# `remedy` is required whenever the verdict is not healthy, and that is
# deliberate rather than defensive: SM712, SM730, SM749 and SM750 are four
# filings in one week about messages that named a state without naming an
# action. A status that says `inconsistent` and stops is the same defect
# wearing a different surface.
sub lifecycle_status {
    my (%a) = @_;

    my $unit    = $a{unit} // '';
    my $kind    = $a{kind} // 'service';
    my $desired = $a{desired_on} ? 'on' : 'off';

    my $verdict;
    if ( defined $a{verdict} ) {
        # A caller that genuinely knows better - a unit that tried to start and
        # failed knows `failed` in a way no derivation can.
        $verdict = $a{verdict};
    }
    elsif ( !$a{desired_on} ) { $verdict = 'off' }
    elsif ( $a{running} )     { $verdict = $a{degraded} ? 'degraded' : 'on' }
    else {
        # Desired on and not running. `starting` only when the caller says a
        # start is in flight; otherwise this IS the disagreement.
        $verdict = $a{starting} ? 'starting' : 'inconsistent';
    }

    my $healthy = ( $verdict eq 'on' || $verdict eq 'off' ) ? 1 : 0;

    return {
        unit    => $unit,
        kind    => $kind,
        desired => $desired,
        verdict => $verdict,
        healthy => $healthy,
        message => $a{message} // _default_message( $unit, $verdict ),
        ( defined $a{since}  ? ( since => $a{since} )   : () ),
        ( defined $a{by}     ? ( by => $a{by} )         : () ),
        ( defined $a{detail} ? ( detail => $a{detail} ) : () ),
        ( $healthy ? () : ( remedy => $a{remedy} // _default_remedy($verdict) ) ),
    };
}

# A message is always present, because a status an operator cannot read sends
# them to ask somebody. The caller's own sentence is better and is preferred;
# this is the floor, not the intent.
sub _default_message {
    my ( $unit, $verdict ) = @_;
    my %m = (
        off          => "$unit is off",
        starting     => "$unit is starting",
        on           => "$unit is running",
        degraded     => "$unit is running, with a problem",
        inconsistent => "$unit is switched on but is not running",
        failed       => "$unit tried to start and could not",
    );
    return $m{$verdict} // "$unit is in a state this version does not name";
}

sub _default_remedy {
    my ($verdict) = @_;
    my %r = (
        starting     => 'wait a moment, then ask again',
        degraded     => 'see the site log for what is failing',
        inconsistent =>
            'the configuration says this should be running and it is not - '
            . 'check the host service and the site log',
        failed => 'see the site log for why the start failed',
    );
    return $r{$verdict} // 'see the site log';
}

1;

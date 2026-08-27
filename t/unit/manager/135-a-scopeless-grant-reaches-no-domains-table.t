#!/usr/bin/perl
# SM648: a grant with no dav_scopes reached no site package and every data
# table - one absence of scope, two opposite defaults, on one instance in one
# request.
#
# IT WAS NOT A DEFAULT SOMEBODY CHOSE. _may_reach returned early on empty
# @CALLER_SCOPES, and the source says why: "EMPTY MEANS UNCONFINED, which is
# the operator - never 'no domains'. The CLI and the processor's render path
# leave it empty and are unaffected." So three callers arrived as one value:
# the CLI, the render path, and a token grant with no domain access. The first
# two mean "no confinement applies"; the third means "confined to nothing".
#
# WHICH MADE "FLIP THE DEFAULT" UNAVAILABLE. Failing closed on empty would
# confine the CLI and the render path too, and a render path that reaches no
# table serves a page with its data missing - on every site, not only
# multi-domain ones. Very likely why packages could fail closed under SM578 and
# tables could not: packages have no render path and no CLI reading them
# through the same predicate.
#
# So the fix is a third state, not a different default:
#   undef/0 - unconfined            the CLI, the render path, a cookie operator
#   1 + []  - confined to nothing   a grant with no domain access
#   1 + [..] - confined to these
#
# WHAT IS ASSERTED
#   an unconfined caller still reaches everything - the CLI does not regress
#   a scopeless CONFINED caller reaches only tables that name no domain
#   a scoped caller is unchanged
#   the instance-wide table is still reachable by all of them - SM593's
#     upgrade-day promise, which is the SECOND escape and stays
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Data ();

# The predicate under test, with its two lookups stubbed so this measures the
# CONFINEMENT decision rather than the table store or the domain registry.
{
    no warnings 'redefine';
    *Lazysite::Manager::Data::_table_domain =
        sub { $_[0] eq 'bound' ? 'alpha.test' : '' };
    *Lazysite::Manager::Data::_caller_domains =
        sub { @Lazysite::Manager::Data::CALLER_SCOPES ? ('alpha.test') : () };
}
my $reach = \&Lazysite::Manager::Data::_may_reach;

sub as {
    my ( $confined, @scopes ) = @_;
    local @Lazysite::Manager::Data::CALLER_SCOPES  = @scopes;
    local $Lazysite::Manager::Data::CALLER_CONFINED = $confined;
    return { bound => $reach->('bound'), free => $reach->('free') };
}

# --- unconfined: the CLI, the render path, a cookie operator ---------------
# The regression that would matter most. A render path reaching no table serves
# a page with its data silently missing, on every site.
for my $who ( 'the CLI / render path', 'a cookie operator' ) {
    my $r = as(0);
    ok( $r->{bound}, "$who still reaches a domain-bound table" );
    ok( $r->{free},  "$who still reaches an unscoped table" );
}

# --- confined, with scopes: unchanged --------------------------------------
my $scoped = as( 1, '/sites/alpha' );
ok( $scoped->{bound}, 'a scoped grant reaches its own domain\'s table' );
ok( $scoped->{free},  'and the instance-wide table' );

# --- confined, with none: the finding --------------------------------------
my $none = as(1);
ok( !$none->{bound},
    'a grant with no domain access reaches NO domain-bound table' )
    or diag( 'This is the defect: it read every table on the instance, because '
        . 'an empty scope set presented as "unconfined" rather than as "no '
        . 'domains" - the same value the CLI uses.' );

# --- and SM593's promise is kept -------------------------------------------
# The SECOND escape, which is deliberate and stays: a table naming no domain
# behaves exactly as it did before per-domain tables existed, so an instance
# upgrading does not have its live tables emptied out from under their
# applications. Confining that too would be a different and much worse change.
ok( $none->{free},
    'but still reaches a table that names no domain - the instance-wide '
        . 'exception SM593 promised on upgrade day' );

# --- the two states are genuinely distinct ---------------------------------
# If the flag were ignored, these two would agree, and the whole change would
# be inert while every assertion above still passed for the unconfined rows.
isnt( $none->{bound}, as(0)->{bound},
    'confined-to-nothing and unconfined give DIFFERENT answers - the flag is '
        . 'read, not merely set' );

done_testing();

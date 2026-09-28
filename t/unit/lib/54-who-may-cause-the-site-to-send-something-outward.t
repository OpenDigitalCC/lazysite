#!/usr/bin/perl
# SM579 / X4: the invocation-mode policy is ONE policy, and it is not the
# connector's private business.
#
# X4 (ruled 2026-09-28) put the Odoo proxy leg "as mode 2 INSIDE SM579's policy,
# not beside it". There was no inside: the three modes, the decision and the
# refusal wording lived in Lazysite::Manager::Connectors, so the only ways for a
# second egress path to honour the same rule were to reach into a manager module
# for a package variable or to keep a second copy of a security decision - which
# is the shape SM662 had just spent a release removing from the control API.
#
# WHAT THIS FILE HOLDS, and why each row is here rather than assumed:
#   * the vocabulary is declared once, and the connector POINTS at it. A copy
#     that happens to be equal today is the defect, so the test is on identity.
#   * the refusal LISTS the modes it derived them from. A hardcoded list in a
#     message is how a fourth mode would ship invisible.
#   * the refusal names what WOULD work (SM807), and the opt-in hint appears
#     only for the mode that is opt-in.
#   * the message says what the callee IS. A proxy refusing a call must not
#     call itself a connector, which is the row that proves the policy is
#     shared rather than renamed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Egress              ();
use Lazysite::Manager::Connectors ();

my @ALL = qw(scheduled authenticated public);

subtest 'one declaration, and the connector points at it' => sub {
    is_deeply( [ Lazysite::Egress::modes() ], \@ALL, 'the three modes, in order' );

    is( $Lazysite::Manager::Connectors::MODES, \@Lazysite::Egress::MODES,
        'Connectors::$MODES IS the policy list, not a copy of it' )
        or diag( 'Two lists that are equal today drift the day a fourth mode '
            . 'is added to one of them. X4 requires one vocabulary.' );

    ok( Lazysite::Egress::is_mode($_), "$_ is a mode" ) for @ALL;
    ok( !Lazysite::Egress::is_mode('bogus'), 'bogus is not' );
    ok( !Lazysite::Egress::is_mode(''),      'the empty string is not' );
    ok( !Lazysite::Egress::is_mode(undef),   'undef is not - and does not warn' );
};

subtest 'a mode that is not a mode is refused, and the message lists the real ones' => sub {
    my ( $ok, $why ) = Lazysite::Egress::may_invoke(
        mode => 'sideways', what => 'connector', permits => { public => 1 } );
    ok( !$ok, 'refused' );
    like( $why, qr/\bsideways\b/, 'naming what was asked for' );
    like( $why, qr/\b$_\b/, "and listing $_" ) for @ALL;
};

subtest 'the refusal names what would work, not only what did not (SM807)' => sub {
    my ( $ok, $why ) = Lazysite::Egress::may_invoke(
        mode => 'public', what => 'connector', permits => { scheduled => 1 } );
    ok( !$ok, 'public refused by a scheduled-only callee' );
    like( $why, qr/it permits: scheduled/, 'and says what it does permit' );
    like( $why, qr/public is opt-in/,      'with the opt-in hint' );

    my ( $ok2, $why2 ) = Lazysite::Egress::may_invoke(
        mode => 'scheduled', what => 'connector', permits => { public => 1 } );
    ok( !$ok2, 'scheduled refused by a public-only callee' );
    unlike( $why2, qr/opt-in/,
        'and the opt-in hint does NOT appear for a mode that is not opt-in' )
        or diag( 'The hint is advice about one setting. Attached to every '
            . 'refusal it stops being advice.' );

    my ( $ok3, $why3 ) = Lazysite::Egress::may_invoke(
        mode => 'public', what => 'connector', permits => {} );
    ok( !$ok3, 'a callee permitting nothing refuses' );
    like( $why3, qr/it permits no mode at all/, 'and says so plainly' );
};

subtest 'the message says what the callee IS' => sub {
    my ( undef, $why ) = Lazysite::Egress::may_invoke(
        mode => 'public', what => 'proxy', permits => { scheduled => 1 } );
    like( $why, qr/this proxy does not permit/, 'a proxy is called a proxy' )
        or diag( 'If the noun is fixed, the policy was renamed rather than '
            . 'shared, and the second caller cannot use its refusals.' );
    unlike( $why, qr/connector/, 'and never a connector' );

    my ( undef, $dflt ) = Lazysite::Egress::may_invoke(
        mode => 'public', permits => { scheduled => 1 } );
    like( $dflt, qr/this callee does not permit/,
        'a caller that names nothing gets a word somebody will want to fix' );
};

subtest 'authenticated: a known account is not an admitted one' => sub {
    my %base = ( mode => 'authenticated', what => 'connector',
        permits => { authenticated => 1 }, override => 'manage_connectors' );

    my ( $ok1 ) = Lazysite::Egress::may_invoke( %base,
        callers => ['tools'], groups => ['tools'] );
    ok( $ok1, 'in a named group: admitted' );

    my ( $ok2, $why2 ) = Lazysite::Egress::may_invoke( %base,
        callers => [ 'tools', 'ops' ], groups => ['strangers'] );
    ok( !$ok2, 'in none of them: refused' );
    like( $why2, qr/tools, ops/, 'and the refusal names the groups that would work' );

    my ( $ok3, $why3 ) = Lazysite::Egress::may_invoke( %base,
        callers => [], groups => ['tools'] );
    ok( !$ok3, 'a callee naming no groups admits nobody by group' );
    like( $why3, qr/and it names none/, 'and says that, rather than listing an empty set' );

    my ( $ok4 ) = Lazysite::Egress::may_invoke( %base,
        callers => [], groups => [], caps => { manage_connectors => 1 } );
    ok( $ok4, 'the override capability gets past a callee that names nobody' );

    # The override is the CALLEE's to name. A policy that always honoured
    # manage_connectors would let a connector's operator grant open a proxy.
    my ( $ok5 ) = Lazysite::Egress::may_invoke(
        mode => 'authenticated', what => 'proxy',
        permits => { authenticated => 1 },
        callers => [], groups => [], caps => { manage_connectors => 1 } );
    ok( !$ok5, 'a callee that declares no override is not opened by somebody else\'s' )
        or diag( 'manage_connectors is the connector\'s override. Honouring it '
            . 'for every callee would make one grant a master key.' );
};

subtest 'scheduled and public need no group - the mode IS the gate' => sub {
    for my $m (qw(scheduled public)) {
        my ($ok) = Lazysite::Egress::may_invoke(
            mode => $m, what => 'connector', permits => { $m => 1 } );
        ok( $ok, "$m is admitted on the permission alone" );
    }
};

subtest 'the connector still answers for itself, in its own words' => sub {
    my $c = { modes => { authenticated => 1 }, callers => ['tools'] };

    my ( $ok, $why ) = Lazysite::Manager::Connectors::may_call( $c,
        mode => 'public' );
    ok( !$ok, 'a public call to an authenticated-only connector is refused' );
    like( $why, qr/this connector does not permit public/, 'in the connector\'s words' );

    my ($ok2) = Lazysite::Manager::Connectors::may_call( $c,
        mode => 'authenticated', groups => ['tools'] );
    ok( $ok2, 'a named caller is admitted' );

    my ($ok3) = Lazysite::Manager::Connectors::may_call( $c,
        mode => 'authenticated', groups => ['nobody'],
        caps => { manage_connectors => 1 } );
    ok( $ok3, 'and manage_connectors is still the connector\'s override' );

    my ( $ok4, $why4 ) = Lazysite::Manager::Connectors::may_call( $c,
        mode => 'authenticated', groups => ['nobody'], caps => {} );
    ok( !$ok4, 'without either: refused' );
    like( $why4, qr/groups the connector names as callers/, 'naming the connector' );
};

subtest 'a callee whose permissions are missing refuses rather than dies' => sub {
    for my $p ( undef, '', 'yes', [] ) {
        my ( $ok, $why ) = Lazysite::Egress::may_invoke(
            mode => 'public', what => 'connector', permits => $p );
        ok( !$ok, 'refused' );
        like( $why, qr/does not permit public/, 'as a refusal, not a crash' );
    }
};

done_testing();

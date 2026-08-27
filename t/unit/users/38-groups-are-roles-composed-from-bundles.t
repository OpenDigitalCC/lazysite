#!/usr/bin/perl
# SM631: the seeded groups are roles an operator recognises, composed from
# capability and channel bundles.
#
# What shipped was six FLAT groups, two of which - agent-ai and mcp-ai - carried
# IDENTICAL capability sets and differed only in channel. One fact stored twice:
# add a capability to the agent role and its MCP twin drifts, silently, and an
# operator looking at an agent whose MCP column is all dots gets no hint a
# sibling group exists.
#
# The capability model separates WHAT a grant may do from WHICH DOOR it comes
# through everywhere except here. Now: cap-* bundles, ch-* bundles, and role-*
# compositions - and only the roles are assignable, so the layering is enforced
# (SM616) rather than merely documented.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "manager_groups: sysops\n";
close $c;
system( $^X, $tool, '--docroot', $d, 'setup-sysop', '--user', 'sjm' ) == 0
    or plan skip_all => 'setup-sysop failed';

$Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
require Lazysite::Auth::Settings;
Lazysite::Auth::Settings->import(qw(caps_for));

require JSON::PP;
my $gs = JSON::PP::decode_json(
    do { open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!; local $/; <$fh> } );

sub role_caps {
    my ($role) = @_;
    open my $g, '>>', "$d/lazysite/auth/groups" or die $!;
    print {$g} "$role: probe-$role\n";
    close $g;
    my $c = caps_for("probe-$role");
    return sort grep { $c->{$_} } keys %$c;
}

# --- 1. a role resolves to the union of its bundles -------------------------
# The composition IS the feature. Asserted through caps_for - the same resolver
# the gate uses - so a role that reads right on the page but resolves wrong at
# the door cannot pass.
{
    my @web = role_caps('agent-ai');
    is_deeply( \@web,
        [ qw(analytics api manage_content manage_forms manage_layouts
                manage_nav manage_themes mcp webdav) ],
        'the AI web developer role resolves to content + design + analytics, '
            . 'over both doors - analytics because the role always had it, which '
            . 'the first cut of this change silently dropped' )
        or diag("got: @web");

    my @app = role_caps('app-developers');
    ok( ( grep { $_ eq 'manage_data' } @app ), 'the app developer role reaches data tables' );
    ok( ( grep { $_ eq 'mcp' } @app ),         'over MCP' );
    ok( !( grep { $_ eq 'manage_themes' } @app ),
        'and not design - the two agent roles differ, rather than being one group twice' );
}

# --- 2. only roles are assignable -------------------------------------------
# The layering is enforced by group-add refusing a backend group, so a bundle
# that were left assignable would be handed to a person by accident.
{
    my @bundles = grep { /^(?:cap|ch)-/ } sort keys %$gs;
    cmp_ok( scalar @bundles, '>=', 8, 'capability and channel bundles are seeded' );
    my @wrong = grep { $gs->{$_}{assignable} } @bundles;
    is_deeply( \@wrong, [], 'no bundle is assignable to a person' )
        or diag("assignable bundles: @wrong");

    my @roles = grep { $gs->{$_}{assignable} } sort keys %$gs;
    cmp_ok( scalar @roles, '>=', 6, 'roles are seeded' );
    my @unassignable = grep { !$gs->{$_}{assignable} } @roles;
    is_deeply( \@unassignable, [], 'every role IS assignable - that is what a role is' );
}

# --- 3. every group says what it grants -------------------------------------
# The operator asked for tooltips. A description that is missing renders as a
# tooltip naming the raw group, which is the state this replaces.
{
    # Bundles AND roles. An earlier revision of this test narrowed the pattern
    # to cap-*/ch-* when the roles took their established names back, which
    # dropped exactly the groups an operator READS - a sabotage removing a
    # role's description passed. The operator asked for tooltips; the roles are
    # what the tooltip is for.
    my @named = grep { /^(?:cap|ch)-/ || $gs->{$_}{assignable} } sort keys %$gs;
    cmp_ok( scalar @named, '>=', 17, 'bundles and roles are both being checked' );
    my @nodesc = grep { !length( $gs->{$_}{description} // '' ) } @named;
    is_deeply( \@nodesc, [], 'every seeded bundle and role carries a description' )
        or diag("missing: @nodesc");
}

# --- 4. purge is in no bundle -----------------------------------------------
# The irreversible tier stays a separate, explicit decision (SM587/SM591). A
# bundle carrying it would hand it over as a side effect of a job title.
{
    my @carry = grep { $gs->{$_}{purge} } grep { /^(?:cap|ch)-/ } sort keys %$gs;
    is_deeply( \@carry, [],
        'no bundle or role carries purge - destroying the last copy is never '
            . 'a side effect of being given a job' );
}

# --- 5. the channel/capability split is real --------------------------------
# The defect this replaces was two groups differing only by channel. If a
# capability bundle also granted a channel, the split would be decorative.
{
    my @cap_with_channel;
    for my $g ( grep { /^cap-/ } sort keys %$gs ) {
        push @cap_with_channel, $g
            if grep { $gs->{$g}{$_} } qw(ui webdav api mcp);
    }
    is_deeply( \@cap_with_channel, [],
        'a capability bundle grants no channel - the two axes stay separate' );

    for my $g ( grep { /^ch-/ } sort keys %$gs ) {
        my @caps = grep { $gs->{$g}{$_} }
            qw(manage_content manage_nav manage_forms manage_themes manage_layouts
            manage_data manage_users manage_config manage_domains);
        is_deeply( \@caps, [], "$g grants no capability, only a door" );
    }
}

# --- 6. composing roles must not defeat the conferral ceiling ---------------
# THE REGRESSION THIS CHANGE INTRODUCED AND AN OLDER TEST CAUGHT.
#
# _caps_granted_by_group answers "what does a person ACQUIRE by being put in
# this group?", which is the ceiling's whole question. It walked DOWNWARD, over
# the group's own members. That was harmless while every role carried its
# capabilities directly - and composing roles from bundles made every role's own
# settings EMPTY, so the ceiling looked at a role, found nothing to confer, and
# allowed the assignment. A manage_users delegate could put anyone into any
# role, including ones conferring api, mcp and purge.
#
# t/unit/users/30 caught it, having guarded this since SM195; this test did not.
# So it is pinned HERE too, against the composed roles specifically, because
# that is the shape that broke it.
{
    # The refusal is a die, so it lands on STDERR. A pipe-open takes stdout
    # only, and the first version of this assertion failed for that reason
    # while the behaviour was correct - the message was there, just not where
    # the test was looking. Quoted per-argument (t/lint/40) rather than
    # interpolating a list into the string.
    my $out = sub {
        my $cmd = join ' ', map { "\Q$_\E" } ( $^X, $tool, '--docroot', $d, @_ );
        return `$cmd 2>&1` // '';
    };
    $out->( 'add',       'ceil-delegate', 'pw12345678' );
    $out->( 'group-add', 'ceil-delegate', 'user-managers' );
    $out->( 'add',       'ceil-target',   'pw12345678' );

    my $r = $out->( 'group-add', 'ceil-target', 'agent-ai', 'ceil-delegate' );
    like( $r, qr/you may not confer/,
        'a manage_users delegate cannot put someone into a composed role whose '
            . 'capabilities arrive by nesting' )
        or diag("got: $r");
    unlike( $r, qr/^User .* added to group/m,
        'and the assignment does not happen' );
}

done_testing();

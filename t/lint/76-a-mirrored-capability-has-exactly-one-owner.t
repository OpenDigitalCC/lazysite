#!/usr/bin/perl
# ADR 0009 / SM447: a capability declared by an extension is MIRRORED in the core
# lists, and the mirror must have exactly one owner.
#
# SM1369 X2 (H-7): THE MIRROR IS BUILT FROM THE INDEX, NOT FROM LITERALS. The
# runtime keeps a static literal for what CORE implements (@CORE_CAP_KEYS, and
# Capabilities' %ACTION_INFO) and fills the rest from the site's extension
# index, which the manager writes from the descriptors of the installed
# extensions when one is enabled, disabled, saved or upgraded - so the request
# path never runs --describe (ten subprocesses on it is not a trade worth
# making), and no core line names a capability an extension owns (t/lint/321).
# This lint builds that index for the tree (Manager::Extensions::engine_hook_index
# runs --describe here, where it is cheap), mirrors it as a door does, and
# holds each state that would otherwise be silent:
#
#   A declaration with NO description - an owned capability its extension does
#   not describe (hooks.capability_info). It would be grantable and say nothing
#   of what it grants; the index build refuses it, and this says so for the tree.
#
#   TWO owners - two extensions declaring one capability. Whichever is asked
#   answers for both, and disabling one leaves the other's grant half-live.
#
#   A LITERAL for a declared capability - a name in core's list that an
#   extension owns. The mirror would be filled twice, and the extension's
#   declaration would be a copy of a copy.
#
#   A mirror with NO owner - a capability in the core list that no extension
#   declares and that core does not implement either: grantable in the UI and
#   unlocking nothing, which reads to an operator as a broken permission.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP                 ();
use TestHelper               qw(mirror_engine);
use Lazysite::Auth::Settings ();
use Lazysite::Capabilities   ();

my $root       = "$FindBin::Bin/../..";
my $extensions = "$root/extensions";
plan skip_all => 'no extensions directory' unless -d $extensions;

my @core_literal = Lazysite::Auth::Settings::core_capability_keys();

# The index for this tree, before and after the mirror: what is declared, and
# what the tables say once it is read.
my $index    = mirror_engine();
my $declared = $index->{declared} || {};

# Every capability every extension declares, and who declares it: from the
# index's declared view for an extension that describes its capabilities
# (hooks.capability_info), and from --describe for one that only owns them
# (`owns.capabilities` alone: data, briefs and the daemon, until each describes
# its own and leaves the literal). The two states are told apart below.
my ( %claimed_by, %described );
for my $id ( sort keys %$declared ) {
    for my $c ( @{ $declared->{$id}{capabilities} || [] } ) {
        push @{ $claimed_by{$c} }, $id;
        $described{$c} = $id if ref $declared->{$id}{capability_info}{$c} eq 'HASH';
    }
}
for my $f ( sort glob "$extensions/*.pl" ) {
    # SM666: SCALAR FIRST - in list context backticks return lines and
    # decode_json would see the first line only.
    my $raw = `$^X \Q$f\E --describe 2>/dev/null`;
    my $d   = eval { JSON::PP::decode_json($raw) };
    next unless ref $d eq 'HASH' && ref $d->{owns} eq 'HASH';
    my $id = $d->{id} // ( $f =~ s{.*/}{}r );
    next if $declared->{$id};    # read from the index above
    push @{ $claimed_by{$_} }, $id for @{ $d->{owns}{capabilities} || [] };
}

subtest 'the index refused no declaration' => sub {
    is_deeply( $index->{refused}, [], 'every in-tree declaration validates and is indexed' )
        or diag explain $index->{refused};
};

subtest 'no capability is claimed by two extensions' => sub {
    my @twice = grep { @{ $claimed_by{$_} } > 1 } sort keys %claimed_by;
    is_deeply( \@twice, [], 'each declared capability has one owner' )
        or diag( join "\n  ", '',
        map { "$_ is claimed by: " . join( ', ', @{ $claimed_by{$_} } ) } @twice );
};

subtest 'every declared capability is grantable and described' => sub {
    my %cap_key = map { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
    my $map     = Lazysite::Capabilities::describe()->{capabilities} || {};
    for my $c ( sort keys %claimed_by ) {
        my $id = $claimed_by{$c}[0];
        ok( $cap_key{$c}, "$c (declared by $id) is in \@CAP_KEYS" )
            or diag( 'A capability that is not in @CAP_KEYS cannot be granted '
                . 'to anybody, so the extension\'s actions are unreachable and '
                . 'nothing says why.' );
        ok( $map->{$c}, "$c is described in Lazysite::Capabilities" )
            or diag( 'describe-capabilities is how a partner learns what it '
                . 'holds. An undescribed capability is one an agent cannot '
                . 'discover.' );
        next unless $described{$c};
        is( $map->{$c}{extension}, $id, "and the map says $c is ${id}'s" );
        is( Lazysite::Auth::Settings::capability_declared_by($c), $id, "as \@CAP_KEYS does" );
    }
};

# SM1369 X2: ONE STATE EACH. A capability its extension describes
# (hooks.capability_info) is mirrored from the index and is not a core literal;
# one its extension only owns is mirrored in the literal, as before X2, until
# the extension describes it - never both, never neither.
subtest 'a described capability is mirrored from the index, an undescribed one in the literal' => sub {
    my %core    = map { $_ => 1 } @core_literal;
    my %section = map { $_ => 1 } @Lazysite::Capabilities::SECTIONS;
    for my $c ( sort keys %claimed_by ) {
        if ( my $id = $described{$c} ) {
            ok( !$core{$c}, "$c is described by $id, and is not a core literal" )
                or diag('The mirror is filled from the index; a literal for it is the copy X2 removed.');
            my $info = $declared->{$id}{capability_info}{$c};
            ok( $section{ $info->{section} // '' }, "$c declares a section the grids know ($info->{section})" );
            ok( length( $info->{label} // '' ), "$c declares the grid's label" );
        }
        else {
            ok( $core{$c}, "$c is owned by $claimed_by{$c}[0] and not described, so the literal still mirrors it" )
                or diag( 'An owned capability nobody describes and no literal carries cannot be granted. '
                    . 'Describe it in the extension\'s hooks.capability_info, or keep the literal.' );
        }
    }
    cmp_ok( scalar( grep { $described{$_} } keys %claimed_by ), '>=', 1, 'at least one capability is described' );
};

# The other direction is the one that catches a stale mirror. It needs to know
# which capabilities core implements itself, and that list is here rather than
# derived because deriving it is the thing being checked - a core capability is
# simply one no extension claims, which would make this assertion vacuous.
my %CORE = map { $_ => 1 } qw(
    ui webdav api mcp
    manage_content write_content manage_nav manage_forms manage_themes manage_layouts
    manage_domains manage_config manage_services manage_users
    analytics audit notifications feedback read_submissions
    delete_submissions approve_accounts
    housekeeping purge audit_switch maintenance_access
    create_sub_users delegate_sub_user_creation
    manage_connectors manage_notifications    # SM1019: core - the notify handler type
    publish_copies);    # SM1354: core - a page copy's publish (Manager::PageCopy)

subtest 'no capability is grantable with nobody implementing it' => sub {
    my @orphan = grep { !$CORE{$_} && !$claimed_by{$_} } sort @Lazysite::Auth::Settings::CAP_KEYS;
    is_deeply( \@orphan, [], 'every @CAP_KEYS entry is core or extension-owned' )
        or diag( join "\n  ", '', @orphan, '',
        'These are grantable in the UI and unlock nothing. To an operator '
            . 'that reads as a broken permission, and there is no error '
            . 'anywhere to lead them to the cause. Either an extension should be '
            . 'declaring it, or the mirror is stale and should be removed.' );
    my @literal_orphan = grep { !$CORE{$_} && !( $claimed_by{$_} && !$described{$_} ) } @core_literal;
    is_deeply( \@literal_orphan, [],
        'and the core literal is what core implements plus the owned-and-undescribed mirrors' );
};

subtest 'the check can actually see something' => sub {
    # A guard that runs before any extension declares a capability would pass
    # every assertion above while proving nothing. SM447's data extension is
    # ADR 0009's exemplar; if it stops declaring, this test has no subject.
    ok( scalar keys %claimed_by,
        'at least one extension declares a capability' )
        or diag( 'With no declarations this test is green and empty - the '
            . 'exact failure mode it exists to catch one layer down.' );
    cmp_ok( scalar @Lazysite::Auth::Settings::CAP_KEYS, '>', scalar @core_literal,
        'and the mirror added to the core literal' );
};

done_testing();

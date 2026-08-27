#!/usr/bin/perl
# SM630: the bootstrap manager group starts with grant authority over every
# capability, so the one CLI command that creates the first administrator is the
# only shell step there ever needs to be.
#
# THE DEFECT WAS THAT GOOD PRACTICE BROKE IT. Grant authority was DERIVED from
# holding: _may_confer returns true if you hold the capability, or if one of
# your groups lists it as `grantable`. The seed set `grantable` to exactly
# ['api','mcp'] - the two channels SM467 knew a manager group would not hold -
# and let holding cover the rest.
#
# That works for an administrator who holds everything for ever. An operator who
# practises least privilege on their OWN account - gives up `purge`, say, while
# still needing to delegate it - loses the authority to confer it the moment
# they give it up. No warning, and no control in the manager that mentions grant
# authority at all. The operator who reported this had done the right thing and
# been penalised for it, then reasonably tried the control that looked relevant
# (Scope ceiling), which governs a different axis entirely.
#
# This adds no power at bootstrap: the group already holds all but the two
# channels, and holding implies conferring. What it does is keep the authority
# when the operator narrows what they hold. Handover is then adding the next
# administrator to that group, from the UI.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Capabilities ();

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "manager_groups: sysops\n";
close $c;

sub users {
    my (@a) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d, @a or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

# Bootstrap exactly as an operator does: one command.
users('setup-sysop', '--user', 'sjm');

my $gs = "$d/lazysite/auth/groups-settings.json";
ok( -f $gs, 'setup-sysop seeded the group settings' ) or do { done_testing(); exit };

require JSON::PP;
my $j = JSON::PP::decode_json( do { open my $fh, '<', $gs or die $!; local $/; <$fh> } );
my $rec = $j->{'sysops'};
ok( $rec, 'the manager group exists' ) or do { done_testing(); exit };

# --- 1. grant authority covers every capability -----------------------------
# `sort Lazysite::Capabilities::capability_keys()` parses as sort SUBNAME LIST -
# Perl takes the function name as the COMPARATOR and sorts an empty list, so the
# expected side was silently empty and the failure read as "the seed is wrong"
# when the seed was right. Same family as the indirect-object trap.
my @keys  = Lazysite::Capabilities::capability_keys();
my @all   = sort @keys;
my @grant = sort @{ $rec->{grantable} || [] };
is_deeply( \@grant, \@all,
    'the first administrator may CONFER every capability, not just the two '
        . 'channels its group does not hold' )
    or diag("missing: @{[ grep { my $c = $_; !grep { $_ eq $c } @grant } @all ]}");

# --- 2. it is authority, not holding ----------------------------------------
# The distinction the whole change rests on. If the seed had simply granted
# everything, the group would HOLD the two remote channels - which SM127
# deliberately refuses, because a manager group is interactive-only.
for my $ch (qw(api mcp)) {
    ok( !$rec->{$ch},
        "the group still does NOT hold '$ch' - manager groups stay "
            . 'interactive-only (SM127)' );
    ok( ( grep { $_ eq $ch } @grant ), "but may confer '$ch'" );
}

# --- 3. the authority SURVIVES giving up the capability ---------------------
# The reported defect, reproduced. Take `purge` away from the group and it must
# still be able to confer it - that is the whole point of grant authority being
# separate from holding.
{
    users( 'group-set', 'sysops', 'purge', 'off' );
    my $after = JSON::PP::decode_json(
        do { open my $fh, '<', $gs or die $!; local $/; <$fh> } );
    my $r = $after->{'sysops'};
    ok( !$r->{purge}, 'the group no longer HOLDS purge' );
    ok( ( grep { $_ eq 'purge' } @{ $r->{grantable} || [] } ),
        'and still has the authority to CONFER it - least privilege on your own '
            . 'account no longer costs you the ability to delegate' );
}

# --- 4. an existing site is not rewritten -----------------------------------
# _ensure_groups_seeded returns early when the settings file exists. A change to
# the seed must not silently widen grant authority on an instance that has
# already made its own decisions.
{
    my $before = do { open my $fh, '<', $gs or die $!; local $/; <$fh> };
    users('groups');
    my $now = do { open my $fh, '<', $gs or die $!; local $/; <$fh> };
    is( $now, $before,
        'a later run does not re-seed, so an existing site keeps the grant '
            . 'authority its operator chose' );
}

done_testing();

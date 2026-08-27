#!/usr/bin/perl
# SM608: a group says whether it shipped with the engine or was made here.
#
# The Groups page listed both in one undifferentiated list. The operator called
# it immaterial and it is worth having anyway, because the two carry DIFFERENT
# RISK on exactly the operations that are hardest to reverse: renaming or
# deleting a shipped group breaks something the engine expects to find, while
# renaming one an operator built breaks only what that operator built.
#
# WRITTEN AT SEED TIME, which is the only moment the answer is known for
# certain. Inferring it later from the name would be a guess, and one that gets
# more wrong as an estate ages and operators name things after the shipped ones.
#
# ABSENT MEANS OPERATOR-MADE, deliberately: every group that predates the marker
# is on an instance somebody had already shaped, and claiming those shipped
# would be the confident wrong answer - the failure this project keeps filing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "manager_groups: lazysite-admins\n";
close $c;
system( $^X, $tool, '--docroot', $d, 'setup-manager' ) == 0
    or plan skip_all => 'setup-manager failed';

require JSON::PP;
my $gs = JSON::PP::decode_json(
    do { open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!; local $/; <$fh> } );

# --- 1. everything the install created is marked ----------------------------
{
    my @unmarked = sort grep { !$gs->{$_}{seeded} } keys %$gs;
    is_deeply( \@unmarked, [],
        'every group a fresh install created is marked as shipped' )
        or diag("unmarked: @unmarked");

    # Including the manager group, which is HEALED rather than seeded - a
    # different code path, and the group whose deletion would break the most.
    ok( $gs->{'lazysite-admins'}{seeded},
        'the manager group is marked too, though it is created by another path' );
}

# --- 2. a group an operator makes is NOT marked -----------------------------
{
    system( $^X, $tool, '--docroot', $d, 'group-set', 'mine-own', 'manage_content', 'on' );
    my $after = JSON::PP::decode_json(
        do { open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!; local $/; <$fh> } );
    ok( exists $after->{'mine-own'}, 'the operator group exists' );
    ok( !$after->{'mine-own'}{seeded},
        'and is NOT marked as shipped - which is the whole distinction' );
}

# --- 3. the flag reaches the page -------------------------------------------
{
    my $api = do { open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!; local $/; <$fh> };
    like( $api, qr/seeded\s*=> \( \$cfg->\{seeded\}/,
        'the groups payload carries the flag' );

    my $page = "$root/starter/manager/groups.md";
    my $p    = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
    like( $p, qr/info\.seeded/, 'the Groups page reads it' );
    like( $p, qr/>system</,     'and marks a shipped group' );
    like( $p, qr/>yours</,      'and an operator-made one' );

    # A TOOLTIP, as the operator asked - it is a fact you want when about to
    # change something, not one to read on every visit.
    like( $p, qr/title="Shipped with the engine[^"]*break/,
        'the shipped badge says what changing it risks' );
    like( $p, qr/title="Created on this instance[^"]*only what was built here/,
        'and the operator badge says the risk is bounded' );
}

done_testing();

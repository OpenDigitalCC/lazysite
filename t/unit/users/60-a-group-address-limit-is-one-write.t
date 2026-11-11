#!/usr/bin/perl
# SM1344: A GROUP'S ADDRESS LIMIT IS SET IN ONE WRITE.
#
# The Groups page's picker moves a profile between Allow and Deny. Sent as two
# settings (addresses_deny, then addresses), a move from Deny to Allow left the
# profile in neither list between the two requests, and a group whose only limit
# that deny was counted from every address for the round-trip - a widening. The
# users tool takes both lists in one group-settings-set (key address_limit),
# validates both, and writes the group store once, under the store lock its
# dispatcher holds across every mutating verb.
#
# What this holds, through the --api door the manager drives:
#   - a Deny -> Allow move is ONE write of groups-settings.json, and the store is
#     never seen with the profile in neither list (every rename of the file is
#     snapshotted by a spy loaded into the tool)
#   - a half-update (one list missing, or a value that is not both) is refused,
#     names what it needs, and changes nothing
#   - a bad name in either list refuses the whole change
#   - it is the operator's, as the single keys are
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";
my $spydir = File::Temp->newdir;
my $snaps  = File::Temp->newdir;

# The spy: every rename onto groups-settings.json leaves a copy of what it put
# there, so the test sees every state the store passed through.
open my $sf, '>', "$spydir/RenameSpy.pm" or die $!;
print {$sf} <<'PERL';
package RenameSpy;
my $n = 0;
BEGIN {
    *CORE::GLOBAL::rename = sub {
        my ( $from, $to ) = @_;
        my $ok = CORE::rename( $from, $to );
        if ( $ok && $to =~ m{/groups-settings\.json\z} && $ENV{RENAME_SPY_DIR} ) {
            if ( open my $in, '<', $to ) {
                local $/;
                my $t = <$in>;
                $n++;
                if ( open my $out, '>', "$ENV{RENAME_SPY_DIR}/$$-$n.json" ) { print {$out} $t }
            }
        }
        return $ok;
    };
}
1;
PERL
close $sf;

sub api {
    my ( $d, $req, %o ) = @_;
    local $ENV{RENAME_SPY_DIR} = $o{spy} ? "$snaps" : '';
    my $out = run_child( [ $^X, "-I$spydir", '-MRenameSpy', $script, '--docroot', $d, '--api' ],
        stdin => encode_json($req), stderr => 'inherit' )->{out} // '';
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

sub canon { return JSON::PP->new->canonical->encode( $_[0] ) }

sub store { my ($d) = @_; open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {}; local $/; decode_json(<$fh>) }

sub snapshots {
    opendir my $dh, "$snaps" or return ();
    my @f = sort grep {/\.json\z/} readdir $dh;
    return map { open my $fh, '<', "$snaps/$_" or die; local $/; decode_json(<$fh>) } @f;
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
run_child( [ $^X, $script, '--docroot', $d, 'setup-sysop', '--user', 'op', 'secretpw1234' ], stderr => 'inherit' );
run_child( [ $^X, $script, '--docroot', $d, 'add', 'carol', 'pw12345678-long-enough' ], stderr => 'inherit' );
api( $d, { action => 'group-create', group => 'g-ed' } );    # n818: the group exists before a limit is set on it
# n812 (ruling 234): a limit names profiles that exist, so the store holds the ones used.
run_child( [ $^X, $script, '--docroot', $d, 'address-profile-set', $_, '--entry', '203.0.113.0/24' ], stderr => 'inherit' ) for qw(office vpn);

my $set = sub { api( $d, { action => 'group-settings-set', group => 'g-ed', key => $_[0], value => $_[1], actor => 'op' }, @_[ 2 .. $#_ ] ) };

subtest 'Deny -> Allow is one write, and the profile is never in neither list' => sub {
    my $r = $set->( 'addresses_deny', 'office' );
    ok( $r->{ok}, 'the group starts limited only by denying office' ) or diag $r->{error};
    ok( !store($d)->{'g-ed'}{addresses}, '...and allows no profile' );
    $r = $set->( 'address_limit', { addresses => ['office'], addresses_deny => [] }, spy => 1 );
    ok( $r->{ok}, 'one request moves office to Allow' ) or diag $r->{error};
    my $g = store($d)->{'g-ed'};
    is_deeply( $g->{addresses}, ['office'], 'the store allows office' );
    ok( !exists $g->{addresses_deny}, '...and denies nothing' );
    my @s = snapshots();
    is( scalar @s, 1, 'the group store was written once' );
    for my $snap (@s) {
        my $sg = $snap->{'g-ed'} || {};
        my $in = grep { $_ eq 'office' } @{ $sg->{addresses} || [] }, @{ $sg->{addresses_deny} || [] };
        ok( $in, 'no state of the store has office in neither list' );
    }
    ok( ref $r->{addresses} eq 'ARRAY' && ref $r->{addresses_deny} eq 'ARRAY', 'the answer carries both lists' );
};

subtest 'a half-update is refused and changes nothing' => sub {
    my $before = canon( store($d) );
    for my $v ( { addresses => ['vpn'] }, { addresses_deny => ['office'] }, 'office', [ 'office' ], undef ) {
        my $r = $set->( 'address_limit', $v );
        ok( !$r->{ok} && ( $r->{field} // '' ) eq 'value', 'refused: ' . ( defined $v ? encode_json( ref $v ? $v : [$v] ) : 'no value' ) );
        like( $r->{error} // '', qr/takes both lists together/, '  saying it takes both lists' );
    }
    my $bad = $set->( 'address_limit', { addresses => ['vpn'], addresses_deny => ['Not A Name'] } );
    ok( !$bad->{ok} && ( $bad->{error} // '' ) =~ /not an address profile name/, 'a bad name in either list refuses the change' );
    is( canon( store($d) ), $before, 'the store is as it was' );
};

subtest 'it is the operator\'s, as the single keys are' => sub {
    my $before = canon( store($d) );
    my $r = api( $d, { action => 'group-settings-set', group => 'g-ed', key => 'address_limit',
            value => { addresses => [], addresses_deny => [] }, actor => 'carol' } );
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'forbidden', 'a non-operator is refused' );
    is( canon( store($d) ), $before, '...and nothing changed' );
    $r = $set->( 'address_limit', { addresses => 'vpn, office', addresses_deny => '' } );
    ok( $r->{ok}, 'comma strings are lists too, and an empty one clears' ) or diag $r->{error};
    is_deeply( store($d)->{'g-ed'}{addresses}, [ 'vpn', 'office' ], '...as written' );
};

done_testing();

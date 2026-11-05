#!/usr/bin/perl
# SM1334 (ruling 78): "only pinning removes the others: home_domain, for an
# account or a group". The account's pin is a domain's locked_users (SM165;
# whoami reports its effect as home_domain, which stopped being a setting of its
# own in 0.7.26). A group could carry no pin. It can now: a domain's
# locked_groups names groups whose members reach ONLY the domains that lock
# them, of the ones they are granted - the account lock, on a group.
#
# And a pin on the primary confines to the primary: before the primary had a row
# (SM1332) no pin could name it, and an empty scope list would leave the member
# unbound - which a signed-in manager reads as every domain.
#
# And losing a group from the request (its address limit, SM1140) can no longer
# lift a pin it carried: the request's scopes are held inside the account's
# whole.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::DomainAccess qw(read_domains effective_scopes effective_home_domain
    DENY_ALL_SCOPE PRIMARY_SCOPE);
use Lazysite::Auth::Settings ();

my $DIR  = tempdir( CLEANUP => 1 );
my $BASE = <<'CONF';
alias_hosts: a.test, b.test
alias.a.test.content_root: sites/a
alias.a.test.allowed_groups: editors
alias.b.test.content_root: sites/b
alias.b.test.allowed_groups: editors, b-only
CONF

sub conf {
    my ($extra) = @_;
    open my $fh, '>', "$DIR/lazysite.conf" or die $!;
    print {$fh} $BASE, ( $extra // '' );
    close $fh;
    return read_domains("$DIR/lazysite.conf");
}
sub scopes { my $d = shift; return [ sort( effective_scopes( $d, @_ ) ) ] }

subtest 'locked_groups is read, on a domain and on the primary row' => sub {
    my $d = conf("alias.a.test.locked_groups: pinned-a\nlocked_groups: pinned-p\n");
    is_deeply( $d->{'a.test'}{locked_groups}, ['pinned-a'], 'a domain' );
    is_deeply( $d->{''}{locked_groups},       ['pinned-p'], 'the primary' );
    is_deeply( $d->{'b.test'}{locked_groups}, [],           'a domain naming none' );
};

subtest 'a group pin removes the other domains' => sub {
    my $d = conf("alias.a.test.locked_groups: pinned-a\n");
    is_deeply( scopes( $d, 'u', ['editors'] ), [ 'sites/a', 'sites/b' ], 'not in the pinned group: both, as before' );
    is_deeply( scopes( $d, 'u', [ 'editors', 'pinned-a' ] ), ['sites/a'], 'in it: a.test only' );
    is( effective_home_domain( $d, 'u', [ 'editors', 'pinned-a' ] ), 'a.test', '...its one home' );
    is_deeply( scopes( $d, 'u', [ 'b-only', 'pinned-a' ] ), [DENY_ALL_SCOPE],
        'pinned to a domain it is not granted: nothing, never unbound' );
};

subtest 'the account pin and the group pin are one lock' => sub {
    my $d = conf("alias.a.test.locked_groups: pinned-a\nalias.b.test.locked_users: u\n");
    is_deeply( scopes( $d, 'u', [ 'editors', 'pinned-a' ] ), [ 'sites/a', 'sites/b' ],
        'locked to a by its group and to b by name: both, nothing else' );
};

subtest 'a pin on the primary confines to the primary' => sub {
    my $d = conf("locked_groups: staff\n");
    is_deeply( scopes( $d, 'u', [ 'editors', 'staff' ] ), [PRIMARY_SCOPE], 'a group pin there: the primary only' );
    is( effective_home_domain( $d, 'u', [ 'editors', 'staff' ] ), '', 'no secondary home' );
    is_deeply( scopes( $d, 'u', ['staff'] ), [PRIMARY_SCOPE], 'granted nothing, pinned there: still confined there' );
    $d = conf("allowed_groups: editors\nlocked_groups: staff\n");
    is_deeply( scopes( $d, 'u', [ 'b-only', 'staff' ] ), [DENY_ALL_SCOPE],
        'pinned to a primary whose row names other groups, and granted b: nothing' );
};

# _scopes_whole_and_request with an address limit in force: the pinning group is
# left out of the request's walk, as an address rule leaves it out.
subtest 'a group left out of the request cannot lift its pin' => sub {
    conf("alias.a.test.locked_groups: pinned-a\n");
    my $d = read_domains("$DIR/lazysite.conf");
    no warnings qw(redefine once);
    local *Lazysite::Auth::Settings::_address_blocked_groups = sub { return { 'pinned-a' => 1 } };
    local *Lazysite::Auth::Settings::read_group_settings     = sub { return {} };
    local *Lazysite::Auth::Settings::_effective_groups = sub {
        return $Lazysite::Auth::Settings::ADDRESS_RULES // 1 ? ('editors') : ( 'editors', 'pinned-a' );
    };
    my ( $whole, $req ) = Lazysite::Auth::Settings::_scopes_whole_and_request( $d, 'u' );
    is_deeply( [ sort @$whole ], ['sites/a'], 'the whole: pinned to a' );
    is_deeply( [ sort @$req ], ['sites/a'], 'the request, without the pinning group: still a only, never b' );
};

done_testing();

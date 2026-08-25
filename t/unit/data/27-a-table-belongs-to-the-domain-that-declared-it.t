#!/usr/bin/perl
# SM593: `manage_data` is an INSTANCE capability and a table's ACL path carries
# no domain component, so on an instance hosting several unrelated parties one
# client's grant reached every other client's tables - and the table NAMES are
# their own disclosure, which is why an unpublished table is invisible to a
# visitor in the first place.
#
# THE MIGRATION CASE IS TESTED AS HARD AS THE FIX. A table that names no domain
# must behave exactly as it did before this existed, because instances carrying
# live tables and live users upgrade into this release and nothing may be taken
# out from under a running application. An unscoped table is therefore reachable
# by everyone, and becomes confined only when somebody writes `domain:` on it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                 ();
use Lazysite::Manager::Data    qw(action_data_tables action_data_table);
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Domains ();

BEGIN {
    unless ( eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ) {
        require Test::More;
        Test::More::plan( skip_all => 'DBI / DBD::SQLite / YAML::PP not available' );
    }
}

my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/db/tables", "$d/lazysite/auth",
    "$d/sites/alpha", "$d/sites/beta" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} <<"CONF";
site_name: T
plugins:
  - plugins/data.pl
alias_hosts: alpha.test, beta.test
alias.alpha.test.content_root: sites/alpha
alias.beta.test.content_root: sites/beta
CONF
close $cf;

$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;
$Lazysite::Manager::Data::DOCROOT    = $d;

sub declare {
    my ( $name, $domain ) = @_;
    open my $fh, '>', "$d/lazysite/db/tables/$name.yaml" or die $!;
    print {$fh} "title: $name\n"
        . ( $domain ? "domain: $domain\n" : '' )
        . "key: slug\nfields:\n  slug:\n    type: text\n";
    close $fh;
}

declare( 'alpha_orders', 'alpha.test' );
declare( 'beta_orders',  'beta.test' );
declare( 'legacy_stock', undef );          # predates the key - the live case

sub as_scoped {
    my ( $scopes, $code ) = @_;
    local @Lazysite::Manager::Data::CALLER_SCOPES = @{$scopes};
    return $code->();
}
sub names_for {
    my ($scopes) = @_;
    my $r = as_scoped( $scopes, sub { action_data_tables() } );
    return [ sort map { $_->{table} } @{ $r->{tables} || [] } ];
}

# --- the derivation itself -------------------------------------------------
is_deeply( [ Lazysite::Manager::Domains::domains_for_scopes() ], [],
    'no scopes is UNCONFINED - an empty answer, never a narrow one' );
is_deeply( [ Lazysite::Manager::Domains::domains_for_scopes('sites/alpha') ],
    ['alpha.test'], 'a scope AT a content root names that domain' );
is_deeply( [ Lazysite::Manager::Domains::domains_for_scopes('sites/alpha/inner') ],
    ['alpha.test'], 'a scope INSIDE a content root names the domain containing it' );
is_deeply( [ Lazysite::Manager::Domains::domains_for_scopes('sites') ],
    [ 'alpha.test', 'beta.test' ],
    'a scope ABOVE several reaches all of them' );

# --- the listing -----------------------------------------------------------
is_deeply( names_for( [] ),
    [qw(alpha_orders beta_orders legacy_stock)],
    'an unconfined caller - the operator - still sees every table' );

is_deeply( names_for( ['sites/alpha'] ),
    [qw(alpha_orders legacy_stock)],
    'a caller scoped to alpha is not told that beta_orders exists' );

is_deeply( names_for( ['sites/beta'] ),
    [qw(beta_orders legacy_stock)],
    'and the same holds in the other direction' );

# --- reaching one by name --------------------------------------------------
my $mine = as_scoped( ['sites/alpha'], sub { action_data_table('alpha_orders') } );
ok( $mine->{ok}, 'a caller reaches its OWN domain table by name' );

my $theirs = as_scoped( ['sites/alpha'], sub { action_data_table('beta_orders') } );
ok( !$theirs->{ok}, "a caller cannot reach another domain's table by name" );

# The refusal must not be a better answer than the one a made-up name gets, or
# a partner could enumerate the instance one guess at a time.
my $absent = as_scoped( ['sites/alpha'], sub { action_data_table('no_such_thing') } );
is( $theirs->{error}, "no table 'beta_orders' is declared",
    "the refusal is the wording a missing table gets" );
is( $theirs->{kind}, $absent->{kind},
    'and the same kind, so the two cases are indistinguishable' );
is_deeply( [ sort keys %$theirs ], [ sort keys %$absent ],
    'the two replies carry the same keys - nothing leaks in the shape either' );

# --- the migration case ----------------------------------------------------
# This is the assertion that says a live instance does not break on upgrade.
for my $scope ( 'sites/alpha', 'sites/beta' ) {
    my $legacy = as_scoped( [$scope], sub { action_data_table('legacy_stock') } );
    ok( $legacy->{ok},
        "a table naming no domain is still reachable from $scope - "
            . 'an upgrade takes nothing away from a running application' );
}

# --- the migration list -----------------------------------------------------
# The docs tell an operator that lazysite-check names the tables still to
# scope, so that has to be true. This is also the only part of SM593 an
# operator sees before they have a partner to be confined from.
{
    my $check = TestHelper::repo_root() . '/tools/lazysite-check.pl';
SKIP: {
        skip 'no check tool', 6 unless -f $check;
        # SEVERAL DOMAINS IS NOT SEVERAL PARTIES. Confinement comes from a
        # domain naming a group in allowed_groups (SM165), and every scope is
        # derived from that - so where no domain names one, nobody is confined
        # and an unscoped table is the operator's own. The fixture above has
        # two domains and no allowed_groups, which is exactly that case.
        my $quiet = TestHelper::run_cmd( $^X, $check, '--docroot', $d );
        unlike( $quiet, qr/name no domain on a/,
            'a multi-domain instance that confines nobody is not warned at all' );
        like( $quiet, qr/no domain confines a group/,
            'it is told the namespace is its own instead' );

        # Add the confinement and the same tree becomes a finding - which is
        # also where the migration list has to be right.
        open my $ac, '>>', "$d/lazysite/lazysite.conf" or die $!;
        print {$ac} "alias.alpha.test.allowed_groups: client-a\n";
        close $ac;
        my $out = TestHelper::run_cmd( $^X, $check, '--docroot', $d );
        like( $out, qr/legacy_stock/,
            'once a domain confines a group, the unscoped table IS a finding' );
        unlike( $out, qr/data table.*\balpha_orders\b/,
            'and the ones that name a domain are not listed' );

        # On a single-domain instance the key would be noise: the exposure
        # needs a second party before it is an exposure.
        my $solo = Cwd::realpath( tempdir( CLEANUP => 1 ) );
        make_path("$solo/lazysite/db/tables");
        open my $sc, '>', "$solo/lazysite/lazysite.conf" or die $!;
        print {$sc} "site_name: Solo\n";
        close $sc;
        open my $tf, '>', "$solo/lazysite/db/tables/only.yaml" or die $!;
        print {$tf} "title: only\nkey: slug\nfields:\n  slug:\n    type: text\n";
        close $tf;
        unlike( TestHelper::run_cmd( $^X, $check, '--docroot', $solo ),
            qr/name no domain/,
            'a single-domain instance is not nagged about a namespace it has to itself' );
    }
}

done_testing();

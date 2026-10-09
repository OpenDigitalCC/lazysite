#!/usr/bin/perl
# SM976 R4 (ruled 2026-10-09, "Use the shared rule"): the data surface answers
# "may this caller reach this table's domain?" with
# Lazysite::Manager::Common::caller_may_reach_domain, like every other action.
#
# It kept a rule of its own (SM593/SM648, Manager::Data _caller_domains): a
# grant reached a domain's tables when its scope and the domain's content root
# overlapped IN EITHER DIRECTION, and a domain with no content root of its own
# was nobody's. And some of its verbs asked nothing at all: the table access
# rule (data-table-acl-get/-set/-remove) and the safety exports (listing, read,
# restore, delete) answered a confined caller for every domain's tables. Each
# case where the answer changed, narrowed or widened, is a subtest here; the
# probe was tmp/q15c-probe.pl (before and after in tmp/q15c-probe.*.out).
#
# R2 (an unbound cookie manager is unconfined) is decided where the control API
# sets $CALLER_CONFINED, so it is held through the API in t/integration/115.
#
# The instance: alpha.test at sites/alpha, blog.test at sites/alpha/blog,
# beta.test at sites/beta, mirror.test with no content root (it serves the
# primary's content).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper ();

BEGIN {
    unless ( eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ) {
        require Test::More;
        Test::More::plan( skip_all => 'DBI / DBD::SQLite / YAML::PP not available' );
    }
}
use Lazysite::Manager::Data qw(action_data_table action_data_table_save action_table_acl_get
    action_table_acl_set action_table_acl_remove action_data_safety_exports
    action_data_safety_export_read action_data_safety_export_restore
    action_data_safety_export_delete);
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Files   ();
use Lazysite::Auth::Acl        ();

my $d = Cwd::realpath( TestHelper::site_tempdir( plugins => 1 ) );
make_path( "$d/lazysite/db/tables", "$d/lazysite/db/rebuilds", "$d/lazysite/auth",
    map { "$d/sites/$_" } qw(alpha alpha/blog beta) );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n"
    . "alias_hosts: alpha.test, blog.test, beta.test, mirror.test\n"
    . "alias.alpha.test.content_root: sites/alpha\nalias.blog.test.content_root: sites/alpha/blog\n"
    . "alias.beta.test.content_root: sites/beta\n";
close $cf;
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;
$Lazysite::Manager::Data::DOCROOT    = $d;
$Lazysite::Manager::Files::DOCROOT   = $d;
$Lazysite::Auth::Acl::DOCROOT        = $d;

sub desc { my ($dom) = @_; return "title: t\n" . ( $dom ? "domain: $dom\n" : '' ) . "key: slug\nfields:\n  slug:\n    type: text\n" }
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
my %TABLE = ( t_alpha => 'alpha.test', t_blog => 'blog.test', t_beta => 'beta.test',
    t_mirror => 'mirror.test', t_free => undef );
for my $t ( sort keys %TABLE ) {
    spit( "$d/lazysite/db/tables/$t.yaml", desc( $TABLE{$t} ) );
    spit( "$d/lazysite/db/rebuilds/$t-20260101T000000Z.json",
        encode_json( { lazysite_data => 1, table => $t, key => 'slug',
                fields => { slug => { type => 'text' } }, rows => [ { slug => 'kept' } ] } ) );
}
sub export_of { return "$_[0]-20260101T000000Z.json" }

# A caller as the surface establishes it: the resolved scopes, and whether
# they were resolved at all.
sub reaches {
    my ( $confined, $scopes, $t ) = @_;
    local @Lazysite::Manager::Data::CALLER_SCOPES   = @{$scopes};
    local $Lazysite::Manager::Data::CALLER_CONFINED = $confined;
    return action_data_table($t)->{ok} ? 1 : 0;
}
sub tables_seen {
    my ( $confined, $scopes ) = @_;
    local @Lazysite::Manager::Data::CALLER_SCOPES   = @{$scopes};
    local $Lazysite::Manager::Data::CALLER_CONFINED = $confined;
    my $r = action_data_safety_exports();
    return join ',', sort map { $_->{table} } @{ $r->{exports} || [] };
}

subtest 'NARROWS: a scope inside a domain reaches that domain, not the one around it' => sub {
    # Before: sites/alpha/blog overlapped alpha's root (sites/alpha) "in either
    # direction", so a grant on blog.test reached alpha.test's tables.
    ok( !reaches( 1, ['sites/alpha/blog'], 't_alpha' ), 'blog.test\'s grant: not alpha.test\'s table' );
    ok( reaches( 1, ['sites/alpha/blog'], 't_blog' ), '...its own' );
    ok( reaches( 1, ['sites/alpha/blog'], 't_free' ), '...and a table naming no domain, as always' );
};

subtest 'UNCHANGED: a scope reaches the domains whose root lies inside it' => sub {
    ok( reaches( 1,  ['sites/alpha'], 't_alpha' ), 'alpha.test\'s grant: its own table' );
    ok( reaches( 1,  ['sites/alpha'], 't_blog' ),  '...and the domain inside it' );
    ok( !reaches( 1, ['sites/alpha'], 't_beta' ),  '...not beta.test' );
    ok( !reaches( 1, ['sites/alpha'], 't_mirror' ), '...not a domain serving the primary\'s content' );
};

subtest 'WIDENS: an unbound grant reaches a domain serving the primary\'s content (R3)' => sub {
    # Before: a domain with no root of its own was skipped, so its tables were
    # nobody's but the operator's. The shared rule gives it to whoever reaches
    # the primary - an unbound grant - and to no scoped one.
    ok( reaches( 1,  [], 't_mirror' ), 'an unbound grant: mirror.test\'s table' );
    ok( !reaches( 1, [], 't_alpha' ),  '...still no domain with a root of its own' );
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ();
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    ok( action_data_table_save( 'fresh_m', desc('mirror.test') )->{ok}, '...and binds a new table to it' );
    ok( !action_data_table_save( 'fresh_a', desc('alpha.test') )->{ok}, '...but not to alpha.test' );
};

subtest 'UNCHANGED: the unconfined caller (CLI, render path, operator) reaches every table' => sub {
    ok( reaches( 0, [], $_ ), $_ ) for sort keys %TABLE;
};

subtest 'NARROWS: a table\'s access rule is that table\'s' => sub {
    # Before: the three verbs asked no reach, so a grant confined to alpha.test
    # read, set and cleared the read rule of beta.test's table.
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ('sites/alpha');
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    for my $t (qw(t_beta t_mirror)) {
        my $set = action_table_acl_set( $t, 'alice', read => ['bob'] );
        ok( !$set->{ok}, "set on $t refused" );
        is( $set->{kind}, 'no_such_table', '...as a table that is not there' );
        is( action_table_acl_get( $t, 'alice' )->{kind}, 'no_such_table', "get on $t refused" );
        is( action_table_acl_remove( $t, 'alice' )->{kind}, 'no_such_table', "remove on $t refused" );
    }
    ok( action_table_acl_set( 't_alpha', 'alice', read => ['bob'] )->{ok}, 'its own table\'s rule is still its to set' );
    ok( action_table_acl_get( 't_alpha', 'alice' )->{ok}, '...and read' );
};

subtest 'NARROWS: a safety export is its table\'s' => sub {
    # Before: every confined caller listed, read, restored and deleted every
    # domain's exports.
    is( tables_seen( 1, ['sites/alpha'] ), 't_alpha,t_blog,t_free', 'alpha.test\'s grant lists its own' );
    is( tables_seen( 1, [] ), 't_free,t_mirror', 'an unbound grant lists the primary\'s' );
    is( tables_seen( 0, [] ), 't_alpha,t_beta,t_blog,t_free,t_mirror', 'the unconfined caller lists all' );
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ('sites/alpha');
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    for my $verb ( [ read => \&action_data_safety_export_read ], [ restore => \&action_data_safety_export_restore ],
        [ delete => \&action_data_safety_export_delete ] )
    {
        my $r = $verb->[1]->( export_of('t_beta') );
        ok( !$r->{ok}, "$verb->[0] of beta.test's export refused" );
        is( $r->{error}, 'no such safety export', '...as one that does not exist' );
    }
    ok( -f "$d/lazysite/db/rebuilds/" . export_of('t_beta'), 'beta.test\'s export is still there' );
    ok( action_data_safety_export_read( export_of('t_alpha') )->{ok}, 'its own export still reads' );
};

done_testing();

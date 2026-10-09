#!/usr/bin/perl
# SM976: a caller confined to its own domains binds a data table only to one of
# them.
#
# data-table-save checked that a descriptor's `domain:` names a domain the
# instance serves, and not whose it is. A grant scoped to alpha created a table
# bound to beta and re-bound its own table to beta: a write into another
# domain's data. The probe was tmp/q15b-data-probe.pl. The unconfined caller
# (the CLI, the render path, the operator) still binds a table to any domain.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                 ();
use Lazysite::Manager::Data    qw(action_data_table_save);
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Domains ();

BEGIN {
    unless ( eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ) {
        require Test::More;
        Test::More::plan( skip_all => 'DBI / DBD::SQLite / YAML::PP not available' );
    }
}

my $d = Cwd::realpath( TestHelper::site_tempdir( plugins => 1 ) );
make_path( "$d/lazysite/db/tables", "$d/lazysite/auth", "$d/sites/alpha", "$d/sites/beta" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\nalias_hosts: alpha.test, beta.test\n"
    . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n";
close $cf;
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;
$Lazysite::Manager::Data::DOCROOT    = $d;

sub desc {
    my ($dom) = @_;
    return "title: t\n" . ( $dom ? "domain: $dom\n" : '' ) . "key: slug\nfields:\n  slug:\n    type: text\n";
}
sub declare { open my $fh, '>', "$d/lazysite/db/tables/$_[0].yaml" or die $!; print {$fh} desc( $_[1] ); close $fh; return }
sub bound_to {
    open my $fh, '<', "$d/lazysite/db/tables/$_[0].yaml" or return undef;
    local $/;
    my $t = <$fh>;
    return $t =~ /^domain:\s*(\S+)/m ? $1 : '';
}
sub fresh { declare( 'alpha_orders', 'alpha.test' ); unlink "$d/lazysite/db/tables/fresh.yaml"; return }

subtest 'a grant scoped to alpha' => sub {
    fresh();
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ('sites/alpha');
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    my $r = action_data_table_save( 'fresh', desc('beta.test') );
    ok( !$r->{ok}, 'cannot create a table bound to beta' );
    is( $r->{kind}, 'forbidden', '...as forbidden' );
    like( $r->{error}, qr/not one of yours.*alpha\.test/, '...naming the domains it may use' );
    ok( !defined bound_to('fresh'), '...and nothing was written' );

    ok( !action_data_table_save( 'alpha_orders', desc('beta.test') )->{ok}, 'cannot re-bind its own table to beta' );
    is( bound_to('alpha_orders'), 'alpha.test', '...which stays on alpha' );

    ok( action_data_table_save( 'alpha_orders', desc('alpha.test') )->{ok}, 'still saves its own table on alpha' );
    ok( action_data_table_save( 'fresh', desc('alpha.test') )->{ok}, 'and creates one bound to alpha' );
};

subtest 'a confined grant naming no scope binds a table to no domain' => sub {
    fresh();
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ();
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    ok( !action_data_table_save( 'fresh', desc('alpha.test') )->{ok}, 'refused' );
    ok( action_data_table_save( 'fresh', desc(undef) )->{ok}, 'an instance-wide table is still its to declare' );
};

subtest 'the unconfined caller binds a table to any domain' => sub {
    fresh();
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ();
    local $Lazysite::Manager::Data::CALLER_CONFINED = 0;
    ok( action_data_table_save( 'fresh', desc('beta.test') )->{ok}, 'beta' );
    ok( action_data_table_save( 'alpha_orders', desc('beta.test') )->{ok}, 'and moves a table between domains' );
};

done_testing();

#!/usr/bin/perl
# SM976 F3 (ruled 2026-10-09, "Record domain"): a safety export carries its
# table's domain, and is confined as the table was.
#
# A dropped table leaves no descriptor, so the export verbs (R4) reached its
# export as they reach a table naming no domain - everyone's. The export now
# records the table's `domain` when the drop writes it ('' for a table naming
# none), and a confined caller reaches it only as it reached the table. An
# export written before this records nothing and is the primary's
# (t/unit/data/67).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use JSON::PP   ();
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
use Lazysite::Data::Tables  ();
use Lazysite::Manager::Data qw(action_data_safety_exports action_data_safety_export_read);
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Domains ();

my $d = Cwd::realpath( TestHelper::site_tempdir( plugins => 1 ) );
make_path( "$d/lazysite/db/tables", "$d/lazysite/auth", "$d/sites/alpha", "$d/sites/beta" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\nalias_hosts: alpha.test, beta.test\n"
    . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n";
close $cf;
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;
$Lazysite::Manager::Data::DOCROOT    = $d;

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
my %TABLE = ( t_alpha => 'alpha.test', t_beta => 'beta.test', t_free => '' );
my %file;
for my $t ( sort keys %TABLE ) {
    spit( "$d/lazysite/db/tables/$t.yaml", "title: t\n" . ( length $TABLE{$t} ? "domain: $TABLE{$t}\n" : '' )
            . "key: slug\nfields:\n  slug:\n    type: text\n" );
    ok( Lazysite::Data::Tables::apply_schema( $d, $t )->{ok}, "set up: $t created" );
    my $r = Lazysite::Data::Tables::drop_table( $d, $t, confirm => $t );
    ok( $r->{ok}, "$t dropped" ) or diag( $r->{error} );
    my ($f) = grep { /\A\Q$t\E-dropped-/ } do { opendir my $dh, "$d/lazysite/db/rebuilds" or die $!; readdir $dh };
    ok( defined $f, "...leaving its safety export" );
    $file{$t} = $f;
    ok( !-f "$d/lazysite/db/tables/$t.yaml", '...and no descriptor' );
}

subtest 'the export records its table\'s domain' => sub {
    for my $t ( sort keys %TABLE ) {
        open my $fh, '<', "$d/lazysite/db/rebuilds/$file{$t}" or die $!;
        my $data = JSON::PP->new->decode( do { local $/; <$fh> } );
        ok( exists $data->{domain}, "$t: the export has a domain" );
        is( $data->{domain}, $TABLE{$t}, "$t: '$TABLE{$t}'" );
    }
};

subtest 'and is reached as the table was' => sub {
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ('sites/alpha');
    local $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    is( join( ',', sort map { $_->{table} } @{ action_data_safety_exports()->{exports} || [] } ), 't_alpha,t_free',
        'alpha.test\'s grant lists its own dropped table\'s export and the one naming no domain' );
    ok( action_data_safety_export_read( $file{t_alpha} )->{ok}, '...reads its own' );
    is( action_data_safety_export_read( $file{t_beta} )->{error}, 'no such safety export',
        '...and not beta.test\'s, which before F3 was everyone\'s once the table was gone' );
};

subtest 'the unconfined caller reaches every export' => sub {
    local @Lazysite::Manager::Data::CALLER_SCOPES   = ();
    local $Lazysite::Manager::Data::CALLER_CONFINED = 0;
    is( join( ',', sort map { $_->{table} } @{ action_data_safety_exports()->{exports} || [] } ), 't_alpha,t_beta,t_free',
        'all three' );
};

done_testing();

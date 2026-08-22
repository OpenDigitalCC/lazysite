#!/usr/bin/perl
# SM472: an unmet dependency is a diagnosis, not a 500.
#
# REPORTED FROM EDGE, and the report is why this test exists in this shape.
# The field bisected it properly - brief descriptor with the table in body and
# query, body only, query only, a two-line minimal descriptor, deliberately
# malformed YAML, all 500 - and still could not see the cause, because nothing
# anywhere said the word "YAML::PP".
#
# EVERY SIGNAL WAS HONEST AND POINTED NOWHERE:
#   list_data_tables succeeded - it globs filenames and, with no tables
#     declared, never reaches the parser at all
#   a call with no descriptor answered properly - the parameter check runs
#     before the require
#   everything else was an HTML 500 - a die in a CGI
#
# Three consistent answers that together said "writes are broken" when the
# truth was "one package is missing". The dependency IS declared - in
# sbom-deps.json, in the deb, in the plugin's `owns` - so this is not about
# whether it should be there. It is about the host where it is not, and 500 is
# the one answer nobody can act on.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

# Hide ONE module from require, leaving everything else alone. Done in BEGIN so
# it is in place before the data modules load.
our %HIDDEN;
BEGIN {
    unshift @INC, sub {
        my ( undef, $file ) = @_;
        die "Can't locate $file in \@INC (hidden by the test)\n"
            if $HIDDEN{$file};
        return;
    };
}

use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Data ();
use Lazysite::Data::Tables  ();
use Lazysite::Data::Connect ();

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/db/tables");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
    close $c;
    return $d;
}

subtest 'saving a descriptor without YAML::PP names the module' => sub {
    my $d = site();
    local $Lazysite::Manager::Data::DOCROOT = $d;
    local %HIDDEN = ( 'YAML/PP.pm' => 1 );
    delete $INC{'YAML/PP.pm'};

    my $r = eval {
        Lazysite::Manager::Data::action_data_table_save( 'tiny',
            "title: Tiny\nfields:\n  name:\n    type: text\n" );
    };
    ok( defined $r, 'it returns rather than dying' )
        or diag( "it died: $@\nA die in a CGI is an HTTP 500 with an HTML "
            . 'body, which is what the field met.' );
    ok( !$r->{ok}, 'and reports a failure' );
    is( $r->{kind}, 'missing_module', 'of a kind a surface can branch on' );
    like( $r->{error}, qr/YAML::PP/, 'NAMING the module' )
        or diag( 'Without the name, three honest signals still add up to '
            . '"writes are broken" rather than "one package is missing".' );
    like( $r->{error}, qr/libyaml-pp-perl/, 'and the package that provides it' );
};

subtest 'reading a descriptor without YAML::PP says the same thing' => sub {
    my $d = site();
    open my $f, '>', "$d/lazysite/db/tables/items.yaml" or die $!;
    print {$f} "key: code\nfields:\n  code:\n    type: text\n";
    close $f;

    local %HIDDEN = ( 'YAML/PP.pm' => 1 );
    delete $INC{'YAML/PP.pm'};
    my $r = eval { Lazysite::Data::Tables::load_table( $d, 'items' ) };
    ok( defined $r, 'load_table returns rather than dying' )
        or diag( "it died: $@\nThe render path calls this, so a die here is a "
            . 'VISITOR-facing 500 on a page whose only fault is a missing '
            . 'package.' );
    is( $r->{kind}, 'missing_module', 'reporting the cause' );
};

subtest 'the store diagnosis leads with the module' => sub {
    my $d = site();
    local %HIDDEN = ( 'DBD/SQLite.pm' => 1 );
    delete $INC{'DBD/SQLite.pm'};

    my $why = Lazysite::Data::Connect::store_diagnosis($d);
    is( $why->{reason}, 'missing_module', 'the module is checked FIRST' )
        or diag( 'It explains every other symptom at once, so reporting "no '
            . 'store yet" instead would send an operator to create something '
            . 'that would not have worked anyway.' );
    like( $why->{detail}, qr/DBD::SQLite/, 'naming it' );
    like( $why->{detail}, qr/libdbd-sqlite\b|libdbd-sqlite-perl/,
        'and a package to install' );
};

subtest 'with the modules present, nothing changes' => sub {
    # The guard must not become the answer. A check that fires when the module
    # IS there would be worse than the die it replaced.
    plan skip_all => 'YAML::PP not available here'
        unless eval { require YAML::PP; 1 };
    my $d = site();
    local $Lazysite::Manager::Data::DOCROOT = $d;
    my $r = Lazysite::Manager::Data::action_data_table_save( 'tiny',
        "title: Tiny\nfields:\n  name:\n    type: text\n" );
    ok( $r->{ok}, 'a descriptor still saves' ) or diag( $r->{error} );
};

done_testing();

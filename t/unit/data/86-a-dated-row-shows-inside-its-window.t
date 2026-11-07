#!/usr/bin/perl
# SM1356: ANY DATA ROW MAY CARRY shows_from AND shows_until. A row outside its
# window is not shown - by a page binding or the data endpoint, both of which are
# Tables::resolve_binding - with no update needed, and the binding says when the
# next row enters or leaves it, so a page carrying the table expires then.
#
#   * a date is a whole day in the site's zone: shown from the start of
#     shows_from, through the end of shows_until;
#   * a datetime is an instant (UTC): shown from it, until it;
#   * an empty bound is no bound;
#   * the list, its _total and .count agree - a hidden row is neither shown nor
#     counted;
#   * the manage_data surfaces (read_rows as the operator) see every row, which
#     is how an editor finds the one that has not started yet;
#   * any other type for shows_from is refused at the descriptor.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Time::Local qw(timegm);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Schedule   ();
use Lazysite::Data::Tables     qw(apply_schema insert_row read_rows resolve_binding);

plan skip_all => 'the host has no zoneinfo for Europe/London'
    unless Lazysite::Data::Schedule::valid_zone('Europe/London');

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub at { my ( $y, $mo, $d, $h, $mi ) = @_; return timegm( 0, $mi, $h, $d, $mo - 1, $y ) }

my $docroot = site_tempdir();
setup_test_site($docroot);
make_path("$docroot/lazysite/db/tables");
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "time_zone: Europe/London\n";
close $cf;

spit( "$docroot/lazysite/db/tables/offers.yaml",
    "title: Offers\npublic: true\nfields:\n  name:\n    type: text\n"
        . "  shows_from:\n    type: date\n  shows_until:\n    type: date\n" );
spit( "$docroot/lazysite/db/tables/notices.yaml",
    "title: Notices\npublic: true\nfields:\n  name:\n    type: text\n"
        . "  shows_from:\n    type: datetime\n  shows_until:\n    type: datetime\n" );
apply_schema( $docroot, $_ ) for qw(offers notices);

insert_row( $docroot, 'offers', { name => 'ALWAYS' } );
insert_row( $docroot, 'offers', { name => 'PAST',    shows_until => '2026-06-30' } );
insert_row( $docroot, 'offers', { name => 'CURRENT', shows_from  => '2026-07-01', shows_until => '2026-07-10' } );
insert_row( $docroot, 'offers', { name => 'FUTURE',  shows_from  => '2026-07-20' } );
insert_row( $docroot, 'notices', { name => 'NOW-ON', shows_from => '2026-07-05 08:00:00', shows_until => '2026-07-05 18:00:00' } );

my $anon = { user => '', groups => [] };
sub names { my ($r) = @_; return join ',', sort map { $_->{name} } @{ $r->{rows} || [] } }

{
    no warnings 'once';
    # 10 July 2026, 22:30 UTC = 23:30 BST: still the 10th in London.
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 10, 22, 30 );
    my $r = resolve_binding( $docroot, 'offers', $anon );
    is( names($r), 'ALWAYS,CURRENT', 'only the rows inside their window are shown' );
    is( $r->{total}, 2, 'the total counts what is shown' );
    is( resolve_binding( $docroot, 'offers.count()', $anon )->{value}, 2, 'and so does .count' );
    is( $r->{expires}, at( 2026, 7, 10, 23, 0 ),
        'the binding expires at local midnight, when CURRENT\'s last day ends' );

    my $all = read_rows( $docroot, 'offers', as => 'operator' );
    is( names($all), 'ALWAYS,CURRENT,FUTURE,PAST', 'the operator\'s listing sees every row' );
}
{
    no warnings 'once';
    # 10 July, 23:30 UTC = 00:30 BST on the 11th: CURRENT has ended in London.
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 10, 23, 30 );
    my $r = resolve_binding( $docroot, 'offers', $anon );
    is( names($r), 'ALWAYS', 'a date is a day in the site\'s zone, not in UTC' );
    is( $r->{expires}, at( 2026, 7, 19, 23, 0 ), 'and the next change is FUTURE starting at its local midnight' );
}
{
    no warnings 'once';
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 20, 0, 0 );
    is( names( resolve_binding( $docroot, 'offers', $anon ) ), 'ALWAYS,FUTURE', 'a row starts showing on its day' );
}
{
    no warnings 'once';
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 5, 7, 59 );
    my $r = resolve_binding( $docroot, 'notices', $anon );
    is( names($r), '', 'a datetime window has not opened a minute before it' );
    is( $r->{expires}, at( 2026, 7, 5, 8, 0 ), 'and the binding expires as it does' );
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 5, 8, 0 );
    $r = resolve_binding( $docroot, 'notices', $anon );
    is( names($r), 'NOW-ON', 'from the instant, it shows' );
    is( $r->{expires}, at( 2026, 7, 5, 18, 0 ), 'until the instant it ends' );
    local $Lazysite::Data::Tables::NOW = at( 2026, 7, 5, 18, 0 );
    is( names( resolve_binding( $docroot, 'notices', $anon ) ), '', 'and at that instant it does not' );
}

my $plain = resolve_binding( $docroot, 'offers', $anon );
ok( exists $plain->{expires}, 'a binding on a dated table always says when it next changes (or that nothing will)' );

my $bad = load_descriptor( 'x', { fields => { shows_from => { type => 'text' } } } );
ok( !$bad->{ok}, 'shows_from of any type but date or datetime is refused' );
like( $bad->{error}, qr/shows_from must be a date or a datetime/, 'by name' );
my $undated = load_descriptor( 'x', { fields => { a => { type => 'text' } } } );
ok( !exists $undated->{shows}, 'a table without them is not dated' );

done_testing();

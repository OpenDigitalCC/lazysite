#!/usr/bin/perl
# n776 (SM1356 with SM1355): THE SCHEDULE'S WIZARD BUILDS AN EXCEPTION ROW.
#
# n773 filed a wizard for a `schedule: true` table, left for the restack because
# n772's wizard format was not on its base. It ships in /docs/data-tables (the
# Schedules section), to be saved over a site's own schedule table. This test
# reads the definition OUT OF THAT PAGE, so the docs and the test are one text:
#
#   * it is a valid wizard over a schedule table (checked against the table);
#   * an exception - a date range with other hours - is built one question at a
#     time, written, and read back as the schedule's exception;
#   * a closed day skips the times and is written closed;
#   * a weekly period asks its day and times and none of an exception's;
#   * the date step takes YYYY-MM-DD and refuses anything else, by name.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir repo_root);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);
use Lazysite::Data::Wizard ();
use Lazysite::Data::Schedule ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# The definition, as the docs page gives it: the YAML block after the sentence
# that names the wizard opening_hours.
my $page = do {
    my $f = repo_root() . '/starter/lazysite/templates/docs/data-tables.md';
    open my $fh, '<', $f or die "$f: $!";
    local $/;
    <$fh>;
};
my ($def) = $page =~ /saved as `opening_hours` over the table.*?```yaml\n(.*?)```/s;
ok( defined $def && $def =~ /\Atitle: /, 'the docs give the schedule wizard' ) or BAIL_OUT('no wizard in the docs');

my $d = site_tempdir();
setup_test_site($d);
make_path( "$d/lazysite/db/tables", "$d/lazysite/db/wizards" );
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "time_zone: Europe/London\nextensions:\n  - extensions/data.pl\n";
close $cf;
spit( "$d/lazysite/db/tables/opening.yaml", "title: Opening hours\nschedule: true\npublic: true\n" );
apply_schema( $d, 'opening' );
spit( "$d/lazysite/db/wizards/opening_hours.yaml", $def );

my $w = Lazysite::Data::Wizard::load_wizard( $d, 'opening_hours' );
ok( $w->{ok}, 'it is a valid wizard over the schedule table' ) or diag explain $w;
is( $w->{table}, 'opening', '... writing the table the docs name' );

# Answer the questions as a person would, one at a time, and return the
# fields asked in order with the finished row.
sub walk {
    my (%say) = @_;
    my ( %answers, @asked );
    for ( 1 .. 20 ) {
        my $r = Lazysite::Data::Wizard::run_steps( $w, \%answers );
        return ( $r, \@asked ) if !$r->{ok} || $r->{complete};
        my $f = $r->{question}{field};
        push @asked, $f;
        $answers{$f} = exists $say{$f} ? $say{$f} : '';
    }
    die "the wizard did not finish\n";
}

subtest 'an exception with other hours, for a range of dates' => sub {
    my ( $r, $asked ) = walk( kind => 'exception', date_from => '2099-12-24', date_until => '2099-12-27',
        closed => 'no', opens => '10:00', closes => '14:00', note => 'Holiday hours' );
    ok( $r->{complete}, 'the wizard completes' ) or diag explain $r;
    is_deeply( $asked, [qw(kind date_from date_until closed opens closes note)],
        '... asking an exception\'s questions, never a day' );
    is_deeply( $r->{row},
        { kind => 'exception', date_from => '2099-12-24', date_until => '2099-12-27', closed => 0,
            opens => '10:00', closes => '14:00', note => 'Holiday hours' },
        '... and builds the exception row' );
    is( Lazysite::Data::Schedule::row_refusal( $r->{row} ), undef, 'a row the schedule reads' );
    my $ins = insert_row( $d, 'opening', $r->{row} );
    ok( $ins->{ok}, 'it is written to the schedule table' ) or diag explain $ins;
    my $rows = Lazysite::Data::Tables::read_rows( $d, 'opening', as => 'operator', where => { kind => 'exception' } );
    my ($x) = grep { ( $_->{note} // '' ) eq 'Holiday hours' } @{ $rows->{rows} || [] };
    ok( $x, '... and read back as an exception' );
    is( $x && $x->{date_until}, '2099-12-27', '... over its range' );
};

subtest 'a closed day' => sub {
    my ( $r, $asked ) = walk( kind => 'exception', date_from => '2099-12-25', closed => 'yes' );
    ok( $r->{complete}, 'the wizard completes with the times left empty' ) or diag explain $r;
    is_deeply( $r->{row}, { kind => 'exception', date_from => '2099-12-25', closed => 1 },
        '... a closed exception for one day' );
    ok( insert_row( $d, 'opening', $r->{row} )->{ok}, '... which the table takes' );
};

subtest 'a weekly period' => sub {
    my ( $r, $asked ) = walk( kind => 'period', day => 'mon', opens => '09:00', closes => '17:30' );
    is_deeply( $asked, [qw(kind day opens closes)], 'a period asks its day and times only' );
    is_deeply( $r->{row}, { kind => 'period', day => 'mon', opens => '09:00', closes => '17:30' },
        '... and builds the period row' );
    ok( insert_row( $d, 'opening', $r->{row} )->{ok}, '... which the table takes' );
};

subtest 'the date step takes YYYY-MM-DD only' => sub {
    my $r = Lazysite::Data::Wizard::run_steps( $w, { kind => 'exception', date_from => '25/12/2099' } );
    ok( !$r->{ok}, 'a date in another shape is refused' );
    is( $r->{field}, 'date_from', '... naming the step' );
    like( $r->{error} // '', qr/is a date, YYYY-MM-DD/, '... and the shape it takes' );
    my $ok = Lazysite::Data::Wizard::run_steps( $w, { kind => 'exception', date_from => ' 2099-12-25 ' } );
    ok( $ok->{ok}, 'one with spaces around it is taken' ) or diag explain $ok;
    my $c = Lazysite::Data::Wizard::check_definition( 'x',
        { table => 'opening', steps => [ { field => 'note', ask => 'When?', type => 'date' } ] },
        sub { Lazysite::Data::Tables::load_table( $d, $_[0] ) } );
    like( $c->{error} // '', qr/a date step cannot write 'note'/, 'a date step cannot write a text field' );
};

done_testing();

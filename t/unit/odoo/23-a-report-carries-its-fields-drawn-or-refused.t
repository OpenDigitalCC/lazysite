#!/usr/bin/perl
# SM747 R wiring (OOM answered R-Q1 as recommended, 0.02): a display read returns
# `rows` beside `fields`, the descriptors carrying `portable_type`. Lazysite
# draws them through the data extension's own descriptor rules and REFUSES, by
# name, a field it cannot draw - it never guesses a type from Odoo's own.
#
#   * odoo_run (and the endpoint, which answers the same result) hands back
#     `fields` (drawn) and `refused` beside the report, which stays as Odoo's
#     operation returned it;
#   * the `odoo:` page binding hands TT the report with `fields` drawn,
#     `refused` named, and no value of a refused field left in the rows;
#   * a report with no descriptors, or with a list of names as `fields` (the
#     shape before 0.02), reaches every door exactly as it did.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo         ();
use Lazysite::Odoo::Fields ();

my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
bind( $d, id => 'stock', operation => 'shop.stock', modes => 'public, authenticated', callers => 'staff' );
bind( $d, id => 'plain', operation => 'shop.plain', modes => 'public, authenticated', callers => 'staff' );
load_processor($d);
$Lazysite::Odoo::TRANSPORT = $fake;

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
sub run { my ($id) = @_; return ( quiet( sub { Lazysite::Odoo::action_odoo_run( $id, {}, %SAM ) } ) )[1] }

subtest 'the interface: drawn, or refused by name' => sub {
    my ( $f, $r ) = Lazysite::Odoo::Fields::present( { fields => { a => { portable_type => 'text' } } } );
    is_deeply( [ sort keys %$f ], ['a'], 'a report with descriptors is drawn' );
    is_deeply( [ Lazysite::Odoo::Fields::present( { rows => [] } ) ], [], 'a report without them: nothing' );
    is_deeply( [ Lazysite::Odoo::Fields::present( { fields => ['name'] } ) ], [],
        'a list of names (the shape before 0.02) is not descriptors: nothing' );
    is_deeply( [ Lazysite::Odoo::Fields::present('x') ], [], 'a report that is not a mapping: nothing' );
};

subtest 'odoo_run: fields drawn and refused beside the report' => sub {
    my $r = run('stock');
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is_deeply( [ sort keys %{ $r->{fields} } ], [qw(kind name price qty)], 'the four it can draw' );
    is( $r->{fields}{price}{type},   'decimal', 'a decimal keeps its type' );
    is( $r->{fields}{price}{places}, 2,         '...and its places' );
    is_deeply( $r->{fields}{kind}{values}, [qw(drink food)], 'an enum keeps its values' );
    is( $r->{fields}{name}{title}, 'Name', 'the label is the title' );
    is_deeply( [ map { $_->{field} } @{ $r->{refused} } ], [qw(note ratio)], 'the two it cannot, named' );
    like( $r->{refused}[0]{why}, qr/no portable_type, and lazysite does not guess/, 'with the reason: no type' );
    like( $r->{refused}[1]{why}, qr/needs (?:digits|places)/, 'and the reason: a decimal with no precision' );
    is( scalar @{ $r->{report}{rows} }, 2, 'the report is as the operation returned it' );
    ok( exists $r->{report}{rows}[0]{note}, '...including a refused field\'s values (the report is not rewritten)' );
    is( ref $r->{report}{fields}, 'HASH', '...and its own descriptors' );
};

subtest 'a report without descriptors reaches the door as it was' => sub {
    my $r = run('plain');
    ok( $r->{ok},                                      'answered' ) or diag explain $r;
    ok( !exists $r->{fields} && !exists $r->{refused}, 'no fields or refused beside it' );
    is_deeply( $r->{report}{fields}, ['name'], 'and its list of names is untouched' );
};

subtest 'the page binding: fields drawn, refused named, nothing refused is rendered' => sub {
    my ( undef, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:stock' } ) } );
    my $x = $v{x};
    ok( ref $x eq 'HASH', 'a hash for the template' ) or diag explain $x;
    is_deeply( [ sort keys %{ $x->{fields} } ], [qw(kind name price qty)], 'x.fields is the drawn set' );
    is_deeply( [ map { $_->{field} } @{ $x->{refused} } ], [qw(note ratio)], 'x.refused names the others' );
    is( scalar @{ $x->{rows} }, 2, 'the rows are there' );
    my %cols = map { $_ => 1 } map { keys %$_ } @{ $x->{rows} };
    is_deeply( [ sort keys %cols ], [qw(kind name price qty)], 'with only the drawn columns' );
    is( $x->{rows}[0]{name}, 'Tea', 'a value is as it was' );
    ( undef, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:plain' } ) } );
    is_deeply( $v{x}{fields}, ['name'], 'a report with no descriptors renders as it did' );
    ok( !exists $v{x}{refused}, '...with no refused list' );
};

subtest 'a label from Odoo is escaped on the page' => sub {
    no warnings 'redefine';
    no warnings q{once};
    local *LazysiteTest::OdooOps::Stock::report = sub {
        return { rows => [ { name => 'x' } ],
            fields => { name => { portable_type => 'text', string => '<b>Name</b>' } } };
    };
    my ( undef, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:stock' } ) } );
    unlike( $v{x}{fields}{name}{title}, qr/<b>/, 'a field title carries no raw markup' );
    like( $v{x}{fields}{name}{title}, qr/&lt;b&gt;/, 'it is escaped, as a value is' );
};

done_testing();

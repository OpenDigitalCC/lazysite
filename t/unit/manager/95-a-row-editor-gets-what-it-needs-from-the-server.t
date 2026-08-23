#!/usr/bin/perl
# DM-3: the contract between the row editor and the server.
#
# THE EDITOR DECIDES NOTHING ABOUT VALIDITY. It is built from the descriptor,
# sends what the operator typed, and shows what the server said. That is the
# only arrangement under which there is ONE validator - two would disagree the
# first time one of them changed, and the one in JavaScript would be the one
# nobody ran the tests against.
#
# So what the page needs from the server is assertable without a browser:
#
#   1. a refused value NAMES THE FIELD, so the form can point at it;
#   2. a field left blank is NOT SENT, and the server applies the declared
#      default - or refuses if the field is required;
#   3. an update touches only the fields sent, leaving the rest alone;
#   4. the key addresses the row and is not a value that can be edited.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema read_rows);
use Lazysite::Manager::Data ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;
open my $f, '>', "$docroot/lazysite/db/tables/stock.yaml" or die $!;
print {$f} <<'YAML';
key: sku
fields:
  sku:
    type: text
    required: true
  qty:
    type: integer
    min: 0
    default: 0
  state:
    type: enum
    values: [new, used]
    default: new
  note:
    type: text
YAML
close $f;
apply_schema( $docroot, 'stock' );
$Lazysite::Manager::Data::DOCROOT = $docroot;

sub save   { Lazysite::Manager::Data::action_data_row_save( 'stock', @_ ) }
sub row_of { my ($k) = @_; ( grep { $_->{sku} eq $k } @{ read_rows( $docroot, 'stock', as => 'operator' )->{rows} } )[0] }

subtest 'A REFUSAL NAMES THE FIELD' => sub {
    my $r = save( undef, { sku => 'A1', qty => 'lots' } );
    ok( !$r->{ok}, 'a non-integer for an integer is refused' );
    is( $r->{field}, 'qty', 'and the reply says WHICH field' )
        or diag( 'Without this the form can only say "something was wrong" '
            . 'and leave the operator to re-read every box.' );
    like( $r->{error}, qr/whole number/, 'with the rule in plain words' );

    my $e = save( undef, { sku => 'A1', state => 'broken' } );
    is( $e->{field}, 'state', 'an enum miss names its field too' );
    like( $e->{error}, qr/\bnew\b.*\bused\b|\bused\b.*\bnew\b/s,
        'and lists what it would have accepted' );
};

subtest 'A BLANK IS NOT SENT, AND THE DEFAULT APPLIES' => sub {
    # This is the editor's collectRow() rule: an empty input is left out of the
    # row entirely. The alternative - sending '' for every untouched field -
    # would overwrite every declared default with an empty string on every
    # save, and the store keeps NULL and '' apart.
    my $r = save( undef, { sku => 'B2' } );
    ok( $r->{ok}, 'a row with only its key is accepted' ) or diag( $r->{error} );
    my $row = row_of('B2');
    is( $row->{qty},   0,     'the integer default applied' );
    is( $row->{state}, 'new', 'the enum default applied' );
    ok( !defined $row->{note}, 'a field with no default is NOT SET, not empty' )
        or diag( 'If this is "" the page sent a blank it should have omitted.' );
};

subtest 'an update touches only what was sent' => sub {
    save( undef, { sku => 'C3', qty => 5, note => 'keep me' } );
    my $r = save( 'C3', { qty => 7 } );
    ok( $r->{ok}, 'the update is accepted' ) or diag( $r->{error} );
    my $row = row_of('C3');
    is( $row->{qty},  7,         'the sent field changed' );
    is( $row->{note}, 'keep me', 'and the unsent one did not' )
        or diag( 'An edit form that blanked every field it did not show would '
            . 'be a data-loss tool with a Save button.' );
};

subtest 'THE KEY IS AN ADDRESS, NOT A VALUE' => sub {
    # The editor renders the key read-only on an update. The server has to
    # agree, or the read-only attribute is decoration: a client that removes it
    # would be able to re-key a row, which is a delete-and-insert wearing the
    # name of an edit.
    my $r = save( 'C3', { sku => 'Z9', qty => 1 } );

    # THE REFUSAL IS ASSERTED, NOT JUST THE OUTCOME. The first version of this
    # checked only that the row stayed at C3 - and it passed while the server
    # was silently DROPPING the new key and replying ok, with qty changed to
    # 1. The row did not move, so the test was satisfied, and the caller had
    # been told their request succeeded when half of it was thrown away.
    ok( !$r->{ok}, 'a re-key on update is REFUSED, not ignored' )
        or diag( 'ok:1 here means the key was discarded and the rest of the '
            . 'update applied - success reported for a request that was not '
            . 'carried out.' );
    is( $r->{field}, 'sku', 'naming the key field' );
    like( $r->{error}, qr/delete it and add it again/, 'and saying how to move a row' );

    my $moved = row_of('Z9');
    my $still = row_of('C3');
    ok( $still && !$moved, 'and the row is still at its original key' );
    is( $still->{qty}, 7, 'with NOTHING else from that request applied' )
        or diag( 'A refusal that had already applied the other fields would '
            . 'be a half-write reported as a failure.' );
};

subtest 'a required field cannot be left blank' => sub {
    my $r = save( undef, { qty => 1 } );
    ok( !$r->{ok}, 'a row with no key is refused' );
    like( $r->{error}, qr/\bsku\b/, 'naming the missing field' );
};

done_testing();

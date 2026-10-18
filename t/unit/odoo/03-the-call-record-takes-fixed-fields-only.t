#!/usr/bin/perl
# SM747 OB8: one record per call - actor, the connection login, binding,
# operation, mode, outcome - and NEVER the payload or the credential. The sink
# refuses any field it does not know, which is how OOM's own audit makes the
# same promise: a payload cannot be added by accident to a trail that will not
# take the key.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(site_tempdir);
use Lazysite::Odoo ();

my $d = site_tempdir();
local $Lazysite::Odoo::DOCROOT = $d;

sub lines {
    open my $fh, '<', Lazysite::Odoo::calls_file() or return ();
    my @l = map { decode_json($_) } <$fh>;
    close $fh;
    return @l;
}

{
    local *STDERR;
    my $log = '';
    open STDERR, '>', \$log or die $!;
    ok( !Lazysite::Odoo::record_call( binding => 'b', params => { qty => 3 } ),
        'a record carrying params is refused' );
    ok( !Lazysite::Odoo::record_call( binding => 'b', api_key => 'k' ),
        'a record carrying a key is refused' );
    like( $log, qr/fields=api_key|fields=params/, 'and the refusal names the field' );
}
is( scalar( my @none = lines() ), 0, 'nothing was written for either' );

ok( Lazysite::Odoo::record_call(
        call_id => 'c1', actor => 'visitor', visitor => 'v1234', ip => '192.0.2.7',
        login   => 'site-connection', binding => 'basket-add', operation => 'shop.add',
        mode    => 'public',          phase => 'apply', outcome => 'answered', ms => 12 ),
    'a record of the fixed fields is written' );
my @l = lines();
is( scalar @l, 1, 'one line' );
is_deeply( [ sort keys %{ $l[0] } ],
    [ sort qw(at call_id actor visitor ip login binding operation mode phase outcome ms) ],
    'exactly the fields given, plus the time' );
is_deeply( [ sort @Lazysite::Odoo::CALL_FIELDS ],
    [ sort qw(at call_id actor visitor ip login binding operation mode phase outcome kind ms via) ],
    'the field list is the one the filing names (SM1164 adds `via`: daemon or in-process), and nothing to carry a payload' );

my $mode = ( stat Lazysite::Odoo::calls_file() )[2] & 07777;
ok( !( $mode & 07 ), sprintf( 'the record is not world-readable (%04o)', $mode ) );

open my $a, '<', "$d/lazysite/logs/audit.log";
my $audit = $a ? do { local $/; <$a> } : '';
like( $audit, qr/odoo-call \| basket-add -> shop\.add \| 192\.0\.2\.7 \| answered \| public/,
    'the shared audit trail has the line too' );

is( Lazysite::Odoo::read_calls()->[0]{call_id}, 'c1', 'and the operator reads it back' );

done_testing();

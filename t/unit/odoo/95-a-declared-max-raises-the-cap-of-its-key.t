#!/usr/bin/perl
# SM1224 (ruling 2026-10-20, "OOM Lab questions": "yes"): a rows key an operation
# declares with its own `max` (OOM 0.38, up to 1,048,576) raises lazysite's per-value
# cap ($MAX_VALUE, 1,000) for THAT key; a key that declares none keeps 1,000.
#
# Held here: through a call (the rows check of SM1198, OOM's Odoo::Ops::Rows->check,
# then the plain-value rule), directly on Binding::_rows, and at the endpoint, where
# the 64 KB body cap would otherwise refuse a declared large value before the
# binding is known: a request over 64 KB names its binding in the query and is
# weighed against that binding's own budget (declared maxima, never above 20 MB).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Binding ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

bind( $d, id => 'notes', operation => 'shop.notes', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'notes=notes' );
bind( $d, id => 'memo', operation => 'shop.notes', modes => 'public',
    apply => 'immediate', params => 'memo=memo' );
bind( $d, id => 'order', operation => 'shop.order', modes => 'public,authenticated', callers => 'staff',
    apply => 'immediate', params => 'lines=lines', fixed => 'basket_key=cart' );

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
sub run {
    my ( $id, $params ) = @_;
    return ( quiet( sub { Lazysite::Odoo::action_odoo_run( $id, $params, %SAM ) } ) )[1];
}
sub n_basket { return scalar @{ $fake->all_ids('x.basket') } }

subtest 'a key that declares max 5000 takes 4,000 characters and refuses 6,000' => sub {
    my $before = n_basket();
    my $r      = run( 'notes', { notes => [ { title => 't', body => 'x' x 4000 } ] } );
    ok( $r->{applied}, '4,000 characters: applied' ) or diag explain $r;
    is( n_basket(), $before + 1, 'and reached Odoo' );
    $r = run( 'notes', { notes => [ { title => 't', body => 'x' x 5000 } ] } );
    ok( $r->{applied}, 'exactly the declared 5000 is taken' ) or diag explain $r;
    $before = n_basket();
    $r      = run( 'notes', { notes => [ { title => 't', body => 'x' x 6000 } ] } );
    is( $r->{kind}, 'invalid', '6,000 characters: refused' ) or diag explain $r;
    like( $r->{error} // '', qr/row 1.*body.*5000/, 'naming the row, the key and the declared limit' );
    is( n_basket(), $before, 'nothing reached Odoo' );
};

subtest 'a key that declares no max keeps 1,000' => sub {
    my $r = run( 'notes', { notes => [ { title => 't' x 1000 } ] } );
    ok( $r->{applied}, '1,000 characters: applied' ) or diag explain $r;
    my $before = n_basket();
    $r = run( 'notes', { notes => [ { title => 't' x 1001 } ] } );
    is( $r->{kind}, 'invalid', '1,001 characters: refused' ) or diag explain $r;
    like( $r->{error} // '', qr/row 1: 'title' is longer than 1000 characters/, 'by the plain-value rule' );
    is( n_basket(), $before, 'nothing reached Odoo' );
    $r = run( 'order', { lines => [ { product_id => 1, qty => 1, note => 'x' x 1001 } ] } );
    is( $r->{kind}, 'invalid', 'an operation with no declared max anywhere: 1,001 refused too' ) or diag explain $r;
};

subtest 'the rows check is the light one (SM1198), and the declared max is read from it' => sub {
    my ($b)     = Lazysite::Odoo::find_binding('notes');
    my ($conn)  = Lazysite::Odoo::connection();
    my ($class) = Lazysite::Odoo::binding_class( $b, $conn );
    my $decl    = $class->params->{notes};
    my $out     = sub {
        my ($len) = @_;
        return [ Lazysite::Odoo::Binding::_rows( $b, $class, $decl, 'notes', [ { title => 't', body => 'x' x $len } ] ) ];
    };
    ok( $INC{'Odoo/Ops/Rows.pm'}, 'Odoo::Ops::Rows is the check in use' );
    ok( $out->(4000)->[0],        '4,000 accepted' );
    my $bad = $out->(6000);
    ok( !$bad->[0], '6,000 refused' );
    like( $bad->[1], qr/'notes' row 1: key 'body' must be at most 5000 characters/, 'by OOM\'s own words (its max is the key\'s)' );
    # OOM allows 8000 here; lazysite does not lower it below the declared max, and
    # does not let a declaration above OOM's own ceiling through
    is( Lazysite::Odoo::Binding::key_limit( { k => { type => 'str', max => 8000 } }, 'k' ), 8000, 'a declared max is the key\'s limit' );
    is( Lazysite::Odoo::Binding::key_limit( { k => { type => 'str', max => 200 } }, 'k' ), 1000, 'one below 1,000 leaves the cap (OOM holds it lower)' );
    is( Lazysite::Odoo::Binding::key_limit( { k => 'str' }, 'k' ), 1000, 'a key with no declaration keeps 1,000' );
    is( Lazysite::Odoo::Binding::key_limit( { k => { type => 'str', max => 9_999_999 } }, 'k' ), 1_048_576, 'never above 1,048,576' );
    is( Lazysite::Odoo::Binding::_plain_problem( 'x' x 1001 ), 'is longer than 1000 characters', 'a bare value keeps 1,000' );
};

subtest 'the request-size budget follows the declared maxima' => sub {
    my ( $conn, $b );
    ($b) = Lazysite::Odoo::find_binding('notes');
    is( Lazysite::Odoo::json_budget($b), 64 * 1024 + 3 * ( 6 * 5000 + 6 * 1000 + length('body') + length('title') + 16 ),
        'a binding with a 5000 key: 64 KB plus what three rows can hold' );
    ($b) = Lazysite::Odoo::find_binding('order');
    is( Lazysite::Odoo::json_budget($b), 64 * 1024, 'a binding with no declared max: 64 KB, as before' );
    ($b) = Lazysite::Odoo::find_binding('memo');
    my $m = Lazysite::Odoo::json_budget($b);
    cmp_ok( $m, '>', 1_200_000, 'a binding with a 200,000-character key: over a megabyte' );
    cmp_ok( $m, '<', 1_300_000, 'and no more than that key needs' );
    my $spec = { big => { type => 'rows', max => 50, row => { t => { type => 'str', max => 1_048_576 } } } };
    is( Lazysite::Odoo::Binding::json_budget( { params => { big => 'big' } }, $spec ), 20 * 1024 * 1024,
        '50 rows of 1 MB: the endpoint\'s ceiling, 20 MB' );
    is( Lazysite::Odoo::Binding::json_budget( { params => { big => 'big' }, rows_max => 1 }, $spec ),
        64 * 1024 + 6 * 1_048_576 + 1 + 8, 'a binding\'s rows_max lowers it' );
};

# --- the endpoint ---------------------------------------------------------------
require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out = '';
    my $in  = defined $body ? ( ref $body ? encode_json($body) : $body ) : '';
    my $pos;
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $in,
            HTTP_HOST => 'localhost', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$in or die $!;
        binmode STDIN;
        quiet( sub { main::main() } );
        $pos = tell STDIN;
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out, $pos );
}
sub cv { my ( $c, $n ) = @_; for (@$c) { return $1 if /\A\Q$n\E=([^;]*)/ } return undef }

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};
sub post {
    my ( $binding_in_query, $body, %o ) = @_;
    return request( 'POST', ( $binding_in_query ? "binding=$binding_in_query" : '' ), $body,
        CONTENT_TYPE => 'application/json', HTTP_COOKIE => $VC, %o );
}

subtest 'a request over 64 KB reaches a binding whose declared maxima need it' => sub {
    my $text   = 'm' x 100_000;
    my $before = n_basket();
    my ( $st, undef, $j, $raw ) = post( 'memo', { binding => 'memo', visitor_token => $VT, params => { memo => [ { text => $text } ] } } );
    is( $st, 200, '100,000 characters to the memo binding: answered' ) or diag $raw;
    ok( $j->{applied}, 'applied' )                                     or diag explain $j;
    is( n_basket(), $before + 1, 'and reached Odoo' );

 # the same size to a binding whose maxima do not need it, or with no binding in the query
    ( $st, undef, $j, $raw ) = post( 'order', { binding => 'order', visitor_token => $VT, params => { lines => [ { product_id => 1, qty => 1, note => $text } ] } } );
    is( $st, 413, 'to a binding with no declared max: 413 as before' );
    ( $st, undef, $j, $raw ) = post( undef, { binding => 'memo', visitor_token => $VT, params => { memo => [ { text => $text } ] } } );
    is( $st,         413,              'with no binding in the query: 413 as before' );
    is( $j->{error}, 'body too large', 'in the old words' );
    ( $st, undef, $j, $raw ) = post( 'memo', { binding => 'order', visitor_token => $VT, params => { lines => [] }, pad => $text } );
    is( $st, 413, 'a body that names another binding than the query: refused' );
    ( $st, undef, $j, $raw ) = post( 'memo', { calls => [ { binding => 'memo' } ], pad => $text } );
    is( $st, 413, 'a batch over 64 KB: refused' );
};

subtest 'over the binding\'s budget is refused before the body is read' => sub {
    my ( $st, undef, $j, $raw, $pos ) = post( 'memo', { binding => 'memo' }, CONTENT_LENGTH => 5 * 1024 * 1024 );
    is( $st,        413,         '5 MB to a 200,000-character key: 413' ) or diag $raw;
    is( $j->{kind}, 'too-large', 'too-large' );
    like( $j->{error} // '', qr/at most \d+ bytes/, 'naming the budget' );
    is( $pos, 0, 'not one byte of the body was read' );
    ( $st, undef, $j, $raw, $pos ) = post( 'notes', { binding => 'notes' }, CONTENT_LENGTH => 1024 * 1024 );
    is( $st,  413, '1 MB to the 5000-character binding: 413' );
    is( $pos, 0,   'unread' );
};

done_testing;

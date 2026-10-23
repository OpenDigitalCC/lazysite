#!/usr/bin/perl
# SM1278 (rulings 10b, 10c): the manager's Odoo page lists the runs left unknown and
# still open, and an operator assumes or dismisses there. odoo-unknown-runs and
# odoo-dismiss need settle_odoo_writes (asked here as well as at the control API's
# gate, since MCP calls the same functions); odoo-resume is the binding's, as on the
# page. A dismissal sends nothing, is kept with who and why, is one call record and
# one audit line, and ends the run: it is not listed, not resumed, and goes on the
# plan store's schedule. A run of a domain the caller does not reach is neither
# listed nor dismissed (domain_refusal, as odoo-bindings asks it: t/unit/odoo/20).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'title=title' );

my %SAM = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );
my %OPS = ( user => 'ops', groups => [], caps => { settle_odoo_writes => 1, manage_connectors => 1 }, ip => '192.0.2.7',
    channel => 'api', reach => {} );
my %NOBODY = ( user => 'eve', groups => ['staff'], caps => {}, ip => '192.0.2.8', channel => 'api', reach => {} );

sub timeout { return Odoo::Error->new( kind => 'transport', sent => 1, write => 1, message => 'Timed out while waiting for socket to become ready for reading' ) }
sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }
sub unknown_run {
    my ( $id, %ctx ) = @_;
    $fake->{fail}{'x.basket.create'} = timeout();
    my ( undef, $r ) = quiet( sub { my ($b) = Lazysite::Odoo::find_binding($id); Lazysite::Odoo::call( $b, { title => 'R' }, strict => 1, %ctx ) } );
    delete $fake->{fail}{'x.basket.create'};
    return $r;
}
sub listed { my ($r) = @_; return { map { ( $_->{run} => $_ ) } @{ $r->{runs} || [] } } }

my $one = unknown_run( 'mix', %SAM );
my $two = unknown_run( 'mix', %SAM );
ok( $one->{run} && $two->{run}, 'two runs left unknown' ) or diag explain [ $one, $two ];

subtest 'the list is the settling capability\'s, and shows what is unknown, never a value' => sub {
    my $no = act( 'action_odoo_unknown_runs', %NOBODY );
    is( $no->{kind}, 'forbidden', 'without settle_odoo_writes: refused' ) or diag explain $no;
    my $l = act( 'action_odoo_unknown_runs', %OPS );
    ok( $l->{ok}, 'listed' ) or diag explain $l;
    my $by = listed($l);
    ok( $by->{ $one->{run} } && $by->{ $two->{run} }, 'both open runs are there' );
    my $r = $by->{ $one->{run} };
    is( $r->{binding}, 'mix',         'its binding' );
    is( $r->{owner},   'account:sam', 'who made it' );
    is( $r->{count},   1,             'how many changes were unknown' );
    is_deeply( [ map { $_->{key} } @{ $r->{changes} } ], ['line:1'], 'and the change still unknown' );
    unlike( encode_json($l), qr/basket_key|"vals"|journal\.jsonl|\/lazysite\//, 'no value and no path' );
};

subtest 'an operator assumes there, through the binding' => sub {
    my $s = act( 'action_odoo_resume', $one->{run}, ['line:1'], undef, %OPS );
    ok( $s->{ok}, 'settled' ) or diag explain $s;
    ok( !listed( act( 'action_odoo_unknown_runs', %OPS ) )->{ $one->{run} }, 'and no longer listed' );
    my $no = act( 'action_odoo_resume', $two->{run}, ['line:1'], undef, %NOBODY );
    is( $no->{kind}, 'not-yours', 'a caller who is neither its maker nor holds the capability may not assume' ) or diag explain $no;
};

subtest 'a dismissal is the operator\'s, sends nothing, is recorded, and ends the run' => sub {
    my $calls = scalar @{ $fake->calls };
    my $no = act( 'action_odoo_dismiss', $two->{run}, 'x', %NOBODY );
    is( $no->{kind}, 'forbidden', 'without the capability: refused' );
    is( act( 'action_odoo_dismiss', 'f' x 32, undef, %OPS )->{kind}, 'not-found', 'no such run: not found' );
    is( act( 'action_odoo_dismiss', $two->{run}, "two\nlines", %OPS )->{kind}, 'invalid', 'a reason is one line' );
    my $r = act( 'action_odoo_dismiss', $two->{run}, 'checked by phone: not made, not wanted', %OPS );
    ok( $r->{ok} && $r->{dismissed}, 'dismissed' ) or diag explain $r;
    is( scalar @{ $fake->calls }, $calls, 'nothing was sent to Odoo' );
    my $meta = Lazysite::Odoo::_read_json_file( Lazysite::Odoo::plans_dir() . "/$two->{run}/meta.json" );
    is( $meta->{dismissed}{by},     'account:ops',                            'kept with who' );
    is( $meta->{dismissed}{reason}, 'checked by phone: not made, not wanted', 'and why' );
    ok( !listed( act( 'action_odoo_unknown_runs', %OPS ) )->{ $two->{run} }, 'no longer listed' );
    my ( undef, $res ) = quiet( sub { Lazysite::Odoo::resume( $two->{run}, %SAM ) } );
    is( $res->{kind}, 'dismissed', 'its maker cannot resume it' ) or diag explain $res;
    is( act( 'action_odoo_dismiss', $two->{run}, undef, %OPS )->{kind}, 'dismissed', 'and it is not dismissed twice' );

    my ($rec) = grep { ( $_->{phase} // '' ) eq 'dismiss' && ( $_->{outcome} // '' ) eq 'answered' } @{ Lazysite::Odoo::read_calls() };
    ok( $rec, 'one call record' ) or return;
    is( $rec->{run},      $two->{run}, 'naming the run' );
    is( $rec->{decision}, 'dismiss',   'and the decision' );
    is( $rec->{actor},    'ops',       'and who' );
    my $audit = do { local $/; open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!; <$fh> };
    like( $audit, qr/ops \| odoo-call \| mix -> shop\.mixed .*run=$two->{run} decision=dismiss/, 'one audit line' );
};

subtest 'a dismissed run goes on the plan store\'s schedule' => sub {
    my $p    = Lazysite::Odoo::plans_dir() . "/$two->{run}/meta.json";
    my $meta = Lazysite::Odoo::_read_json_file($p);
    $meta->{created} = time - ( $Lazysite::Odoo::PLAN_KEEP_DAYS + 1 ) * 86400;
    Lazysite::Odoo::_write_json_file( $p, $meta );
    quiet( sub { my ($b) = Lazysite::Odoo::find_binding('mix'); Lazysite::Odoo::call( $b, { title => 'p' }, strict => 1, %SAM ) } );
    ok( !-e $p, 'pruned' );
};

subtest 'the Odoo extension\'s row on the Extensions page offers them' => sub {
    my $page = do { local $/; open my $fh, '<', "$FindBin::Bin/../../../starter/manager/plugin-config.md" or die $!; <$fh> };
    like( $page, qr/plugin\.id === 'odoo'.*Unknown Odoo writes/s, 'an Unknown Odoo writes panel on the Odoo row' );
    like( $page, qr/action=odoo-unknown-runs/, 'listing the open runs' );
    like( $page, qr/action=odoo-resume/,       'checking again and assuming' );
    like( $page, qr/action=odoo-dismiss/,      'and dismissing' );
    like( $page, qr/>It was made</,            'with the operator\'s two words' );
    like( $page, qr/>It was not made</,        'for a change' );
    like( $page, qr/>Close run</,              'and Close run for the run' );
};

done_testing;

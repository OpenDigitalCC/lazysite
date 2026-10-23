#!/usr/bin/perl
# SM1279 (ruling 10c, 2026-10-23): "a run stays resumable until it is settled or
# dismissed (no expiry)". The plan store prunes a plan after its days
# ($PLAN_KEEP_DAYS) and the daemon's run folders on the same schedule; a confirmed
# plan's file bytes go once it is spent (SM1162). A run whose apply left a change
# unknown is kept whole - its folder, its daemon run folder and its file bytes - for
# as long as it is open, because a resume reads all three: a change assumed not made
# is sent again with its bytes. Settled, it goes on the ordinary schedule.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
for my $f (qw(name res_model mimetype checksum)) { $fake->{fields}{'ir.attachment'}{$f} = { type => 'char', string => $f, portable_type => 'text' } }
for my $f (qw(res_id file_size)) { $fake->{fields}{'ir.attachment'}{$f} = { type => 'integer', string => $f, portable_type => 'integer' } }
$fake->{fields}{'ir.attachment'}{datas} = { type => 'binary', string => 'datas', portable_type => 'binary' };

bind( $d, id => 'att', operation => 'core.attach', modes => 'authenticated', callers => 'staff',
    file_params => 'f=file', fixed => 'model=x.product,record=1', file_max_kb => 8 );
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'title=title' );
my %SAM   = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );
my $BYTES = "\xFF\xD8\xFF\xE0MARKER-kept-" . ( 'k' x 300 );

sub timeout { return Odoo::Error->new( kind => 'transport', sent => 1, write => 1, message => 'Timed out while waiting for socket to become ready for reading' ) }
sub pdir  { return Lazysite::Odoo::plans_dir() . "/$_[0]" }
sub blobs { my $b = pdir( $_[0] ) . '/blobs'; return -d $b ? scalar( () = glob("$b/*") ) : 0 }
sub q_ { my ( undef, $r ) = quiet( $_[0] ); return $r }
sub age {
    my ( $pid, $days ) = @_;
    my $m = Lazysite::Odoo::_read_json_file( pdir($pid) . '/meta.json' );
    $m->{created} = time - $days * 86400;
    Lazysite::Odoo::_write_json_file( pdir($pid) . '/meta.json', $m );
}
sub prune { q_( sub { my ($b) = Lazysite::Odoo::find_binding('mix'); Lazysite::Odoo::call( $b, { title => 'p' }, %SAM ) } ) }

subtest 'an unknown confirm keeps its file bytes, and a change assumed not made is sent with them' => sub {
    my $p = q_( sub { my ($b) = Lazysite::Odoo::find_binding('att'); Lazysite::Odoo::call( $b, {}, %SAM, files => { f => [ { name => 'r.jpg', bytes => $BYTES } ] } ) } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    $fake->{fail}{'ir.attachment.create'} = timeout();
    my $c = q_( sub { Lazysite::Odoo::confirm( $p->{plan}, %SAM ) } );
    delete $fake->{fail}{'ir.attachment.create'};
    is( $c->{unknown}, 1, 'the attachment is unknown' ) or diag explain $c;
    is( blobs( $p->{plan} ), 1, 'its bytes are kept' );
    my $before = scalar @{ $fake->all_ids('ir.attachment') };
    my $s = q_( sub { Lazysite::Odoo::resume( $c->{run}, %SAM, assume_not_done => [ map { $_->{key} // $_->{seq} } @{ q_( sub { Lazysite::Odoo::resume( $c->{run}, %SAM ) } )->{changes} } ] ) } );
    ok( $s->{ok} && $s->{applied}, 'the resume sends it' ) or diag explain $s;
    is( scalar @{ $fake->all_ids('ir.attachment') }, $before + 1, 'the attachment is made' );
    my ($att) = grep { ( $_->{name} // '' ) eq 'r.jpg' } map { $fake->record( 'ir.attachment', $_ ) } @{ $fake->all_ids('ir.attachment') };
    ok( $att && length( $att->{datas} // '' ), 'with its bytes' );
    is( blobs( $p->{plan} ), 0, 'and once settled they go' );
};

subtest 'an open run outlives the plan store\'s days; a settled one does not' => sub {
    $fake->{fail}{'x.basket.create'} = timeout();
    my $open = prune();
    my $done = prune();
    delete $fake->{fail}{'x.basket.create'};
    ok( $open->{run} && $done->{run}, 'two runs left unknown' ) or diag explain [ $open, $done ];
    my $s = q_( sub { Lazysite::Odoo::resume( $done->{run}, %SAM, assume_done => ['line:1'] ) } );
    ok( $s->{ok}, 'one is settled' ) or diag explain $s;
    my $plain = prune();
    ok( $plain->{ok}, 'and an ordinary apply' );
    age( $_, $Lazysite::Odoo::PLAN_KEEP_DAYS + 30 ) for $open->{run}, $done->{run}, $plain->{plan};

    # a daemon run folder an open run names, and one nothing names, both old
    my $runs = Lazysite::Odoo::store_dir() . '/runs';
    make_path( "$runs/kept-run", "$runs/old-run" );
    my $m = Lazysite::Odoo::_read_json_file( pdir( $open->{run} ) . '/meta.json' );
    $m->{run_id} = 'kept-run';
    Lazysite::Odoo::_write_json_file( pdir( $open->{run} ) . '/meta.json', $m );
    my $old = time - ( $Lazysite::Odoo::PLAN_KEEP_DAYS + 30 ) * 86400;
    utime $old, $old, "$runs/kept-run", "$runs/old-run";

    prune();    # a new plan prunes
    ok( -d pdir( $open->{run} ), 'the open run is kept' );
    ok( !-d pdir( $done->{run} ), 'the settled one is pruned' );
    ok( !-d pdir( $plain->{plan} ), 'as is an ordinary plan' );
    ok( -d "$runs/kept-run", 'the daemon run folder of the open run is kept' );
    ok( !-d "$runs/old-run", 'one nothing names is pruned' );

    $m->{run_id} = undef;
    delete $m->{run_id};
    Lazysite::Odoo::_write_json_file( pdir( $open->{run} ) . '/meta.json', $m );
    my $c = q_( sub { Lazysite::Odoo::resume( $open->{run}, %SAM ) } );
    is( $c->{kind}, 'unknown-outcome', 'and it is still resumable' ) or diag explain $c;
};

done_testing;

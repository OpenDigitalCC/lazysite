#!/usr/bin/perl
# SM1162 (release manager, 2026-10-19: "When the plan is applied or withdrawn"): the
# bytes of a file a planned write holds - OOM keeps them once, in the plan's
# blobs/ folder, so a confirm can apply them - are removed as soon as the plan is
# SPENT: applied (fully or partly), withdrawn, or refused as no longer applicable.
# An unconfirmed plan's go when the plan expires, as before. The plan record keeps
# the file's name, size, sha256 and type. The removal is OOM's own
# (Odoo::Ops::Blob->purge), and a revert after it does what it was found to do.
use strict;
use warnings;
use Test::More;
use File::Find ();
use File::Path qw(remove_tree);
use JSON::PP qw(decode_json encode_json);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
my $BYTES = "\xFF\xD8\xFF\xE0MARKER-blobs-" . ( 'z' x 300 );
my $SHA   = sha256_hex($BYTES);

# OOM's fake Odoo serving the attachment model core.attach writes to
for my $f (qw(name res_model mimetype checksum)) { $fake->{fields}{'ir.attachment'}{$f} = { type => 'char', string => $f, portable_type => 'text' } }
for my $f (qw(res_id file_size)) { $fake->{fields}{'ir.attachment'}{$f} = { type => 'integer', string => $f, portable_type => 'integer' } }
$fake->{fields}{'ir.attachment'}{datas} = { type => 'binary', string => 'datas', portable_type => 'binary' };

bind( $d, id => 'att', operation => 'core.attach', modes => 'authenticated', callers => 'staff',
    file_params => 'f=file', fixed => 'model=x.product,record=1', file_max_kb => 8 );

my %SAM = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );
sub plan_it {
    my ($name) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('att');
            Lazysite::Odoo::call( $b, {}, %SAM, files => { f => [ { name => $name // 'till.jpg', bytes => $BYTES } ] } );
    } );
    return $r;
}
sub pdir  { return Lazysite::Odoo::plans_dir() . "/$_[0]" }
sub blobs { my $b = pdir( $_[0] ) . '/blobs'; return -d $b ? scalar( () = glob("$b/*") ) : 0 }
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return <$fh> }

subtest 'a planned file write holds its bytes in the plan until the plan is spent' => sub {
    my $r = plan_it();
    ok( $r->{planned}, 'planned' ) or diag explain $r;
    is( blobs( $r->{plan} ), 1, 'the bytes sit in the plan\'s blobs/ folder, as OOM keeps them' );
    my $plan = slurp( pdir( $r->{plan} ) . '/plan.json' );
    unlike( $plan, qr/MARKER-blobs/, 'and not in the plan record' );
    like( $plan, qr/\Q$SHA\E/, 'which names the sha256' );
};

subtest 'after a confirm the blobs are gone and the plan record still names the file' => sub {
    my $r = plan_it('receipt.jpg');
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %SAM ) } );
    ok( $c->{ok} && $c->{applied}, 'applied' ) or diag explain $c;
    is( blobs( $r->{plan} ), 0, 'the plan\'s blobs/ folder is gone' );
    ok( !-d pdir( $r->{plan} ) . '/blobs', 'the folder itself' );
    my $plan = slurp( pdir( $r->{plan} ) . '/plan.json' );
    like( $plan, qr/\Q$SHA\E/, 'the plan record still names the sha256' );
    like( $plan, qr/receipt\.jpg/, 'and the name' );
    like( $plan, qr/"size"\s*:\s*\d+/, 'and the size' );
    ok( -e pdir( $r->{plan} ) . '/journal.jsonl', 'the journal is kept' );
    unlike( slurp( pdir( $r->{plan} ) . '/journal.jsonl' ), qr/MARKER-blobs/, 'with no bytes in it' );
};

subtest 'a withdrawn plan loses its blobs and cannot be confirmed' => sub {
    my $r = plan_it();
    is( blobs( $r->{plan} ), 1, 'it holds them' );
    my ( undef, $w ) = quiet( sub { Lazysite::Odoo::withdraw( $r->{plan}, %SAM ) } );
    ok( $w->{ok} && $w->{withdrawn}, 'withdrawn' ) or diag explain $w;
    is( blobs( $r->{plan} ), 0, 'the blobs are gone' );
    like( slurp( pdir( $r->{plan} ) . '/plan.json' ), qr/\Q$SHA\E/, 'the record names the sha256' );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %SAM ) } );
    ok( !$c->{ok}, 'it cannot be confirmed' );
    is( $c->{kind}, 'not-found', 'it does not exist for a confirm' );
    ( undef, $c ) = quiet( sub { Lazysite::Odoo::withdraw( $r->{plan}, %SAM ) } );
    is( $c->{kind}, 'not-found', 'and a withdrawn plan cannot be withdrawn again' );

    my $o = plan_it();
    my ( undef, $x ) = quiet( sub { Lazysite::Odoo::withdraw( $o->{plan}, %SAM, actor => 'bob' ) } );
    ok( !$x->{ok}, 'somebody else cannot withdraw it' );
    is( blobs( $o->{plan} ), 1, 'and its blobs stay' );
};

subtest 'a plan that can no longer apply loses its blobs' => sub {
    my $r = plan_it('stale.jpg');
    # an edited plan: the seal no longer fits
    my $pf = pdir( $r->{plan} ) . '/plan.json';
    my $j  = decode_json( slurp($pf) );
    $j->{changes}[0]{line} .= ' (edited)';
    open my $fh, '>:raw', $pf or die $!;
    print {$fh} JSON::PP->new->canonical->encode($j);
    close $fh;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %SAM ) } );
    ok( !$c->{ok}, 'refused' ) or diag explain $c;
    is( $c->{kind}, 'edited', 'as edited after it was made' );
    is( blobs( $r->{plan} ), 0, 'its blobs are gone' );
};

subtest 'an unconfirmed plan loses everything when it expires, as before' => sub {
    my $r = plan_it();
    my $mf = pdir( $r->{plan} ) . '/meta.json';
    my $m  = decode_json( slurp($mf) );
    $m->{created} = time - 86400 * 30;
    open my $fh, '>', $mf or die $!;
    print {$fh} encode_json($m);
    close $fh;
    plan_it();    # making a plan prunes
    ok( !-d pdir( $r->{plan} ), 'the expired plan is gone' );
};

subtest 'a revert after the purge' => sub {
    my $r = plan_it('revertme.jpg');
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %SAM ) } );
    ok( $c->{applied}, 'applied' ) or diag explain $c;
    is( blobs( $r->{plan} ), 0, 'purged' );
    require Odoo::Ops::Runner;
    my ($conn) = Lazysite::Odoo::connection();
    my $ctx = Lazysite::Odoo::context( $conn, actor => 'sam' );
    my $rv = eval { Lazysite::Odoo::with_site_ops( $conn, sub { Odoo::Ops::Runner->revert_plan( $ctx, pdir( $r->{plan} ) . '/journal.jsonl' ) } ) };
    my $err = $@;
    ok( !$rv, 'OOM refuses to plan the revert' );
    like( ref $err && $err->can('message') ? $err->message : "$err", qr/blob sha256:[0-9a-f]{64} \(\d+ bytes\) is missing from the run folder/,
        'plainly, naming the blob it cannot read back (an attachment has no inverse; the revert would only have held the row)' );
};

subtest 'the endpoint withdraws a plan its caller made, and no one else\'s' => sub {
    require "$FindBin::Bin/../../../lazysite-odoo.pl";
    TestHelper::setup_minimal_site($d);
    OdooTest::odoo_site($d);
    $Lazysite::Odoo::TRANSPORT = $fake;
    { no warnings 'once'; $Lazysite::Odoo::Visitor::DOCROOT = $d; }
    bind( $d, id => 'pub', operation => 'core.attach', modes => 'public',
        file_params => 'f=file', fixed => 'model=x.product,record=1', file_max_kb => 8 );
    my $req = sub {
        my ( $method, $query, $body, %env ) = @_;
        my $out = '';
        my $in  = $body // '';
        {
            local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query,
                REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', CONTENT_LENGTH => length $in,
                HTTP_HOST => 'localhost', %env );
            local *STDOUT;
            open STDOUT, '>', \$out or die $!;
            local *STDIN;
            open STDIN, '<', \$in or die $!;
            binmode STDIN;
            quiet( sub { main::main() } );
        }
        my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
        my ($st) = $head =~ /Status:\s*(\d+)/;
        my @ck = $head =~ /^Set-Cookie:\s*(.*?);/mg;
        return ( $st, \@ck, ( eval { decode_json( $payload // '' ) } || {} ) );
    };
    my ( undef, $ck, $tok ) = $req->( 'GET', 'csrf=1', '' );
    my $VC = join '; ', @$ck;
    my $VT = $tok->{visitor_token};
    my $b  = '----lzs0123456789abcdef';
    my $body = "--$b\r\nContent-Disposition: form-data; name=\"json\"\r\n\r\n" . encode_json( { visitor_token => $VT } )
        . "\r\n--$b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"p.jpg\"\r\n\r\n$BYTES\r\n--$b--\r\n";
    my ( $st, undef, $j ) = $req->( 'POST', 'binding=pub', $body, CONTENT_TYPE => "multipart/form-data; boundary=$b", HTTP_COOKIE => $VC );
    is( $st, 200, 'planned by the endpoint' ) or diag explain $j;
    my $pid = $j->{plan};
    is( blobs($pid), 1, 'it holds the bytes' );
    my $post = sub { encode_json( {@_} ) };
    ( $st, undef, $j ) = $req->( 'POST', '', $post->( plan => $pid, withdraw => JSON::PP::true, visitor_token => 'bad' ), HTTP_COOKIE => $VC );
    is( $st, 403, 'a withdraw needs its token' );
    is( blobs($pid), 1, 'and with a bad one nothing is removed' );
    ( $st, undef, $j ) = $req->( 'POST', '', $post->( plan => $pid, withdraw => JSON::PP::true, visitor_token => $VT ), HTTP_COOKIE => $VC );
    is( $st, 200, 'withdrawn' ) or diag explain $j;
    is( blobs($pid), 0, 'the bytes are gone' );
};

done_testing();

#!/usr/bin/perl
# SM1180, SM1162: A STORED DECLARATION CARRIES A BINDING'S FILE PARAMETERS.
#
# SM1180 stores each binding's operation declaration at save so a call oomd answers
# loads no OOM in the endpoint; SM1162 lets a binding take a file, checked against
# the operation's own `file` / `files` declarations (type, max, max_bytes) and
# weighed by the endpoint before the body is read (upload_budget). Stacked, the
# file binding's whole request path must run on the stored declaration:
#
#   * the stored declaration holds the file parameters as the operation declares
#     them, so check_against and assemble see them;
#   * a call with files, in a fresh process (a CGI is one), through the REAL
#     vendored oomd, is answered by the daemon on the stored declaration, and the
#     endpoint's budget for the body is read from it too - none of Registry,
#     Service or Odoo::Client is in %INC;
#   * the stored file declaration is what is believed while its stamp holds (a
#     lowered max_bytes refuses the binding's cap);
#   * an operation named with a hyphen (SM1178) is found by its stored declaration.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Odoo::Decl ();
use Lazysite::Daemon::Service::Oomd ();

my $root  = repo_root();
my $state = oomd_env();
my $d     = oomd_site();
$Lazysite::Odoo::DOCROOT = $d;

bind( $d, id => 'filed', operation => 'test.file', modes => 'public',
    file_params => 'one=file,many=files', file_max_kb => 8, file_types => 'image/jpeg,image/png' );

my $decl_file = "$d/lazysite/odoo/decl/filed.json";
sub read_decl { open my $fh, '<', $decl_file or return undef; local $/; return JSON::PP::decode_json(<$fh>) }
sub write_decl { my ($x) = @_; open my $fh, '>', $decl_file or die $!; print {$fh} JSON::PP->new->canonical->encode($x); close $fh }
sub last_call { my $r = Lazysite::Odoo::read_calls() || []; return $r->[0] }

my $MARK = 'MARKER-4a91c2-stored-decl';
my $JPEG = "\xFF\xD8\xFF\xE0$MARK" . ( 'j' x 400 );
my $PNG  = "\x89PNG\r\n\x1a\n$MARK" . ( 'p' x 400 );

# The child: the endpoint's budget and one call with files, in a fresh perl, and
# what it loaded.
my $script = "$d/child-file-call.pl";
{
    open my $fh, '>', $script or die $!;
    print {$fh} <<'PERL';
use strict; use warnings; no warnings 'once';
use lib $ENV{T_REPO} . '/lib';
use JSON::PP;
require Lazysite::Odoo;
$Lazysite::Odoo::DOCROOT = $ENV{T_DOCROOT};
my $jpeg = pack 'H*', $ENV{T_JPEG};
my $png  = pack 'H*', $ENV{T_PNG};
my ($b) = Lazysite::Odoo::find_binding('filed');
my ( $cap, $n ) = Lazysite::Odoo::upload_budget($b);
my $r = Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.7', files => {
        one  => [ { name => 'receipt.jpg', bytes => $jpeg, claimed => 'image/jpeg' } ],
        many => [ { name => 'a.png', bytes => $png } ] } );
my @loaded = sort grep { m{\AOdoo/} } keys %INC;
print encode_json( { ok => $r->{ok} ? 1 : 0, kind => $r->{kind}, error => $r->{error},
    rows => $r->{report}{rows}, via => Lazysite::Odoo::last_via(), cap => $cap, n => $n,
    loaded => { map { $_ => 1 } @loaded } } ), "\n";
PERL
    close $fh;
}
sub child {
    local $ENV{T_REPO}    = $root;
    local $ENV{T_DOCROOT} = $d;
    local $ENV{T_JPEG}    = unpack 'H*', $JPEG;
    local $ENV{T_PNG}     = unpack 'H*', $PNG;
    open my $ph, '-|', $^X, $script or die $!;
    my $out = do { local $/; <$ph> };
    close $ph;
    my $r = eval { JSON::PP::decode_json($out) } or do { diag "child said: $out"; return {} };
    return $r;
}
my @FORBIDDEN = qw(Odoo/Ops/Registry.pm Odoo/Ops/Service.pm Odoo/Client.pm);
sub loads_oom { my ($r) = @_; return grep { $r->{loaded}{$_} } @FORBIDDEN }

subtest 'the stored declaration holds the operation\'s file parameters' => sub {
    my $x = read_decl();
    ok( $x, 'lazysite/odoo/decl/filed.json exists' ) or return;
    is( $x->{params}{file}{type},       'file',   'the one-file parameter, as a file' );
    is( $x->{params}{file}{max_bytes},  100_000,  'with its max_bytes' );
    is( $x->{params}{files}{type},      'files',  'the list, as files' );
    is( $x->{params}{files}{max},       10,       'with its max' );
    is( $x->{params}{files}{max_bytes}, 100_000,  'and its max_bytes' );
};

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'a file call through oomd runs on the stored declaration and loads no OOM' => sub {
    my $r = child();
    ok( $r->{ok}, 'the call is answered' ) or diag explain $r;
    is( $r->{via}, 'daemon', 'by the daemon' );
    is( last_call()->{decl}, 'stored', 'on the stored declaration' );
    is_deeply( [ map { $_->{seen} } @{ $r->{rows} || [] } ], [ sha256_hex($JPEG), sha256_hex($PNG) ],
        'the operation in the daemon saw both files\' bytes' );
    is_deeply( [ map { $_->{mimetype} } @{ $r->{rows} || [] } ], [qw(image/jpeg image/png)],
        'with the type read from the bytes' );
    is( $r->{cap}, 8 * 1024, 'the endpoint\'s budget: the binding\'s cap on one file' );
    is( $r->{n},   11,       'and the count from the stored declaration (one file, a list of at most 10)' );
    is_deeply( [ loads_oom($r) ], [], 'none of Registry, Service, Odoo::Client is in %INC' )
        or diag join ', ', sort keys %{ $r->{loaded} };
    note 'Odoo modules loaded: ' . join( ', ', sort keys %{ $r->{loaded} } );
};

subtest 'the stored file declaration is believed while its stamp holds' => sub {
    my $good = read_decl();
    my $x    = read_decl();
    $x->{params}{file}{max_bytes} = 4096;
    write_decl($x);
    my $r = child();
    ok( !$r->{ok}, 'a stored max_bytes below the binding\'s cap refuses the binding' );
    like( $r->{error} // '', qr/file_max_kb 8 is above the 4096 bytes/, 'naming the stored max_bytes' )
        or diag explain $r;
    write_decl($good);
    ok( child()->{ok}, 'and with the operation\'s own declaration back it is answered again' );
};

oomd_stop($svc);
ok( !oomd_up($d), 'the daemon is stopped' );

subtest 'an operation named with a hyphen is found by its stored declaration' => sub {
    my ($conn) = Lazysite::Odoo::connection();
    ok( $conn && ( $conn->{daemon} // 'off' ) ne 'off', 'the site runs with the daemon on' ) or return;
    my $op = 'shop-page.names';
    my $d0 = Lazysite::Odoo::Decl::capture( 'Hyphen::Op', $op, $conn );
    ok( $d0, 'a declaration is captured for it' ) or return;
    ok( Lazysite::Odoo::Decl::store( Lazysite::Odoo::store_dir(), 'hy', $d0 ), 'and stored' );
    my ( $class, $why, $how ) = Lazysite::Odoo::binding_class( { id => 'hy', operation => $op }, $conn );
    is( $how, 'stored', 'binding_class finds it stored' ) or diag $why;
    ok( $class && $class->params->{limit}, 'with its parameters' );
};

done_testing();

package Hyphen::Op;
sub writes  { 0 }
sub summary { 'a fixture named with a hyphen' }
sub params  { return { limit => { type => 'int', default => 20 } } }

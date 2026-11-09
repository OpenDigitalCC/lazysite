#!/usr/bin/perl
# SM297: THE DATA ENDPOINT IS CONVERTED - ITS IDENTITY IS A VALUE IT HOLDS, NOT
# HEADERS IT WRITES INTO ITS OWN ENVIRONMENT AND READS BACK.
#
# lazysite-data.pl verifies its own caller (request_session). Before SM297 it then
# deleted every X-Remote-* header, wrote the verified user and groups back under the
# fixed names, set the wrapper's sentinel, and let every reader it called - its own,
# the ACL's operator check, the capability gates - read them out of %ENV: a forgeable
# channel inside its own address space. Now it holds the value
# ($Lazysite::Auth::Identity::HELD) and every reader is answered that.
#
#   1. an identity forged in the request (the fixed names and the sentinel) has no
#      effect, for an anonymous caller and for a member;
#   2. an identity written into %ENV in the middle of the request - after the value
#      was decided, as anything the endpoint calls could - has no effect: the reader
#      answers the held value;
#   3. a SABOTAGED copy of the endpoint, with the hold removed (the bypass: back to
#      an unheld identity), is fooled by the same write - so 2 measures the hold;
#   4. ruling 206: a session whose store cannot be read is refused 503, naming the
#      store, never served as anonymous; the log line names it too.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available (the data extension needs them)';
}

my $root = repo_root();
my $d    = site_tempdir();
my $t    = $d =~ s{/[^/]+\z}{}r;

sub spit {
    my ( $p, $s ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $s;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

my $SECRET = 'd' x 64;
spit( "$d/lazysite/lazysite.conf", "site_name: T\nextensions:\n  - extensions/data.pl\n" );
spit( "$d/lazysite/auth/.secret", "$SECRET\n" );
chmod 0600, "$d/lazysite/auth/.secret";
spit( "$d/lazysite/auth/users",  "alice:x\n" );
spit( "$d/lazysite/auth/groups", "staff: alice\n" );
spit( "$d/lazysite/auth/user-settings.json", "{}\n" );
spit( "$d/lazysite/db/tables/products.yaml",
    "public: true\nkey: code\nfields:\n  code:\n    type: text\n    required: true\n" );
{
    local $ENV{DOCUMENT_ROOT} = $d;
    require Lazysite::Data::Tables;
    Lazysite::Data::Tables::apply_schema( $d, 'products' );
    Lazysite::Data::Tables::insert_row( $d, 'products', { code => 'W1' } );
}

# A legacy three-field cookie (user:ts:groups), which verifies without a registry
# entry; the groups baked in are never read (SEC-2026-07 M5).
sub cookie_for {
    my $payload = "$_[0]:" . time() . ':baked';
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
}

# The sabotage: the endpoint with its hold removed.
my $real = "$root/lazysite-data.pl";
my $src  = slurp($real);
( my $bypass = $src ) =~ s/local \$Lazysite::Auth::Identity::HELD = /my \$unheld = /;
isnt( $bypass, $src, 'the sabotage applies: the hold is removed from a copy' );
my $sabotaged = "$t/sabotaged-data.pl";
spit( $sabotaged, $bypass );

# Runs an endpoint's main() in a process of its own, as a CGI runs. When the table is
# resolved - mid-request, after the identity was decided - it writes a forged identity
# into %ENV (the fixed names and the sentinel) and records what the one reader then
# answers, as any module the endpoint calls would ask it.
my $driver = "$t/data-driver.pl";
spit( $driver, <<"PERL" );
use strict;
use warnings;
use lib '$root/lib';
use JSON::PP;
use Lazysite::Auth::Identity ();
require Lazysite::Data::Tables;
my \$seen;
{
    no warnings 'redefine';
    my \$orig = \\&Lazysite::Data::Tables::resolve_binding;
    *Lazysite::Data::Tables::resolve_binding = sub {
        if ( \$ENV{FORGE_MID_REQUEST} ) {
            \$ENV{HTTP_X_REMOTE_USER}    = 'mallory';
            \$ENV{HTTP_X_REMOTE_GROUPS}  = 'admins';
            \$ENV{LAZYSITE_AUTH_TRUSTED} = '1';
        }
        \$seen = Lazysite::Auth::Identity::request_identity( lazysite_dir => "\$ENV{DOCUMENT_ROOT}/lazysite" );
        return \$orig->(\@_);
    };
}
do \$ARGV[0];
die \$@ if \$@;
open my \$save, '>&', \\*STDOUT or die \$!;
close STDOUT;
my \$buf = '';
open STDOUT, '>', \\\$buf or die \$!;
main::main();
close STDOUT;
open STDOUT, '>&', \$save or die \$!;
my (\$st)   = \$buf =~ /Status:\\s*(\\d+)/;
my (\$body) = \$buf =~ /\\r?\\n\\r?\\n(.*)\\z/s;
print JSON::PP->new->canonical->encode(
    { status => \$st // 0, seen => \$seen, body => eval { decode_json( \$body // '' ) } || {} } );
PERL

sub run_endpoint {
    my ( $script, %env ) = @_;
    my $err = "$t/stderr.log";
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
        QUERY_STRING => 'table=products', REMOTE_ADDR => '203.0.113.9', LAZYSITE_LOG_LEVEL => 'WARN', %env );
    my $out = qx(\Q$^X\E \Q$driver\E \Q$script\E 2>\Q$err\E);
    my $r = eval { decode_json($out) } || { status => 0, raw => $out };
    $r->{stderr} = slurp($err);
    return $r;
}

my %FORGED = ( HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins', LAZYSITE_AUTH_TRUSTED => '1' );

subtest 'an identity forged in the request has no effect' => sub {
    my $anon = run_endpoint( $real, %FORGED );
    is( $anon->{status}, 200, 'an anonymous caller is answered' ) or diag explain $anon;
    is( $anon->{seen}{user}, '', 'as nobody, though the sentinel and X-Remote-User name someone' );
    is_deeply( $anon->{seen}{groups}, [], 'with no groups' );

    my $mem = run_endpoint( $real, %FORGED, HTTP_COOKIE => cookie_for('alice') );
    is( $mem->{status}, 200, 'a member is answered' ) or diag explain $mem;
    is( $mem->{seen}{user}, 'alice', 'as the member the cookie proves, not the forged name' );
    is_deeply( $mem->{seen}{groups}, ['staff'], 'with the member\'s own groups' );
};

subtest 'an identity written into %ENV mid-request has no effect' => sub {
    my $mem = run_endpoint( $real, FORGE_MID_REQUEST => 1, HTTP_COOKIE => cookie_for('alice') );
    is( $mem->{seen}{user}, 'alice', 'a member stays the member: the reader answers the held value' )
        or diag explain $mem;
    is_deeply( $mem->{seen}{groups}, ['staff'], 'and the forged groups grant nothing' );

    my $anon = run_endpoint( $real, FORGE_MID_REQUEST => 1 );
    is( $anon->{seen}{user}, '', 'nobody stays nobody' ) or diag explain $anon;
};

subtest 'SABOTAGE: without the hold, the same write is believed' => sub {
    my $mem = run_endpoint( $sabotaged, FORGE_MID_REQUEST => 1, HTTP_COOKIE => cookie_for('alice') );
    is( $mem->{seen}{user}, 'mallory', 'the bypassed endpoint\'s readers take the forged identity' )
        or diag( 'If this is alice, the test above does not measure the hold. ' . explain $mem );
    my $anon = run_endpoint( $sabotaged, FORGE_MID_REQUEST => 1 );
    is( $anon->{seen}{user}, 'mallory', 'and an anonymous caller becomes the forged one' )
        or diag explain $anon;
};

subtest 'ruling 206: a session store that cannot be read is refused, never anonymous' => sub {
    my $store = "$d/lazysite/auth/user-settings.json";
    my $kept  = slurp($store);
    spit( $store, '{ not json' );
    my $r = run_endpoint( $real, HTTP_COOKIE => cookie_for('alice') );
    spit( $store, $kept );
    is( $r->{status}, 503, 'a 503, not the anonymous 200' ) or diag explain $r;
    is( $r->{body}{kind}, 'cannot-tell', 'the refusal says who is calling cannot be told' );
    like( $r->{body}{error} // '', qr{lazysite/auth/user-settings\.json}, 'and names the store to repair' );
    ok( !$r->{body}{rows}, 'no rows are served' );
    ok( !defined $r->{seen}, 'nothing downstream ran' );
    like( $r->{stderr}, qr/cannot tell.*user-settings\.json/i, 'the log line names the store too' )
        or diag( $r->{stderr} );

    my $ok = run_endpoint( $real, HTTP_COOKIE => cookie_for('alice') );
    is( $ok->{status}, 200, 'repaired, the same cookie is served again' );
};

done_testing();

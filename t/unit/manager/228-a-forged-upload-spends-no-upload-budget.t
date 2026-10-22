#!/usr/bin/perl
# upload-budget (SM944 S34 finding F-1, built for review 2026-10-11): A FORGED
# UPLOAD SPENDS NOTHING OF THE ACCOUNT'S HOURLY UPLOAD BUDGET.
#
# file-upload's rate check reserves a slot as it checks, and it ran in the body
# read, before the CSRF gate. A cross-site POST from a signed-in manager's
# browser was refused 403 and still spent one: after one genuine upload, 59
# forged POSTs answered 403, the 60th 429, and the manager's next genuine upload
# was refused 429 for the rest of the hour
# (tmp/sm944-s34-f1-upload-rate-probe.out). The check now runs at the dispatch
# branch, after every gate.
#
# The default budget (60 an hour) is used as it ships. The sequence: a forged
# POST before any upload writes no rate store; one genuine upload; 59 forged
# POSTs, each refused 403; a genuine upload is answered 200; 58 more genuine
# uploads are answered 200 (60 in all); the 61st genuine upload is refused 429,
# which is the limit unchanged for a genuine caller.
#
# The budget and the CSRF token are both keyed on the hour. A run that crosses
# the hour is run again once on a fresh site; a run of this length cannot cross
# two.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3  qw(open3);
use File::Path  qw(make_path);
use TestHelper  qw(repo_root site_tempdir grant_caps run_child);

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";
plan skip_all => 'manager api missing' unless -f $mapi;
plan skip_all => 'DB_File missing: the upload budget fails open without it'
    unless eval { require DB_File; 1 };
my $secret = 'c' x 64;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub new_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\nmanager_groups: managers\n" );
    spit( "$d/lazysite/auth/.secret", $secret );
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'add', username => 'admin', password => 'pw-admin-0123456789' } ), stderr => 'merge' )->{out};
    grant_caps( $d, 'admin', 'manage_users', 'ui', 'manage_content' ); # SM1057: writes content in the manager
    return $d;
}

# A cookie session's multipart POST of file-upload, as the auth wrapper vouches
# for it; with this hour's token for the account when $genuine, with none when
# not (a cross-site form cannot read the token).
sub upload {
    my ( $d, $genuine, $n ) = @_;
    my $b = 'B0und';
    my $body = "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u$n.txt\"\r\n"
        . "Content-Type: text/plain\r\n\r\nhello\r\n--$b--\r\n";
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION HTTP_X_CSRF_TOKEN HTTP_COOKIE)};
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = 'POST';
    $ENV{QUERY_STRING}          = 'action=file-upload&path=/';
    $ENV{CONTENT_TYPE}          = "multipart/form-data; boundary=$b";
    $ENV{CONTENT_LENGTH}        = length $body;
    $ENV{HTTP_X_REMOTE_USER}    = 'admin';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( 'csrf:admin:' . int( time() / 3600 ), $secret ) if $genuine;
    my $out = run_child( [ $^X, $mapi ], stdin => $body, stderr => 'merge' )->{out};
    my ($status) = $out =~ /^Status:\s*(\d+)/m;
    my ($jb)     = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 200, eval { decode_json( $jb // '' ) } // {} );
}

# The sequence, its answers tallied. Returns the tallies and whether the hour
# held from the first request to the last.
sub run_sequence {
    my $hour = int( time() / 3600 );
    my $d    = new_site();
    my %t;
    my ( $st, $res ) = upload( $d, 0, 0 );
    $t{first_forged}  = $st;
    $t{store_after_1} = -e "$d/lazysite/manager/.upload-rate.db" ? 1 : 0;
    ( $t{genuine_1} ) = upload( $d, 1, 1 );
    my %forged;
    for my $i ( 1 .. 59 ) {
        my ( $s, $r ) = upload( $d, 0, 100 + $i );
        $forged{ $s . ' ' . ( $r->{error} // '' ) }++;
    }
    $t{forged} = \%forged;
    ( $t{genuine_2}, $t{genuine_2_res} ) = upload( $d, 1, 2 );
    my %genuine;
    for my $i ( 3 .. 60 ) {
        my ($s) = upload( $d, 1, $i );
        $genuine{$s}++;
    }
    $t{genuine_3_60} = \%genuine;
    ( $t{genuine_61}, $t{genuine_61_res} ) = upload( $d, 1, 61 );
    $t{saved}        = scalar grep { -f "$d/u$_.txt" } 1 .. 61;
    $t{forged_saved} = scalar grep { -f "$d/u$_.txt" } 0, 101 .. 159;
    return ( \%t, $hour == int( time() / 3600 ) );
}

my ( $t, $held ) = run_sequence();
( $t, $held ) = run_sequence() unless $held;
ok( $held, 'the sequence ran within one hour' );

is( $t->{first_forged},  403, 'a forged upload before any genuine one is refused 403' );
is( $t->{store_after_1}, 0,   '...and writes no upload rate store' );
is( $t->{genuine_1},     200, 'a genuine upload is answered 200' );
is_deeply( $t->{forged}, { '403 Invalid or missing CSRF token' => 59 },
    '59 forged uploads are each refused 403 by the CSRF gate, none 429' )
    or diag explain $t->{forged};
is( $t->{genuine_2}, 200, 'a genuine upload after them is answered 200: they spent no slot' )
    or diag explain $t->{genuine_2_res};
is_deeply( $t->{genuine_3_60}, { 200 => 58 }, 'genuine uploads 3 to 60 are each answered 200' )
    or diag explain $t->{genuine_3_60};
is( $t->{genuine_61}, 429, 'the 61st genuine upload of the hour is refused 429' );
is( $t->{genuine_61_res}{kind} // '', 'rate', '...as a rate refusal' );
is( $t->{genuine_61_res}{error} // '', 'Upload rate limit reached (60 per hour)', '...naming the limit' );
is( $t->{saved},        60, 'the 60 genuine uploads landed and the 61st did not' );
is( $t->{forged_saved}, 0,  'no forged upload landed' );

done_testing();

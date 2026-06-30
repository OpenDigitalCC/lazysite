#!/usr/bin/perl
# SM071 Phase 3 (P3.6): control-API per-token throttle (429 + Retry-After).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mscript = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return decode_json($out);
}
# Return the raw CGI output so we can read Status + headers.
sub mraw {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{CONTENT_LENGTH} = 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mscript );
    close $w;
    my $out = do { local $/; <$r> }; close $e; waitpid $pid, 0;
    return $out;
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/layouts/base/themes/live");
open my $cf, '>', "$d/lazysite/lazysite.conf"; print $cf "layout: base\ntheme: live\n"; close $cf;
open my $tj, '>', "$d/lazysite/layouts/base/themes/live/theme.json";
print $tj '{"name":"live","layouts":["base"]}'; close $tj;
uapi( $d, { action => 'add', username => 'p', password => 'x' } );
grant_caps( $d, 'p', 'manage_themes' );
my $tok = uapi( $d, { action => 'token', username => 'p' } )->{token};
my $auth = 'Basic ' . encode_base64( "p:$tok", '' );

my %rate = ( LAZYSITE_RATE_BURST => 1, LAZYSITE_RATE_REFILL => 0 );
my $q = 'action=artifact-manifest&layout=base&theme=live';

my $first = mraw( $d, QUERY_STRING => $q, HTTP_AUTHORIZATION => $auth, %rate );
like( $first, qr/Status:\s*200/, 'first control-API call ok' );

my $second = mraw( $d, QUERY_STRING => $q, HTTP_AUTHORIZATION => $auth, %rate );
like( $second, qr/Status:\s*429/, 'second call throttled (429)' );
like( $second, qr/Retry-After:\s*\d+/, '429 carries Retry-After' );

done_testing();

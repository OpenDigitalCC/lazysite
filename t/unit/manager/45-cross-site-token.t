#!/usr/bin/perl
# ADVERSARIAL / tenant isolation (breadth pass 0.8.1): a control-API token is a
# credential in ONE site's auth store (lazysite/auth, per docroot). It must never
# authenticate against a DIFFERENT site's docroot - otherwise a partner on site A
# could drive site B. Verification is per-docroot by construction (each site has
# its own .secret + credential store), so a token minted on A simply does not
# exist on B; this test pins that structural property end-to-end across two
# independent docroots, on the token channel.
use strict;
use warnings;
use Test::More;
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2   qw(open2);
use IPC::Open3   qw(open3);
use Symbol       qw(gensym);
use File::Path   qw(make_path);
use File::Temp   qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

# A token control-API call against docroot $d.
sub mapi {
    my ( $d, $user, $tok, $qs ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'GET';
    $ENV{QUERY_STRING}       = $qs;
    $ENV{CONTENT_LENGTH}     = 0;
    $ENV{HTTP_AUTHORIZATION} = basic( $user, $tok );
    delete $ENV{HTTP_X_REMOTE_USER};
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

# Build a secured site with an api-capable partner and mint its token.
sub make_site {
    my ($name) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: $name\n";
    close $cf;
    uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
    grant_caps( $d, 'partner', 'api', 'manage_content' );
    my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
    return ( $d, $tok );
}

my ( $siteA, $tokA ) = make_site('A');
my ( $siteB, $tokB ) = make_site('B');
ok( $tokA && $tokA =~ /^lzs_/, "site A minted a partner token" );
ok( $tokB && $tokB =~ /^lzs_/, "site B minted a partner token" );
isnt( $tokA, $tokB, "the two sites' tokens differ" );

# --- control: A's token works on A -------------------------------------------
my $onA = mapi( $siteA, 'partner', $tokA, 'action=whoami' );
ok( $onA->{ok}, "site A token authenticates on site A" );

# --- the isolation property: A's token is REJECTED on site B -----------------
my $cross = mapi( $siteB, 'partner', $tokA, 'action=whoami' );
ok( !$cross->{ok}, "site A token is REJECTED on site B (no cross-site auth)" );
like( $cross->{error} // '', qr/invalid credentials/i,
    "  ... refused as invalid credentials, not merely capability-denied" );

# --- and symmetrically, B's token is rejected on A ---------------------------
my $cross2 = mapi( $siteA, 'partner', $tokB, 'action=whoami' );
ok( !$cross2->{ok}, "site B token is rejected on site A" );

# --- a forged/again-different token is rejected too (sanity) -----------------
my $forged = mapi( $siteB, 'partner', 'lzs_deadbeefdeadbeefdeadbeef', 'action=whoami' );
ok( !$forged->{ok}, "a made-up token is rejected on site B" );

done_testing();

#!/usr/bin/perl
# config-set over the token control API: an allowlisted key writes
# lazysite.conf; a privilege-relevant key is refused; manage_config gates it.
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

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }
sub conf  { open my $f, '<', "$_[0]/lazysite/lazysite.conf" or die $!; local $/; <$f> }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: My Site\n"; close $cf;

uapi( $d, { action => 'add', username => 'p', password => 'x' } );
grant_caps( $d, 'p', 'manage_config', 'api' );   # SM126: token client holds the api channel cap
my $tok = uapi( $d, { action => 'token', username => 'p' } )->{token};
ok( $tok && $tok =~ /^lzs_/, 'minted a manage_config token' );

# allowed key writes the conf
my $ok = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'site_name', value => 'The Barn by the Ford' } ) );
ok( $ok->{ok}, 'config-set site_name succeeds with manage_config' );
like( conf($d), qr/^site_name: The Barn by the Ford$/m, 'lazysite.conf updated in place' );

# privilege-relevant key refused, and not written
my $bad = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'manager_groups', value => 'pwn' } ) );
ok( !$bad->{ok}, 'a privilege-relevant key is refused' );
unlike( conf($d), qr/manager_groups: pwn/, 'refused key is not written' );

# update_channel accepts the full ladder (field finding: only all/stable were
# selectable), plus 'edge' as the CLI-vocabulary synonym of 'all'; junk refused.
for my $ch (qw(all edge beta stable)) {
    my $c = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'p', $tok ),
        body => encode_json( { key => 'update_channel', value => $ch } ) );
    ok( $c->{ok}, "config-set update_channel accepts '$ch'" ) or diag $c->{error};
}
like( conf($d), qr/^update_channel: stable$/m, 'last channel value written' );
my $badch = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'update_channel', value => 'nightly' } ) );
ok( !$badch->{ok}, 'an unknown channel is refused' );

# SM156: canonical_ip - a comma list of IP literals; may be CLEARED (empty =
# auto-detect); a hostname / junk is refused; config-read surfaces it.
my $cip = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'canonical_ip', value => '2.59.188.206, 2606:4700::1' } ) );
ok( $cip->{ok}, 'config-set canonical_ip accepts comma-separated IPs' ) or diag $cip->{error};
like( conf($d), qr/^canonical_ip: 2\.59\.188\.206, 2606:4700::1$/m, 'canonical_ip written' );

my $cread = mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=config-read',
    HTTP_AUTHORIZATION => basic( 'p', $tok ) );
is( $cread->{config}{canonical_ip}, '2.59.188.206, 2606:4700::1',
    'config-read surfaces canonical_ip for the panel' );

my $cipbad = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'canonical_ip', value => 'evil.example.com' } ) );
ok( !$cipbad->{ok}, 'a hostname is refused as canonical_ip (IP literals only)' );

my $cipclear = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'p', $tok ),
    body => encode_json( { key => 'canonical_ip', value => '' } ) );
ok( $cipclear->{ok}, 'canonical_ip may be cleared (empty = auto-detect)' ) or diag $cipclear->{error};
like( conf($d), qr/^canonical_ip:\s*$/m, 'cleared canonical_ip is written empty' );

# without manage_config the capability gate refuses it
uapi( $d, { action => 'add', username => 'q', password => 'x' } );
my $tok2 = uapi( $d, { action => 'token', username => 'q' } )->{token};
my $nocap = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'q', $tok2 ),
    body => encode_json( { key => 'site_name', value => 'x' } ) );
ok( !$nocap->{ok} && ( $nocap->{error} // '' ) =~ /capabilit/i,
    'config-set requires the manage_config capability' );

# --- SM128: bad-url-blocks / bad-url-unblock over the control API ------------
make_path("$d/lazysite/cache");
open my $bf, '>', "$d/lazysite/cache/bad-url-blocked.json" or die $!;
print $bf encode_json( { '203.0.113.9' => { since => time(), count => 12, path => '/.env' } } );
close $bf;

my $bl = mapi( $d, QUERY_STRING => 'action=bad-url-blocks', HTTP_AUTHORIZATION => basic( 'p', $tok ) );
ok( $bl->{ok} && $bl->{blocks}{'203.0.113.9'}, 'bad-url-blocks lists the blocked IP (manage_config)' );

my $ub = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=bad-url-unblock&ip=203.0.113.9',
    HTTP_AUTHORIZATION => basic( 'p', $tok ) );
ok( $ub->{ok} && $ub->{removed}, 'bad-url-unblock removes the IP' );

my $bl2 = mapi( $d, QUERY_STRING => 'action=bad-url-blocks', HTTP_AUTHORIZATION => basic( 'p', $tok ) );
ok( !$bl2->{blocks}{'203.0.113.9'}, 'the IP is gone after unblock' );

my $bl_nc = mapi( $d, QUERY_STRING => 'action=bad-url-blocks', HTTP_AUTHORIZATION => basic( 'q', $tok2 ) );
ok( !$bl_nc->{ok} && ( $bl_nc->{error} // '' ) =~ /capabilit/i,
    'bad-url-blocks requires manage_config' );

done_testing();

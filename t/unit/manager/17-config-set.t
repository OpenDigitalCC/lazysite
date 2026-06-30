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
grant_caps( $d, 'p', 'manage_config' );
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

# without manage_config the capability gate refuses it
uapi( $d, { action => 'add', username => 'q', password => 'x' } );
my $tok2 = uapi( $d, { action => 'token', username => 'q' } )->{token};
my $nocap = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
    HTTP_AUTHORIZATION => basic( 'q', $tok2 ),
    body => encode_json( { key => 'site_name', value => 'x' } ) );
ok( !$nocap->{ok} && ( $nocap->{error} // '' ) =~ /capabilit/i,
    'config-set requires the manage_config capability' );

done_testing();

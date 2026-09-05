#!/usr/bin/perl
# SM724 at the door: a sign-in with no destination lands on the account's start
# page; an explicit next still wins; unset lands on the manager with the
# account sheet open; a start page that stopped being reachable lands there
# too, flagged, rather than on a refusal.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps revoke_caps env_passthrough);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print {$cin} encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}
sub run_auth {
    my ( $env, $body ) = @_;
    $body //= '';
    local %ENV = ( env_passthrough(), %$env, CONTENT_LENGTH => length($body),
        CONTENT_TYPE => 'application/x-www-form-urlencoded', LAZYSITE_USERS_TOOL => $utl );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print {$wtr} $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $pid, 0;
    return $out // '';
}

my $t = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $d = "$t/site/public_html";
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/sites/shop" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Test\nsite_url: https://main.example\nmanager: enabled\nalias_hosts: shop.example\nalias.shop.example.content_root: sites/shop\n";
close $cf;
users_api( $d, { action => 'add', username => 'ed', password => 'pw' } );
grant_caps( $d, 'ed', qw(ui manage_content) );

my %base = ( DOCUMENT_ROOT => $d, REMOTE_ADDR => '127.0.0.1', HTTPS => '' );
my $ip = 10; # a fresh source address per sign-in: the per-IP login limiter (H-3) is not the subject here
sub login {
    my ( $user, $next ) = @_;
    $ip++;
    return run_auth( { %base, REMOTE_ADDR => "10.0.0.$ip", REQUEST_METHOD => 'POST', QUERY_STRING => 'action=login' }, "username=$user&password=pw&next=$next" );
}
sub location { my ($out) = @_; my ($l) = $out =~ /Location:\s*(\S+)/; return $l // '(none)' }

is( location( login( 'ed', q{/} ) ), '/manager/?account=1', 'unset: the manager with the account sheet open' );
is( location( login( 'ed', '/about' ) ), '/about', 'an explicit next wins, as before' );

users_api( $d, { action => 'settings-set', username => 'ed', key => 'start_page', value => 'manager:files', actor => 'ed' } );
is( location( login( 'ed', q{/} ) ), '/manager/files', 'set to a manager page: lands there' );
is( location( login( 'ed', '/about' ) ), '/about', 'and an explicit next STILL wins over the start page' );

users_api( $d, { action => 'settings-set', username => 'ed', key => 'start_page', value => 'domain:shop.example|/catalogue', actor => 'ed' } );
is( location( login( 'ed', q{/} ) ), 'https://shop.example/catalogue', 'set to a page on another host this instance serves: an absolute URL there' );

users_api( $d, { action => 'settings-set', username => 'ed', key => 'start_page', value => 'manager:files', actor => 'ed' } );
revoke_caps( $d, 'ed', 'manage_content' );
is( location( login( 'ed', q{/} ) ), '/manager/?account=1&start=unreachable',
    'the grant went away after the choice: the fallback, flagged - not a 403 at every sign-in' );

done_testing;

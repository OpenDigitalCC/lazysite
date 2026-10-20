#!/usr/bin/perl
# SM1209 (0.15.13 edge walk, H-1): config-set read a stored key whose line is
# PRESENT BUT EMPTY (`app_scope:`, how a cleared key is left) as the whole next line,
# so on a conf with every app_* line stored empty, app_scope read as 'app_start_url:'
# and no app_scope or app_offline_pages could be saved. This builds that conf and
# saves through the real config-set.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir setup_test_site);

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
sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $o, '>', $path or die "$path: $!";
    print {$o} $text;
    close $o;
}

my $d = site_tempdir();
setup_test_site($d);
# The conf as the edge walk found it: every app_* line present and empty.
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\n";
print $cf "app_name:\napp_scope:\napp_start_url:\napp_icon_192:\napp_offline_pages:\napp_update:\n";
close $cf;
put( "$d/assets/$_", "/* $_ */\n" ) for qw(lazysite-chrome.css lazysite-chrome.js lazysite-app.js);
put( "$d/zz/a.md", "---\ntitle: A\n---\nA.\n" );
put( "$d/zz/g.md", "---\ntitle: G\nauth: required\n---\nG.\n" );

uapi( $d, { action => 'add', username => 'p', password => 'x-long-enough' } );
grant_caps( $d, 'p', 'manage_config', 'api' );
my $tok = uapi( $d, { action => 'token', username => 'p' } )->{token};
ok( $tok && $tok =~ /^lzs_/, 'minted a manage_config token' );

sub set {
    my ( $k, $v ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=config-set',
        HTTP_AUTHORIZATION => basic( 'p', $tok ),
        body               => encode_json( { key => $k, value => $v } ) );
}

my $r = set( app_scope => '/zz/' );
ok( $r->{ok}, 'app_scope saves with app_start_url stored empty' ) or diag explain $r;
like( conf($d), qr{^app_scope: /zz/$}m, '... and is written' );

$r = set( app_offline_pages => '/zz/a' );
ok( $r->{ok}, 'app_offline_pages saves with the other app lines stored empty' ) or diag explain $r;
like( conf($d), qr{^app_offline_pages: /zz/a$}m, '... and is written' );

$r = set( app_offline_pages => '/zz/a, /zz/g' );
ok( !$r->{ok}, 'a gated page is still refused' );
like( $r->{error} // '', qr{/zz/g},   '... naming the page' );
like( $r->{error} // '', qr{sign-in}, '... and the reason' );

$r = set( app_offline_pages => '/zz/a, /manager/' );
ok( !$r->{ok}, '/manager/ is still refused' );
like( $r->{error} // '', qr{/manager/}, '... naming the page' );
like( $r->{error} // '', qr{manager}i,  '... and the reason' );

$r = set( app_start_url => '/zz/a' );
ok( $r->{ok}, 'a start page inside the stored scope saves' ) or diag explain $r;
$r = set( app_start_url => '/elsewhere' );
ok( !$r->{ok}, 'a start page outside it is refused' );
like( $r->{error} // '', qr{app_scope \(/zz/\)}, '... naming the stored scope, not the next line' );
$r = set( app_scope => '/yy/' );
ok( !$r->{ok}, 'a scope that strands the stored start page is refused' );

done_testing;

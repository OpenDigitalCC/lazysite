#!/usr/bin/perl
# SM1266 (ruled 2026-10-22, #2): SM1174's page key for every feature a page may
# ask for. `geolocation: self` is accepted like `camera: self`; the validator
# names a value other than self or none (`permission-unreadable`) and a key that
# says self and is no feature a page can ask for (`permission-unknown`); and
# page_status lists the features a page allows, with the https condition. The
# camera keeps SM1174's own kind and fields.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
spit( "$d/clock.md", "---\ntitle: Clock\ngeolocation: self\ncamera: self\n---\nC\n" );
spit( "$d/plain.md", "---\ntitle: Plain\n---\nP\n" );
spit( "$d/typo.md",  "---\ntitle: Typo\ngeolocaton: self\n---\nP\n" );
my $stub = "$d/users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_content => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $body,
        LAZYSITE_USERS_TOOL => $stub, LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION => 'Bearer tester:lzs_tok' );
    open my $e, '>', "$d/stderr.log" or die $!;
    my $pid = open3( my $in, my $out, '>&' . fileno($e), $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no answer' };
}
sub kinds { my ($r) = @_; return [ sort map { $_->{kind} // '' } @{ $r->{issues} || [] } ] }
sub page  { my ($fm) = @_; return mcp( validate_page => { content => "---\ntitle: T\n$fm---\nB\n" } ) }

subtest 'page_status lists the features a page allows, and only for that page' => sub {
    my $r = mcp( page_status => { path => '/clock' } );
    ok( $r->{ok}, 'page_status answers' ) or diag explain $r;
    is_deeply( $r->{permissions}, [qw(camera geolocation)], 'camera and geolocation, in the policy order' );
    like( $r->{permissions_note}, qr/geolocation=\(self\)/, 'the note names what is sent' );
    like( $r->{permissions_note}, qr/https/,                '...that it is https only' );
    like( $r->{permissions_note}, qr/plain http/,           '...and what plain http does' );
    is( $r->{camera}, 'self', "the camera's own SM1174 field is kept" );
    for my $p (qw(/plain /typo)) {
        my $o = mcp( page_status => { path => $p } );
        ok( !exists $o->{permissions} && !exists $o->{permissions_note}, "$p: no permissions in its status" );
    }
};

subtest 'self and none are accepted for every feature a page may ask for' => sub {
    for my $f (qw(geolocation microphone accelerometer browsing-topics display-capture gyroscope
        magnetometer midi usb xr-spatial-tracking)) {
        for my $v (qw(self none 'self' "none")) {
            is_deeply( kinds( page("$f: $v\n") ), [], "$f: $v - no issue" );
        }
    }
};

subtest 'any other value is permission-unreadable, naming the key' => sub {
    for my $v ( '*', 'https://x', 'Self', '(self)', '' ) {
        my $r = page("geolocation: $v\n");
        my ($i) = grep { ( $_->{kind} // '' ) eq 'permission-unreadable' } @{ $r->{issues} || [] };
        ok( $i, "geolocation: '$v' is an issue" ) or diag explain $r;
        is( $i->{key}, 'geolocation', '...keyed by the feature' );
        like( $i->{message} // '', qr/geolocation=\(\)/, '...saying the page keeps it denied' );
        like( $i->{message} // '', qr/geolocation: self/, '...and what to write' );
        ok( !$r->{valid}, '...so the page is not valid' );
    }
    my $twice = page("microphone: self\nmicrophone: self\n");
    is_deeply( kinds($twice), ['permission-unreadable'], 'given twice is an issue too' );
};

subtest 'a key that says self and is no feature a page can ask for is permission-unknown' => sub {
    for my $k (qw(geolocaton bluetooth fullscreen Camera)) {
        my $r = page("$k: self\n");
        my ($i) = grep { ( $_->{kind} // '' ) eq 'permission-unknown' } @{ $r->{issues} || [] };
        ok( $i, "$k: self is an issue" ) or diag explain $r;
        like( $i->{message} // '', qr/grants nothing/, '...saying it grants nothing' );
        like( $i->{message} // '', qr/geolocation, gyroscope/, '...and naming the features there are' );
    }
    is_deeply( kinds( mcp( validate_page => { path => '/typo' } ) ), ['permission-unknown'], 'a saved page alike' );
    is_deeply( kinds( page("tagline: myself\n") ), [], 'a value that is not self is any other key' );
    ok( !( grep { $_ eq 'permission-unknown' } @{ kinds( page("payment: self\n") ) } ),
        'payment: self is the access key reader\'s to report, not this' );
};

subtest 'the camera keeps its SM1174 kind' => sub {
    is_deeply( kinds( page("camera: *\n") ), ['camera-unreadable'], 'camera: * is camera-unreadable' );
};

done_testing;

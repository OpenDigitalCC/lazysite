#!/usr/bin/perl
# SM1174 (L-16): `camera: self` in a page's front matter is the ONLY accepted
# value besides absent and `none`. The validator names anything else
# (`camera: *`, `camera: https://x`), and page_status shows "camera allowed on
# this page" for a page that has it - and says it is https only.
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
make_path( "$d/lazysite/auth" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
spit( "$d/scan.md",  "---\ntitle: Scan\ncamera: self\n---\nS\n" );
spit( "$d/plain.md", "---\ntitle: Plain\n---\nP\n" );
spit( "$d/none.md",  "---\ntitle: None\ncamera: none\n---\nP\n" );
spit( "$d/star.md",  "---\ntitle: Star\ncamera: *\n---\nP\n" );
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

subtest 'page_status shows a camera page, and only that page' => sub {
    my $r = mcp( page_status => { path => '/scan' } );
    ok( $r->{ok}, 'page_status answers' ) or diag explain $r;
    is( $r->{camera}, 'self', 'camera: self' );
    like( $r->{camera_note}, qr/camera allowed on this page/, 'says "camera allowed on this page"' );
    like( $r->{camera_note}, qr/https/, '...and that it is https only' );
    like( $r->{camera_note}, qr/plain http/, '...and why plain http does not carry it' );
    for my $p (qw(/plain /none)) {
        my $o = mcp( page_status => { path => $p } );
        ok( !exists $o->{camera} && !exists $o->{camera_note}, "$p: no camera in its status" );
    }
};

subtest 'the validator accepts self and none, and names any other value' => sub {
    for my $p (qw(/scan /plain /none)) {
        my $r = mcp( validate_page => { path => $p } );
        ok( !( grep { ( $_->{kind} // '' ) eq 'camera-unreadable' } @{ $r->{issues} || [] } ), "$p: no camera issue" )
            or diag explain $r;
    }
    for my $bad ( [ '*', '/star' ], [ 'https://x', undef ], [ 'Self', undef ], [ '', undef ] ) {
        my ( $v, $p ) = @$bad;
        my $content = "---\ntitle: T\ncamera: $v\n---\nB\n";
        my $r = $p ? mcp( validate_page => { path => $p } ) : mcp( validate_page => { content => $content } );
        my ($i) = grep { ( $_->{kind} // '' ) eq 'camera-unreadable' } @{ $r->{issues} || [] };
        ok( $i, "camera: '$v' is an issue" ) or diag explain $r;
        like( $i->{message} // '', qr/camera/, '...naming the key' );
        like( $i->{message} // '', qr/self/,   '...and the value it takes' );
        ok( !$r->{valid}, '...so the page is not valid' );
    }
};

done_testing;

#!/usr/bin/perl
# SM019: end-to-end tests for the manager file-upload and
# file-download actions. Drives lazysite-manager-api.pl as a
# subprocess with a real multipart body.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IPC::Open2;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
mkdir "$docroot/lazysite" or die $!;
mkdir "$docroot/lazysite/themes" or die $!;
mkdir "$docroot/subdir" or die $!;

sub write_conf {
    my ($body) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $body;
    close $fh;
}
write_conf("site_name: T\n");

sub csrf_token {
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => 'action=csrf-token',
        HTTP_X_REMOTE_USER => 'testmgr',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out)->{token};
}

sub api_get {
    my ( $qs ) = @_;
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => $qs,
        HTTP_X_REMOTE_USER => 'testmgr',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    return $out;
}

sub api_post_multipart {
    my ( $qs, $body, $token, $ctype ) = @_;
    my ( $cout, $cin );
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => $qs,
        CONTENT_TYPE       => $ctype,
        CONTENT_LENGTH     => length($body),
        HTTP_X_REMOTE_USER => 'testmgr',
        HTTP_X_CSRF_TOKEN  => $token,
    );
    # The size gate exits before reading STDIN, so a rejected
    # upload closes our pipe while we are still writing. Ignore
    # SIGPIPE here and tolerate short writes.
    local $SIG{PIPE} = 'IGNORE';
    my $pid = open2( $cout, $cin,
        $^X, "$root/lazysite-manager-api.pl" );
    { no warnings 'closed'; print {$cin} $body; }
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out);
}

sub build_multipart {
    my ( $boundary, @parts ) = @_;
    my $body = '';
    for my $p (@parts) {
        my ( $name, $value, $filename, $ctype ) = @$p;
        $body .= "--$boundary\r\n";
        $body .= qq{Content-Disposition: form-data; name="$name"};
        $body .= qq{; filename="$filename"} if defined $filename;
        $body .= "\r\n";
        $body .= "Content-Type: $ctype\r\n" if defined $ctype;
        $body .= "\r\n";
        $body .= $value;
        $body .= "\r\n";
    }
    $body .= "--$boundary--\r\n";
    return $body;
}

my $BOUNDARY = 'TeStBoUnDaRy123';
my $CTYPE    = "multipart/form-data; boundary=$BOUNDARY";
my $token    = csrf_token();
ok( length($token) == 64, 'csrf token obtained' );

# --- 1. Upload a single text file ---
{
    my $body = build_multipart( $BOUNDARY,
        [ 'overwrite' => '0' ],
        [ 'file' => "hello world\n", 'hello.txt', 'text/plain' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/', $body, $token, $CTYPE );
    is( $r->{ok}, 1, 'upload accepted' ) or diag explain $r;
    is( scalar @{ $r->{saved} // [] }, 1, 'one file saved' );
    ok( -f "$docroot/hello.txt", 'file exists on disk' );
    open my $fh, '<', "$docroot/hello.txt" or die $!;
    is( do { local $/; <$fh> }, "hello world\n", 'file content matches' );
    close $fh;

    # Listing includes the uploaded file
    my $listing = api_get('action=list&path=/');
    like( $listing, qr/hello\.txt/, 'upload visible in list' );
}

# --- 2. Upload into a subdirectory ---
{
    my $body = build_multipart( $BOUNDARY,
        [ 'file' => "sub content\n", 'deep.txt', 'text/plain' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/subdir', $body, $token, $CTYPE );
    is( $r->{ok}, 1, 'subdir upload ok' );
    ok( -f "$docroot/subdir/deep.txt", 'file landed in subdir' );
}

# --- 3. Upload rejected under lazysite/auth prefix ---
{
    mkdir "$docroot/lazysite/auth" unless -d "$docroot/lazysite/auth";
    my $body = build_multipart( $BOUNDARY,
        [ 'file' => "stolen\n", 'secret.txt', 'text/plain' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/lazysite/auth', $body, $token, $CTYPE );
    is( $r->{ok}, 1, 'request processed' );
    is( scalar @{ $r->{saved} // [] }, 0, 'no files saved under auth/' );
    is( scalar @{ $r->{errors} // [] }, 1, 'one error recorded' );
    ok( !-f "$docroot/lazysite/auth/secret.txt",
        'file not written to auth dir' );
}

# --- 4. Upload of a .pl file is rejected by extension ---
{
    my $body = build_multipart( $BOUNDARY,
        [ 'file' => "#!/usr/bin/perl\n", 'evil.pl', 'text/x-perl' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/', $body, $token, $CTYPE );
    is( $r->{ok}, 1, 'request processed' );
    is( scalar @{ $r->{saved} // [] }, 0, 'no .pl saved' );
    ok( !-f "$docroot/evil.pl", '.pl not on disk' );
}

# --- 5. Oversize upload rejected by the size gate ---
{
    write_conf("site_name: T\nmanager_upload_max_mb: 1\n");
    # ~1.5 MB payload (over the 1 MB cap)
    my $big = 'x' x ( 1500 * 1024 );
    my $body = build_multipart( $BOUNDARY,
        [ 'file' => $big, 'big.bin', 'application/octet-stream' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/', $body, $token, $CTYPE );
    is( $r->{ok}, 0, 'oversize upload rejected' );
    like( $r->{error} // '', qr/exceeds limit|too large/i,
        'error mentions limit' );
    ok( !-f "$docroot/big.bin", 'oversize file not written' );
    write_conf("site_name: T\n");  # restore
}

# --- 6. Rate limit: 2 requests then a third rejected ---
{
    write_conf("site_name: T\nmanager_upload_rate_count: 2\n"
             . "manager_upload_rate_mb: 100\n");
    unlink "$docroot/lazysite/manager/.upload-rate.db";

    for my $n ( 1 .. 2 ) {
        my $body = build_multipart( $BOUNDARY,
            [ 'file' => "r$n\n", "rate$n.txt", 'text/plain' ],
        );
        my $r = api_post_multipart(
            'action=file-upload&path=/', $body, $token, $CTYPE );
        is( $r->{ok}, 1, "request $n under rate limit" )
            or diag explain $r;
    }
    my $body = build_multipart( $BOUNDARY,
        [ 'file' => "rX\n", "rate3.txt", 'text/plain' ],
    );
    my $r = api_post_multipart(
        'action=file-upload&path=/', $body, $token, $CTYPE );
    is( $r->{ok}, 0, 'third request rejected by rate limit' );
    like( $r->{error} // '', qr/rate limit|rate/i,
        'error mentions rate' );
    write_conf("site_name: T\n");  # restore
    unlink "$docroot/lazysite/manager/.upload-rate.db";
}

# --- 7. Download a file returns the right headers ---
{
    open my $fh, '>', "$docroot/download-me.md" or die $!;
    print $fh "# hi\n";
    close $fh;
    my $out = api_get('action=file-download&path=/download-me.md');
    like( $out, qr{^Status: 200 OK}m,       '200 status' );
    like( $out, qr{^Content-Type:\s*text/plain}mi,
        'text/plain content-type for .md' );
    like( $out, qr{^Content-Disposition: attachment; filename="download-me\.md"}m,
        'disposition attachment with filename' );
    like( $out, qr/^# hi$/m, 'body included' );
}

# --- 8. Download of a non-existent file returns error ---
{
    my $out = api_get('action=file-download&path=/no-such-file.txt');
    my ($body) = $out =~ /\r?\n\r?\n(.*)\z/s;
    my $r = decode_json($body);
    is( $r->{ok}, 0, 'not-found returns error' );
    like( $r->{error}, qr/not found|File not found/i,
        'error mentions not found' );
}

# --- 9. action_read on a binary file returns {binary:1} ---
{
    # Write a tiny PNG header fixture
    open my $fh, '>', "$docroot/pic.png" or die $!;
    binmode $fh;
    print $fh "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    close $fh;

    my $out = api_get('action=read&path=/pic.png');
    my ($body) = $out =~ /\r?\n\r?\n(.*)\z/s;
    my $r = decode_json($body);
    is( $r->{ok}, 0, 'binary read returns ok=0' );
    is( $r->{binary}, 1, 'binary flag set' );
    ok( !exists $r->{content} || !length( $r->{content} // '' ),
        'no content field populated for binary' );
}

# --- 10. Zip download of two files returns a valid zip ---
SKIP: {
    eval { require Archive::Zip };
    skip 'Archive::Zip unavailable', 2 if $@;

    open my $f1, '>', "$docroot/a.txt" or die $!;
    print $f1 "first\n";
    close $f1;
    open my $f2, '>', "$docroot/b.txt" or die $!;
    print $f2 "second\n";
    close $f2;

    my $raw = api_get('action=file-zip-download&paths=/a.txt&paths=/b.txt');
    my ($headers, $zipbody) = split /\r?\n\r?\n/, $raw, 2;
    like( $headers, qr{Content-Type:\s*application/zip}i,
        'zip content-type' );
    ok( defined $zipbody && substr( $zipbody, 0, 2 ) eq 'PK',
        'body starts with PK zip magic' );
}

# --- 11. Zip download with no selection returns error ---
{
    my $out = api_get('action=file-zip-download');
    my ($body) = $out =~ /\r?\n\r?\n(.*)\z/s;
    my $r = decode_json($body);
    is( $r->{ok}, 0, 'empty selection rejected' );
    like( $r->{error} // '', qr/selected|no files/i, 'error mentions selection' );
}

done_testing();

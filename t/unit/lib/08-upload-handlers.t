#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Upload action handlers
# (action_file_upload / download), previously subprocess-only and unmeasured.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Upload qw(action_file_upload action_file_download);
use Lazysite::Manager::Common ();

my $d = tempdir( CLEANUP => 1 );
make_path("$d/content");
$Lazysite::Manager::Upload::DOCROOT      = $d;
$Lazysite::Manager::Upload::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Common::DOCROOT      = $d;

sub slurp { open my $f, '<', $_[0] or return ''; local $/; <$f> }
sub multipart {
    my ( $boundary, $fname, $data ) = @_;
    return "--$boundary\r\n"
        . qq{Content-Disposition: form-data; name="file"; filename="$fname"\r\n}
        . "\r\n$data\r\n--$boundary--\r\n";
}

# --- action_file_upload ---
my $b = 'xBOUNDARYx';
{
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$b";
    my $r = action_file_upload( 'content', multipart( $b, 'hi.txt', 'hello' ) );
    ok( $r->{ok}, 'upload succeeds' );
    is( slurp("$d/content/hi.txt"), 'hello', 'uploaded content written' );

    # a blocked target (*.pl) is refused per file
    my $r2 = action_file_upload( 'content', multipart( $b, 'evil.pl', 'code' ) );
    ok( ( $r2->{errors} && @{ $r2->{errors} } ) || !$r2->{ok},
        '*.pl target refused' );
    ok( !-f "$d/content/evil.pl", '*.pl not written' );

    # non-multipart body refused
    local $ENV{CONTENT_TYPE} = 'application/json';
    ok( !action_file_upload( 'content', '{}' )->{ok}, 'non-multipart refused' );
}

# --- action_file_download (emits headers + body to STDOUT) ---
sub capture_stdout {
    my ($code) = @_;
    my $buf = '';
    local *STDOUT;
    open STDOUT, '>', \$buf or die;
    $code->();
    close STDOUT;
    return $buf;
}
# The body is sent via syswrite (bypasses the in-memory capture), but the
# headers prove the handler resolved + sized the file correctly.
my $out = capture_stdout( sub { action_file_download('content/hi.txt') } );
like( $out, qr/Status: 200/,                 'download returns 200' );
like( $out, qr/Content-Length: 5/,           'download sizes the 5-byte file' );
like( $out, qr/filename="hi\.txt"/,          'download sets the attachment filename' );

my $miss = capture_stdout( sub { action_file_download('content/nope.txt') } );
like( $miss, qr/404|not found/i,   'missing file downloads as 404' );

done_testing();

#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Upload action handlers.
# Verifies actual effects (bytes on disk, the real download body, specific
# refusal reasons), not just that the handlers ran.
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
make_path( "$d/content", "$d/lazysite/auth" );
$Lazysite::Manager::Upload::DOCROOT      = $d;
$Lazysite::Manager::Upload::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Common::DOCROOT      = $d;

sub slurp { open my $f, '<', $_[0] or return undef; local $/; <$f> }

# Build a multipart body: a file part, plus optional overwrite=1 field.
sub multipart {
    my ( $boundary, $fname, $data, $overwrite ) = @_;
    my $b = '';
    if ($overwrite) {
        $b .= "--$boundary\r\n"
            . qq{Content-Disposition: form-data; name="overwrite"\r\n\r\n1\r\n};
    }
    $b .= "--$boundary\r\n"
        . qq{Content-Disposition: form-data; name="file"; filename="$fname"\r\n}
        . "\r\n$data\r\n--$boundary--\r\n";
    return $b;
}

my $B = 'xBOUNDARYx';
local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$B";

# --- a clean upload writes the exact bytes ---
my $r = action_file_upload( 'content', multipart( $B, 'hi.txt', 'hello' ) );
ok( $r->{ok}, 'upload succeeds' );
is( $r->{saved}[0]{name}, 'hi.txt', 'reports the saved file' );
ok( -f "$d/content/hi.txt", 'file exists' );
is( slurp("$d/content/hi.txt"), 'hello', 'exact bytes written' );

# --- a *.pl target is refused for the RIGHT reason, named, and not written ---
my $rp = action_file_upload( 'content', multipart( $B, 'evil.pl', 'code' ) );
is( scalar @{ $rp->{saved} // [] }, 0, 'nothing saved for the blocked .pl' );
is( $rp->{errors}[0]{name},  'evil.pl',       'the error names the offending file' );
is( $rp->{errors}[0]{error}, 'Blocked target', 'refused specifically as a blocked target' );
ok( !-f "$d/content/evil.pl", '.pl not written' );

# --- a *.cgi is blocked ONLY via the is_blocked_config extension list ---
my $rc = action_file_upload( 'content', multipart( $B, 'x.cgi', 'c' ) );
is( $rc->{errors}[0]{error}, 'Blocked target', '.cgi blocked via the extension list' );
ok( !-f "$d/content/x.cgi", '.cgi not written' );

# --- a target under a blocked PATH prefix (lazysite/auth) is refused ---
my $rpath = action_file_upload( 'lazysite/auth', multipart( $B, 'note.txt', 'x' ) );
is( $rpath->{errors}[0]{error}, 'Blocked target', 'blocked-path-prefix target refused' );
ok( !-f "$d/lazysite/auth/note.txt", 'not written into the auth dir' );

# --- overwrite protection: second upload skips unless overwrite=1 ---
my $skip = action_file_upload( 'content', multipart( $B, 'hi.txt', 'NEW' ) );
is_deeply( $skip->{skipped}, ['hi.txt'], 'existing file skipped without overwrite' );
is( slurp("$d/content/hi.txt"), 'hello', 'original content preserved' );
my $ow = action_file_upload( 'content', multipart( $B, 'hi.txt', 'NEW', 1 ) );
is( $ow->{saved}[0]{name}, 'hi.txt', 'overwrite=1 replaces the file' );
is( slurp("$d/content/hi.txt"), 'NEW', 'content overwritten' );

# --- non-multipart body refused ---
{
    local $ENV{CONTENT_TYPE} = 'application/json';
    ok( !action_file_upload( 'content', '{}' )->{ok}, 'non-multipart refused' );
}

# --- download: capture the REAL fd (body is syswrite'd) and verify the bytes ---
sub capture_download {
    my ($rel) = @_;
    my $out = "$d/.dl";
    open my $save, '>&', \*STDOUT or die;
    open STDOUT, '>', $out or die;
    action_file_download($rel);
    open STDOUT, '>&', $save or die;
    return slurp($out);
}
my $dl = capture_download('content/hi.txt');
like( $dl, qr/Content-Length: 3/,         'download sizes the (overwritten) 3-byte file' );
like( $dl, qr/filename="hi\.txt"/,        'download sets the attachment filename' );
like( $dl, qr/\r\n\r\nNEW\z/,             'download sends the real body bytes' );

# missing file -> JSON {ok:0}, not an HTTP 404
my $miss = capture_download('content/nope.txt');
like( $miss, qr/"ok":0/,         'missing file returns ok:0 JSON' );
like( $miss, qr/File not found/, 'with a not-found error' );

done_testing();

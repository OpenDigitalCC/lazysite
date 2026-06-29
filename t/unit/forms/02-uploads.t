use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Binary uploads on the form handler: multipart files are parsed binary-safe,
# validated against the form's upload constraints, stored in a per-submission
# subdir next to the <form>.jsonl, and their names recorded in the submission.
my $PLUGIN = 'plugins/form-handler.pl';
ok( -f $PLUGIN, 'form handler present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/forms");
my $SECRET = 'test-secret-1234567890';
open my $sf, '>', "$d/lazysite/forms/.secret" or die $!; print $sf "$SECRET\n"; close $sf;
open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
print $hc "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    enabled: true\n    path: $d/subs\n";
close $hc;
# Form accepts <=2 files, <=4 KiB each, png/jpg/pdf only.
open my $fc, '>', "$d/lazysite/forms/contact.conf" or die $!;
print $fc "targets:\n  - handler: jsonl\n"
        . "upload_max_files: 2\nupload_max_kb: 4\nupload_accept: png, jpg, pdf\n";
close $fc;

my $BOUNDARY = 'Xbnd123';

sub multipart {
    my ($files) = @_;          # arrayref of [field, filename, ctype, bytes]
    my $ts = time() - 10;      # age 10s: passes the 3s..7200s window
    my $tk = hmac_sha256_hex( $ts, $SECRET );
    my @fields = ( [ '_form', 'contact' ], [ '_ts', $ts ], [ '_tk', $tk ],
        [ '_hp', '' ], [ 'name', 'Ada' ] );
    my $b = '';
    for my $f (@fields) {
        $b .= "--$BOUNDARY\r\nContent-Disposition: form-data; name=\"$f->[0]\"\r\n\r\n$f->[1]\r\n";
    }
    for my $f (@$files) {
        $b .= "--$BOUNDARY\r\n"
            . "Content-Disposition: form-data; name=\"$f->[0]\"; filename=\"$f->[1]\"\r\n"
            . "Content-Type: $f->[2]\r\n\r\n$f->[3]\r\n";
    }
    $b .= "--$BOUNDARY--\r\n";
    return $b;
}

my $IP = 0;
sub post {
    my ($body) = @_;
    my $bf = "$d/.body";
    open my $w, '>:raw', $bf or die $!; print {$w} $body; close $w;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = "multipart/form-data; boundary=$BOUNDARY";
    local $ENV{CONTENT_LENGTH} = -s $bf;
    local $ENV{REMOTE_ADDR}    = '10.0.0.' . ( ++$IP );   # fresh IP -> no rate limit
    my $out = qx($^X \Q$PLUGIN\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;     # strip CGI headers
    return decode_json($out);
}

sub records {
    my $f = "$d/subs/contact.jsonl";
    return () unless -f $f;
    open my $fh, '<', $f or return ();
    my @r = map { decode_json($_) } <$fh>;
    close $fh;
    return @r;
}

# 1) A valid PNG upload is accepted, stored, and recorded.
my $png = "\x89PNG\r\n" . ( 'x' x 200 );
my $r = post( multipart( [ [ 'photo', 'pic.png', 'image/png', $png ] ] ) );
ok( $r->{ok}, 'valid upload accepted' ) or diag explain $r;
my ($rec) = records();
is_deeply( $rec->{_files}, ['pic.png'], 'submission records the filename' );
ok( $rec->{_files_dir} && $rec->{_files_dir} =~ m{^contact\.files/}, 'records the files subdir' );
ok( -f "$d/subs/$rec->{_files_dir}/pic.png", 'file stored in the subdir next to the submission' );
{
    open my $fh, '<:raw', "$d/subs/$rec->{_files_dir}/pic.png"; local $/; my $got = <$fh>; close $fh;
    is( $got, $png, 'stored bytes are byte-identical (binary-safe)' );
}

# 2) Oversized file rejected with a specific message; nothing stored.
my $before = () = records();
my $big = post( multipart( [ [ 'photo', 'huge.png', 'image/png', 'y' x (5 * 1024) ] ] ) );
ok( !$big->{ok}, 'oversized file rejected' );
like( $big->{error}, qr/too large/i, 'specific size error shown to user' );
is( scalar( () = records() ), $before, 'no submission written on reject' );

# 3) Disallowed type rejected.
my $exe = post( multipart( [ [ 'photo', 'evil.exe', 'application/octet-stream', 'MZ' ] ] ) );
ok( !$exe->{ok}, 'disallowed extension rejected' );
like( $exe->{error}, qr/not allowed/i, 'specific type error shown' );

# 4) Too many files rejected.
my $many = post( multipart( [
    [ 'a', '1.png', 'image/png', 'a' ], [ 'b', '2.png', 'image/png', 'b' ],
    [ 'c', '3.png', 'image/png', 'c' ] ] ) );
ok( !$many->{ok}, 'too many files rejected' );
like( $many->{error}, qr/too many/i, 'specific count error shown' );

# 5) Path-traversal filename is sanitised to a bare basename.
my $trav = post( multipart( [ [ 'photo', '../../etc/passwd.png', 'image/png', $png ] ] ) );
ok( $trav->{ok}, 'traversal upload accepted (name sanitised)' );
my @all = records();
my $last = $all[-1];
unlike( $last->{_files}[0], qr{[/\\]}, 'stored filename has no path component' );
ok( -f "$d/subs/$last->{_files_dir}/$last->{_files}[0]", 'sanitised file exists' );
ok( !-e "$d/etc/passwd.png", 'no traversal write outside the subdir' );

done_testing;

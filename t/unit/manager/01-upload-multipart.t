#!/usr/bin/perl
# SM019: unit tests for parse_multipart_body and
# sanitise_upload_filename. Both are pure functions; loaded via the
# LAZYSITE_API_LOAD_ONLY hook so we avoid subprocess overhead.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}

my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# Helper: build a multipart body with a given boundary and parts.
# Each part is [name => value] for text fields or
# [name => value, filename, content_type] for file fields.
sub build_multipart {
    my ( $boundary, @parts ) = @_;
    my $out = '';
    for my $p (@parts) {
        my ( $name, $value, $filename, $ctype ) = @$p;
        $out .= "--$boundary\r\n";
        $out .= qq{Content-Disposition: form-data; name="$name"};
        $out .= qq{; filename="$filename"} if defined $filename;
        $out .= "\r\n";
        $out .= "Content-Type: $ctype\r\n" if defined $ctype;
        $out .= "\r\n";
        $out .= $value;
        $out .= "\r\n";
    }
    $out .= "--$boundary--\r\n";
    return $out;
}

# --- parse_multipart_body ---

subtest 'one text field, one file field' => sub {
    my $b = 'xAbC123';
    my $body = build_multipart(
        $b,
        [ 'overwrite' => '1' ],
        [ 'file'      => "hello world\n", 'hello.txt', 'text/plain' ],
    );
    my @parts = main::parse_multipart_body(
        $body, "multipart/form-data; boundary=$b" );
    is( scalar @parts, 2, 'two parts parsed' );
    is( $parts[0]{name}, 'overwrite',       'text field name' );
    is( $parts[0]{data}, '1',               'text field value' );
    is( $parts[1]{name}, 'file',            'file field name' );
    is( $parts[1]{filename}, 'hello.txt',   'file field filename' );
    is( $parts[1]{data}, "hello world\n",   'file field data' );
    is( $parts[1]{type}, 'text/plain',      'file field type' );
};

subtest 'two files' => sub {
    my $b = 'zzz';
    my $body = build_multipart(
        $b,
        [ 'file' => "one\n", 'a.txt', 'text/plain' ],
        [ 'file' => "two\n", 'b.txt', 'text/plain' ],
    );
    my @parts = main::parse_multipart_body(
        $body, "multipart/form-data; boundary=$b" );
    is( scalar @parts, 2, 'two file parts' );
    is( $parts[0]{filename}, 'a.txt', 'first filename' );
    is( $parts[1]{filename}, 'b.txt', 'second filename' );
};

subtest 'binary content with null bytes and CRLF in payload' => sub {
    my $b = 'bIn0';
    my $payload = "PNG\x00HEAD\r\nBODY\x00\x01\x02";
    my $body = build_multipart(
        $b,
        [ 'file' => $payload, 'image.png', 'image/png' ],
    );
    my @parts = main::parse_multipart_body(
        $body, "multipart/form-data; boundary=$b" );
    is( scalar @parts, 1, 'one part parsed' );
    is( $parts[0]{data}, $payload, 'binary payload preserved byte-for-byte' );
};

subtest 'missing boundary returns empty' => sub {
    my @parts = main::parse_multipart_body( "whatever", "text/plain" );
    is( scalar @parts, 0, 'no parts when content-type is not multipart' );
};

subtest 'quoted and unquoted boundary' => sub {
    my $b = 'quoted-b';
    my $body = build_multipart(
        $b, [ 'x' => 'y' ],
    );
    my @q = main::parse_multipart_body(
        $body, qq{multipart/form-data; boundary="$b"} );
    is( scalar @q, 1, 'quoted boundary parsed' );
    is( $q[0]{data}, 'y', 'quoted value intact' );

    my @u = main::parse_multipart_body(
        $body, "multipart/form-data; boundary=$b" );
    is( scalar @u, 1, 'unquoted boundary parsed' );
};

# --- sanitise_upload_filename ---

subtest 'sanitise strips path components' => sub {
    is( main::sanitise_upload_filename('../../../etc/passwd'),
        'passwd', 'dot-dot path collapsed to basename' );
    is( main::sanitise_upload_filename('/abs/foo.txt'),
        'foo.txt', 'absolute path collapsed' );
    is( main::sanitise_upload_filename('C:\\Windows\\x.exe'),
        'x.exe', 'backslash path collapsed' );
};

subtest 'sanitise rejects null bytes' => sub {
    is( main::sanitise_upload_filename("ok\x00.jpg"),
        '', 'null byte rejected' );
};

subtest 'sanitise rejects dotfile-only and empty' => sub {
    is( main::sanitise_upload_filename(''),   '', 'empty rejected' );
    is( main::sanitise_upload_filename('.'),  '', 'dot rejected' );
    is( main::sanitise_upload_filename('..'), '', 'dotdot rejected' );
};

subtest 'sanitise strips control chars but keeps normal name' => sub {
    is( main::sanitise_upload_filename("name\x01\x1f.txt"),
        'name.txt', 'control chars stripped' );
    is( main::sanitise_upload_filename('normal-name.jpg'),
        'normal-name.jpg', 'normal name unchanged' );
};

done_testing();

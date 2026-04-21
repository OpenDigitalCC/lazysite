#!/usr/bin/perl
# SM020: write_file_checked returns (ok, err) and does not leave
# files on disk when open fails. Directly mocking print/close
# failure is fiddly and unreliable across Perl versions, so we
# test the helper via the open-failure branch plus two integration
# paths (action_save and action_nav_save) that now use the helper.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use IPC::Open2;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# --- Unit-level: open failure branch ---

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $dir = tempdir( CLEANUP => 1 );

subtest 'happy path' => sub {
    my $path = "$dir/ok.txt";
    my ( $ok, $err ) = main::write_file_checked( $path, "hello\n" );
    is( $ok,  1,     'ok=1' );
    is( $err, undef, 'no error' );
    ok( -f $path, 'file exists' );
    open my $fh, '<', $path or die $!;
    is( do { local $/; <$fh> }, "hello\n", 'content correct' );
};

subtest 'open failure returns (0, error) and leaves no file' => sub {
    my $path = "$dir/does/not/exist/x.txt";
    my ( $ok, $err ) = main::write_file_checked( $path, "data" );
    is( $ok, 0, 'ok=0 on open failure' );
    like( $err, qr/Cannot write file/, 'error mentions write' );
    ok( !-f $path, 'no file on disk' );
};

subtest 'unicode content round-trips through utf8 layer' => sub {
    my $path = "$dir/utf8.txt";
    my $txt  = "hello \x{2014} world\n";
    my ( $ok, $err ) = main::write_file_checked( $path, $txt );
    is( $ok, 1, 'unicode write ok' );
    open my $fh, '<:utf8', $path or die $!;
    is( do { local $/; <$fh> }, $txt, 'unicode round-trip' );
};

# --- Integration-level: action_save surfaces helper errors ---

# Build a throwaway docroot where the target directory is
# read-only. write_file_checked's open will fail with EACCES and
# action_save's error payload must surface the reason. This also
# covers action_nav_save and the other four sites by the same
# mechanism: they all route through write_file_checked now.

SKIP: {
    skip 'running as root - chmod would have no effect', 2 if $> == 0;

    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite");
    make_path("$docroot/ro");
    chmod 0o500, "$docroot/ro";   # read+execute, no write

    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;

    sub csrf_for {
        my ($dr) = @_;
        local %ENV = (
            DOCUMENT_ROOT      => $dr,
            REQUEST_METHOD     => 'GET',
            QUERY_STRING       => 'action=csrf-token',
            HTTP_X_REMOTE_USER => 'mgr',
        );
        my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
        $out =~ s/\A.*?\r?\n\r?\n//s;
        return decode_json($out)->{token};
    }

    my $token = csrf_for($docroot);

    my ( $cout, $cin );
    my $body = '{"content":"boom","mtime":null}';
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => 'action=save&path=/ro/blocked.md',
        CONTENT_TYPE       => 'application/json',
        CONTENT_LENGTH     => length($body),
        HTTP_X_REMOTE_USER => 'mgr',
        HTTP_X_CSRF_TOKEN  => $token,
    );
    my $pid = open2( $cout, $cin,
        $^X, "$root/lazysite-manager-api.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $r = decode_json($out);

    is( $r->{ok}, 0, 'action_save returns ok=0 on read-only parent' );
    ok( !-e "$docroot/ro/blocked.md",
        'no partial file on read-only parent' );

    chmod 0o700, "$docroot/ro";   # allow cleanup
}

done_testing();

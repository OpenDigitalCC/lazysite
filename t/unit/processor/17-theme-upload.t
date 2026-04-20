#!/usr/bin/perl
# Theme upload: build a small zip fixture in-process with
# Archive::Zip, feed it to lazysite-manager-api.pl's theme-upload
# action, verify the theme was extracted into the expected
# location. Also verifies zip-slip rejection: a malicious entry
# with ../ components is refused before any files land on disk.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IPC::Open2;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

# Skip the whole file if Archive::Zip is unavailable - theme upload
# is explicitly an optional feature (install.sh warns if the
# module is missing).
eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)) };
if ( $@ ) {
    plan skip_all => 'Archive::Zip not installed (libarchive-zip-perl)';
}

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );

# Minimal conf so manager-api accepts the request without
# manager_groups enforcement blocking the call. Leaving
# manager_groups empty means "any authenticated user", which for
# the test harness we simulate with HTTP_X_REMOTE_USER.
mkdir "$docroot/lazysite";
mkdir "$docroot/lazysite/themes";
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

sub build_zip {
    my ($spec) = @_;       # arrayref of [filename => content]
    my $zip = Archive::Zip->new;
    for my $pair (@$spec) {
        my ( $name, $content ) = @$pair;
        my $m = $zip->addString( $content, $name );
        $m->desiredCompressionMethod(Archive::Zip::COMPRESSION_DEFLATED());
    }
    my $tmp = "$docroot/tmp.zip";
    $zip->writeToFileNamed($tmp) == Archive::Zip::AZ_OK()
        or die "zip write failed";
    open my $fh, '<:raw', $tmp or die $!;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    unlink $tmp;
    return $bytes;
}

# Everything below is a POST to manager-api with a CSRF token
# obtained from the same process. auth_proxy_trusted: true is NOT
# set, but HTTP_X_REMOTE_USER is honoured because the manager-api
# script reads it directly (it's the processor, not the
# manager-api, that gates on the trust sentinel).
sub api_post {
    my ( $action, $filename, $body, $token ) = @_;
    my ( $cout, $cin );
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => "action=$action"
                            . ( defined $filename
                                ? "&filename=" . $filename
                                : '' ),
        CONTENT_LENGTH     => length($body // ''),
        HTTP_X_REMOTE_USER => 'testadmin',
        HTTP_X_CSRF_TOKEN  => $token // '',
    );
    my $pid = open2( $cout, $cin,
        $^X, "$root/lazysite-manager-api.pl" );
    print $cin $body if defined $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out);
}

sub csrf_token {
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => 'action=csrf-token',
        HTTP_X_REMOTE_USER => 'testadmin',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out)->{token};
}

my $token = csrf_token();
ok( $token && length($token) == 64, 'csrf token obtained' );

# --- 1. Upload a well-formed theme zip ---
{
    my $zipbytes = build_zip([
        [ 'view.tt'    => "<html><body>[% content %]</body></html>\n" ],
        [ 'theme.json' => '{"name":"demo-theme","version":"1.0"}' ],
        [ 'assets/manager.css' => "/* demo css */\n" ],
    ]);

    my $r = api_post( 'theme-upload', 'demo.zip', $zipbytes, $token );
    is( $r->{ok}, 1, 'theme-upload accepted' )
        or diag explain $r;
    my $installed = $r->{installed_as} // $r->{name};
    ok( $installed, 'theme installed with a name' );

    my $dest = "$docroot/lazysite/themes/$installed";
    ok( -d $dest,                   'theme directory created' );
    ok( -f "$dest/view.tt",         'view.tt extracted' );
    ok( -f "$dest/theme.json",      'theme.json extracted' );

    open my $fh, '<', "$dest/view.tt" or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;
    like( $content, qr/\[% content %\]/, 'view.tt content preserved' );
}

# --- 2. Zip slip: entry with ../ is rejected ---
{
    my $zipbytes = build_zip([
        [ 'view.tt'    => "ok\n" ],
        [ 'theme.json' => '{"name":"evil"}' ],
        [ '../../../../tmp/d017-evil-theme' => "pwned\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'evil.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'zip slip attempt rejected' );
    like( $r->{error} // '', qr/slip|unsafe|traversal/i,
          'error message mentions slip/unsafe/traversal' );
    ok( !-e '/tmp/d017-evil-theme',
        'malicious entry was not extracted to /tmp' );
}

# --- 3. Zip with absolute path entry is rejected ---
{
    my $zipbytes = build_zip([
        [ 'view.tt'    => "ok\n" ],
        [ 'theme.json' => '{"name":"abs"}' ],
        [ '/etc/test-abs' => "nope\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'abs.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'absolute-path entry rejected' );
}

# --- 4. Missing view.tt → rejected ---
{
    my $zipbytes = build_zip([
        [ 'theme.json' => '{"name":"no-view"}' ],
        [ 'readme.md'  => "nothing to see\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'no-view.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'zip without view.tt rejected' );
    like( $r->{error} // '', qr/view\.tt/, 'error mentions view.tt' );
}

# --- 5. Missing theme.json → rejected ---
{
    my $zipbytes = build_zip([
        [ 'view.tt' => "ok\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'no-json.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'zip without theme.json rejected' );
    like( $r->{error} // '', qr/theme\.json/, 'error mentions theme.json' );
}

done_testing();

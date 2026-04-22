#!/usr/bin/perl
# D013: theme upload. Build a small zip fixture in-process with
# Archive::Zip, feed it to lazysite-manager-api.pl's theme-upload
# action, verify the theme was extracted into the nested path
# lazysite/layouts/LAYOUT/themes/THEME/. Also verifies strict
# rejection when theme.json omits the required layouts[] field,
# zip-slip rejection, and missing-manifest rejection.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IPC::Open2;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)) };
if ( $@ ) {
    plan skip_all => 'Archive::Zip not installed (libarchive-zip-perl)';
}

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );

# Minimal conf. Pre-create the 'default' layout on disk so themes
# declaring layouts:["default"] resolve.
make_path("$docroot/lazysite");
make_path("$docroot/lazysite/layouts/default");
open my $lfh, '>', "$docroot/lazysite/layouts/default/layout.tt" or die $!;
print $lfh "<html>[% content %]</html>\n";
close $lfh;
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\nlayout: default\n";
close $cf;

sub build_zip {
    my ($spec) = @_;
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

# --- 1. Upload a well-formed D013 theme zip ---
{
    my $meta = encode_json({
        name    => 'demo-theme',
        version => '1.0',
        layouts => ['default'],
        config  => { colours => { primary => '#112233' } },
    });
    my $zipbytes = build_zip([
        [ 'theme.json'        => $meta ],
        [ 'main.css'          => "/* demo css */\n" ],
        [ 'assets/logo.svg'   => "<svg/>\n" ],
    ]);

    my $r = api_post( 'theme-upload', 'demo.zip', $zipbytes, $token );
    is( $r->{ok}, 1, 'theme-upload accepted' ) or diag explain $r;

    my $installed = $r->{installed_as} // $r->{name};
    ok( $installed, 'theme installed with a name' );

    my $dest = "$docroot/lazysite/layouts/default/themes/$installed";
    ok( -d $dest,                'theme directory at nested path' );
    ok( -f "$dest/theme.json",   'theme.json extracted' );
    ok( -f "$dest/main.css",     'main.css extracted' );

    my $assets = "$docroot/lazysite-assets/default/$installed";
    ok( -d $assets,              'assets dir at nested asset path' );
    ok( -f "$assets/logo.svg",   'asset extracted' );
}

# --- 2. Zip slip: entry with ../ is rejected ---
{
    my $meta = encode_json({
        name => 'evil', version => '1.0',
        layouts => ['default'],
        config => {},
    });
    my $zipbytes = build_zip([
        [ 'theme.json' => $meta ],
        [ '../../../../tmp/d013-evil-theme' => "pwned\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'evil.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'zip slip attempt rejected' );
    like( $r->{error} // '', qr/slip|unsafe|traversal/i,
          'error message mentions slip/unsafe/traversal' );
    ok( !-e '/tmp/d013-evil-theme',
        'malicious entry was not extracted to /tmp' );
}

# --- 3. Missing layouts[] is rejected (DP-C strict) ---
{
    my $meta = encode_json({ name => 'no-layouts', version => '1.0',
                             config => {} });
    my $zipbytes = build_zip([
        [ 'theme.json' => $meta ],
        [ 'main.css'   => "/* */\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'no-layouts.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'theme without layouts[] rejected' );
    like( $r->{error} // '', qr/layouts/i, 'error mentions layouts' );
}

# --- 4. theme targets a missing layout ---
{
    my $meta = encode_json({
        name => 'bad-target', version => '1.0',
        layouts => ['not-installed'],
        config  => {},
    });
    my $zipbytes = build_zip([ [ 'theme.json' => $meta ] ]);
    my $r = api_post( 'theme-upload', 'bad.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'theme targeting missing layout rejected' );
    like( $r->{error} // '', qr/missing layout/i,
          'error names the missing layout' );
}

# --- 5. Missing theme.json → rejected ---
{
    my $zipbytes = build_zip([
        [ 'main.css' => "/* */\n" ],
    ]);
    my $r = api_post( 'theme-upload', 'no-json.zip', $zipbytes, $token );
    is( $r->{ok}, 0, 'zip without theme.json rejected' );
    like( $r->{error} // '', qr/theme\.json/, 'error mentions theme.json' );
}

done_testing();

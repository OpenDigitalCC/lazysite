#!/usr/bin/perl
# SM1303: THE MANAGER'S THEME UPLOAD REFUSES WHAT EVERY OTHER WAY INTO A THEME DOES.
#
# The manager's Upload Theme (theme-upload, Manager::Themes::action_theme_upload)
# had three gaps the other theme-writing channels do not: no size limit
# (file-upload and upload_file apply the site's upload limit), symbolic links
# extracted and copied into the served asset mirror - so a public
# /lazysite-assets/ URL named any file the web server can read, the session
# secret among them - and file types the web server runs (WebDAV and
# upload_file refuse them under a theme). This drives the manager's own door,
# as a signed-in person, to show each closed - and that an ordinary theme still
# installs.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use JSON::PP       qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root);
use ManagerSession ();

plan skip_all => 'Archive::Zip is not installed' unless eval { require Archive::Zip; 1 };
my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my $ms = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nsite_name: T\nlayout: default\nmanager_upload_max_mb: 1\n" );
my $d = $ms->docroot;
make_path("$d/lazysite/layouts/default");
open my $lt, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
print {$lt} '<html><body>[% content %]</body></html>';
close $lt;

my @ALL = qw(ui manage_themes);
$ms->add_user( 'tess', 'pw-tess-0123456789' );
$ms->grant( 'tess', 'designers', [@ALL], \@ALL );

# A zip of { name => bytes }, and of { name => target } as symbolic links.
#
# THE LINKS ARE MADE BY HAND. Archive::Zip 1.68 writing a symbolic-link member
# calls symlink() on its output handle and leaves a link named like
# `GLOB(0x...)` in the working directory (seen while building this test), so the
# links are written as ordinary members and marked as links afterwards in the
# central directory: made by Unix (version-made-by high byte 3) and S_IFLNK in
# the external attributes - what `zip --symlinks` writes.
sub zip_of {
    my ( $files, $links ) = @_;
    $links ||= {};
    my $z = Archive::Zip->new;
    $z->addString( $files->{$_}, $_ ) for sort keys %$files;
    $z->addString( $links->{$_}, $_ ) for sort keys %$links;
    my $out = '';
    open my $fh, '>', \$out or die;
    binmode $fh;
    $z->writeToFileHandle($fh) == Archive::Zip::AZ_OK() or die 'zip write failed';
    close $fh;
    my $at = 0;
    while ( ( $at = index( $out, "PK\x01\x02", $at ) ) >= 0 ) {
        my $nl   = unpack( 'v', substr( $out, $at + 28, 2 ) );
        my $name = substr( $out, $at + 46, $nl );
        if ( exists $links->{$name} ) {
            substr( $out, $at + 5,  1 ) = chr(3);
            substr( $out, $at + 38, 4 ) = pack( 'V', 0120777 << 16 );
        }
        $at += 46 + $nl;
    }
    return $out;
}
sub upload {
    my ($zip) = @_;
    return $ms->call( 'tess', 'theme-upload', raw => $zip, content_type => 'application/zip',
        query => 'action=theme-upload&filename=t.zip' );
}
sub json_for { encode_json( { name => $_[0], version => '1', layouts => ['default'] } ) }
my $THEMES = "$d/lazysite/layouts/default/themes";

subtest 'an ordinary theme installs' => sub {
    my $r = upload( zip_of( { 'theme.json' => json_for('plain'), 'assets/main.css' => "body{}\n" } ) );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    ok( -f "$THEMES/plain/theme.json", 'under the layout' );
    ok( -f "$d/lazysite-assets/default/plain/main.css", 'with its asset mirror' );
};

subtest 'a symbolic link is refused' => sub {
    my $r = upload( zip_of( { 'theme.json' => json_for('linky') }, { 'assets/passwd' => '/etc/passwd' } ) );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/symbolic link/, 'naming the entry' ) or diag explain $r;
    ok( !-e "$THEMES/linky", 'nothing installed' );
    ok( !-l "$d/lazysite-assets/default/linky/passwd" && !-e _, 'and no link in the served mirror' );
};

subtest 'a file type the web server runs is refused' => sub {
    my $r = upload( zip_of( { 'theme.json' => json_for('runny'), 'assets/x.php' => '<?php ?>' } ) );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/web server would run/, 'naming why' ) or diag explain $r;
    ok( !-e "$THEMES/runny", 'nothing installed' );
};

subtest 'an archive over the site\'s upload limit is refused' => sub {
    my $noise = join '', map { chr( int( rand 256 ) ) } 1 .. ( 1024 * 1024 + 4096 );
    my $r = upload( zip_of( { 'theme.json' => json_for('huge'), 'assets/big.bin' => $noise } ) );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'too-large', 'as too-large' ) or diag explain $r;
    ok( !-e "$THEMES/huge", 'nothing installed' );
};

done_testing();

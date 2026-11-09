#!/usr/bin/perl
# SM1369 X7 (rulings 188, 202): THE INSTALLER LAYS AN EXTENSION OUT WHEN ITS
# PACKAGE IS PRESENT, and never removes it from a site that uses it.
#
# lazysite-odoo is its own deb. The common payload's release manifest still
# lists Odoo's files, each marked `extension: odoo`, so install.pl, run from a
# payload WITHOUT that package, must:
#
#   - leave the extension out whole, and treat the site's old copies as files
#     that left the manifest: an unedited copy is removed, an edited one kept
#     with its orphan warning (the 0.16.7 rule);
#   - refuse, before anything changes, a site that has the extension ON,
#     naming the package (R-7);
#   - and, from a payload WITH it, lay it out as before.
#
# Real install.pl, real stages built from this checkout's manifest (PayloadStage).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site slurp spit);
use PayloadStage  qw(make_stage tree_digest run_install);

my $MF = repo_manifest_guard();

my $manifest = decode_json( slurp( $MF->path ) );
my %ext_of   = map { $_->{path} => $_->{extension} } @{ $manifest->{files} };

subtest 'the manifest marks the extension\'s files, and only those' => sub {
    is( $ext_of{'extensions/odoo.pl'},                     'odoo', 'the descriptor' );
    is( $ext_of{'extensions/odoo/lib/Lazysite/Odoo.pm'},   'odoo', 'the payload lib' );
    is( $ext_of{'extensions/odoo/assets/lazysite-odoo.js'}, 'odoo', 'the payload assets' );
    is( $ext_of{'lazysite-odoo.pl'},                       'odoo', 'the endpoint owns.endpoints names' );
    is( $ext_of{'lazysite-data.pl'},                       'data', 'another extension\'s endpoint is its own' );
    ok( !defined $ext_of{'lazysite-processor.pl'},         'a core CGI belongs to no extension' );
    ok( !defined $ext_of{'lib/Lazysite/Extensions.pm'},    'nor does core\'s lib' );
};

my $full   = make_stage( $MF->path );
my $noodoo = make_stage( $MF->path, without => ['odoo'] );
ok( !-e "$noodoo/extensions/odoo.pl" && -f "$noodoo/release-manifest.json",
    'a payload without lazysite-odoo: its files absent, the manifest still listing them' );

sub provision {
    my ( $docroot, $cgibin ) = @_;
    my ( $rc, $out ) = run_install( $full, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'provision' );
    is( $rc, 0, 'provisioned from the full payload' ) or diag $out;
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    $conf =~ s/^update_channel:.*\n//mg;
    spit( "$docroot/lazysite/lazysite.conf", $conf . "update_channel: all\n" );
    # Below every version this branch can carry, so the next run is an upgrade.
    my $sp = "$docroot/lazysite/.install-state.json";
    my $s  = slurp($sp);
    $s =~ s/"version"\s*:\s*"[^"]*"/"version" : "0.16.2"/;
    spit( $sp, $s );
    return;
}

subtest 'Odoo off, its package absent: left out, the old copies go, an edited one stays' => sub {
    my ( $docroot, $cgibin, $root ) = new_site();
    provision( $docroot, $cgibin );
    ok( -f "$root/extensions/odoo.pl" && -f "$cgibin/lazysite-odoo.pl", 'the full payload laid Odoo out' );
    my $edited = "$root/extensions/odoo/lib/Lazysite/Odoo/Session.pm";
    ok( -f $edited, 'a payload module to edit' );
    spit( $edited, slurp($edited) . "\n# a local edit\n" );

    my ( $rc, $out ) = run_install( $noodoo, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade' );
    is( $rc, 0, 'the upgrade succeeds' ) or diag $out;
    like( $out, qr/not in this payload, left out: odoo/, 'and says what it left out' );
    ok( !-e "$root/extensions/odoo.pl",                     'the unedited descriptor is removed' );
    ok( !-e "$root/extensions/odoo/lib/Lazysite/Odoo.pm",   'an unedited payload module is removed' );
    ok( !-e "$cgibin/lazysite-odoo.pl",                     'the endpoint is removed' );
    ok( -f $edited,                                         'the edited module is kept' );
    like( $out, qr/orphan \(edited post-install, left in place\): \Q$edited\E/, 'with its orphan warning' );
    ok( -f "$cgibin/lazysite-processor.pl" && -f "$root/extensions/data.pl", 'core and the other extensions are laid' );
    my $state = decode_json( slurp("$docroot/lazysite/.install-state.json") );
    ok( !( grep {m{/extensions/odoo\.pl\z|/lazysite-odoo\.pl\z}} keys %{ $state->{files} } ),
        'the install state no longer records them' );
};

subtest 'Odoo on, its package absent: refused before anything changes' => sub {
    my ( $docroot, $cgibin, $root ) = new_site();
    provision( $docroot, $cgibin );
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    $conf =~ s/^extensions:\s*\n/extensions:\n  - extensions\/odoo.pl\n/m
        or $conf .= "extensions:\n  - extensions/odoo.pl\n";
    spit( "$docroot/lazysite/lazysite.conf", $conf );
    my $before = tree_digest($root);

    my ( $rc, $out ) = run_install( $noodoo, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade' );
    is( $rc, 2, 'refused (exit 2)' ) or diag $out;
    like( $out, qr/'odoo' extension on, and this payload does not carry it/, 'saying why' );
    like( $out, qr/Install lazysite-odoo/,       'naming the package to install' );
    like( $out, qr/Nothing was changed/,         'and that nothing changed' );
    is( tree_digest($root), $before, 'and nothing did: not a file, a mode or a backup' );

    ( $rc, $out ) = run_install( $full, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade' );
    is( $rc, 0, 'with the package present the same upgrade succeeds' ) or diag $out;
    unlike( $out, qr/left out: odoo/, 'leaving nothing out' );
    ok( -f "$root/extensions/odoo.pl" && -f "$root/extensions/odoo/lib/Lazysite/Odoo.pm"
            && -f "$cgibin/lazysite-odoo.pl",
        'and Odoo is laid out' );
};

subtest 'verify reads the same rule' => sub {
    my ( $docroot, $cgibin ) = new_site();
    provision( $docroot, $cgibin );
    my ( $rc, $out ) = run_install( $noodoo, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade' );
    is( $rc, 0, 'upgraded without Odoo' ) or diag $out;
    unlike( $out, qr/INTEGRITY:/, 'the integrity check does not ask for the absent extension\'s files' );
};

done_testing();

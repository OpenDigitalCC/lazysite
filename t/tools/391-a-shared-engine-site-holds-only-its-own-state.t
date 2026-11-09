#!/usr/bin/perl
# SM1361 (rulings 201, 202): A SHARED-ENGINE SITE HOLDS ONLY ITS OWN STATE.
#
# A volume-hosted site runs in a container whose image is the payload, read-only.
# install.pl --engine shared (the container's entrypoint passes it) lays the
# site - content, settings, the templates and the manager's pages and assets,
# the per-site copies ruling 202 keeps - and nothing of the engine: no CGI, no
# lib, no tools, no extensions. The steps that run an installed tool run the
# payload's. Here, against a payload stage made read-only as the image is:
#
#   - provision lays no engine copy and writes nothing into the payload, the
#     site passes its own health check, and the state remembers `shared`;
#   - a later run without the flag stays shared (a remembered choice);
#   - the image's SHARED-ENGINE marker makes a new site shared without the
#     flag, and the hook index is built from the payload, naming its copy of
#     the extension (Lazysite::Extensions' shared rule);
#   - a site as today's recipe left it (engine copies recorded in the state,
#     gone with the recreated container) upgrades without re-laying them;
#   - an unknown --engine is refused.
use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site slurp spit);
use PayloadStage  qw(make_stage make_writable tree_digest run_install);

my $MF    = repo_manifest_guard();
my $image = make_stage( $MF->path, image => 1, links => [qw(form-handler payment-demo)] );
END { make_writable($image) if $image }
my $before = tree_digest($image);

sub shared_state {
    my ($docroot) = @_;
    return decode_json( slurp("$docroot/lazysite/.install-state.json") );
}

subtest 'provision lays the site and none of the engine' => sub {
    my ( $docroot, undef, $root ) = new_site();
    local $PayloadStage::HEALTH = 1;
    my ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image,
        '--mode', 'provision', '--engine', 'shared' );
    is( $rc, 0, 'provisioned, and the site passes its own health check' ) or diag $out;
    ok( !-e "$root/$_", "no $_ beside the docroot" ) for qw(lib tools extensions);
    ok( -f "$docroot/manager/index.md",                      'the manager\'s pages are laid' );
    ok( -f "$docroot/assets/qrcode.js",                      'and the shipped assets' );
    ok( -f "$docroot/lazysite/templates/system/login.md",    'and the engine\'s templates' );
    ok( -f "$docroot/lazysite/lazysite.conf",                'and the settings' );
    my $state = shared_state($docroot);
    is( $state->{engine}, 'shared', 'the state remembers the shared engine' );
    my @engine = grep { index( $_, "$image/" ) == 0 || m{\A\Q$root\E/(?:lib|tools|extensions)/} }
        keys %{ $state->{files} };
    is_deeply( \@engine, [], 'and records no engine file' );
    is( tree_digest($image), $before, 'the payload is unchanged' );
};

subtest 'a later run without the flag stays shared' => sub {
    my ( $docroot, undef, $root ) = new_site();
    my ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image,
        '--mode', 'provision', '--engine', 'shared' );
    is( $rc, 0, 'provisioned' ) or diag $out;
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    $conf =~ s/^extensions:\s*\n/extensions:\n  - extensions\/odoo.pl\n/m
        or $conf .= "extensions:\n  - extensions/odoo.pl\n";
    spit( "$docroot/lazysite/lazysite.conf", $conf );
    # A run WITHOUT --engine: the remembered choice holds.
    ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image, '--mode', 'reinstall' );
    is( $rc, 0, 'reinstalled without the flag' ) or diag $out;
    unlike( $out, qr/HOOKS:/, 'the hook index step ran clean' );
    ok( !-e "$root/$_", "still no $_ beside the docroot" ) for qw(lib tools extensions);
    is( shared_state($docroot)->{engine}, 'shared', 'and the site is still shared' );
    is( tree_digest($image), $before, 'the payload is unchanged' );
};

subtest 'a site from today\'s recipe upgrades without re-laying the copies' => sub {
    my ( $docroot, $cgibin, $root ) = new_site();
    my ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'provision',
        '--engine', 'copy' );
    is( $rc, 0, 'provisioned with the engine copy, as the recipe did' ) or diag $out;
    ok( -f "$root/lib/Lazysite/Extensions.pm" && -f "$cgibin/lazysite-processor.pl", 'with its copies' );
    make_writable($root);
    remove_tree( "$root/lib", "$root/tools", "$root/extensions", $cgibin );    # the recreated container
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    $conf =~ s/^update_channel:.*\n//mg;
    spit( "$docroot/lazysite/lazysite.conf", $conf . "update_channel: all\n" );
    my $sp = "$docroot/lazysite/.install-state.json";
    ( my $s = slurp($sp) ) =~ s/"version"\s*:\s*"[^"]*"/"version" : "0.16.2"/;
    spit( $sp, $s );

    ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image,
        '--mode', 'upgrade', '--engine', 'shared' );
    is( $rc, 0, 'the upgrade succeeds' ) or diag $out;
    unlike( $out, qr/INTEGRITY:|orphan/, 'with no integrity warning and no orphan' );
    ok( !-e "$root/$_", "and no $_ re-laid" ) for qw(lib tools extensions);
    my $state = shared_state($docroot);
    is( $state->{engine}, 'shared', 'the site is shared now' );
    ok( !( grep { m{\A\Q$root\E/(?:lib|tools|extensions|cgi-bin)/} } keys %{ $state->{files} } ),
        'and the state forgets the old copies' );
    is( tree_digest($image), $before, 'the payload is unchanged' );
};

subtest 'the image\'s marker makes a site shared without the flag, and the index is the payload\'s' => sub {
    my ( $docroot, undef, $root ) = new_site();
    my ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image, '--mode', 'provision' );
    is( $rc, 0, 'provisioned from the marked image, no --engine' ) or diag $out;
    is( shared_state($docroot)->{engine}, 'shared', 'the site is shared' );
    ok( !-e "$root/$_", "no $_ beside the docroot" ) for qw(lib tools extensions);
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    $conf =~ s/^extensions:\s*\n/extensions:\n  - extensions\/odoo.pl\n/m
        or $conf .= "extensions:\n  - extensions/odoo.pl\n";
    spit( "$docroot/lazysite/lazysite.conf", $conf );
    ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $image, '--mode', 'reinstall' );
    is( $rc, 0, 'reinstalled with Odoo on' ) or diag $out;
    unlike( $out, qr/HOOKS:/, 'the hook index step ran clean' );
    my $index = decode_json( slurp("$docroot/lazysite/extensions.index.json") // '{}' );
    is( ( $index->{extensions}{odoo} // {} )->{payload}, "$image/extensions/odoo",
        'the index names the payload\'s copy of the extension, found by the engine\'s rule' );
    is( tree_digest($image), $before, 'the payload is unchanged' );
};

subtest 'an unknown --engine is refused' => sub {
    my ( $docroot, $cgibin ) = new_site();
    my ( $rc, $out ) = run_install( $image, '--docroot', $docroot, '--cgibin', $cgibin,
        '--mode', 'provision', '--engine', 'both' );
    is( $rc, 2, 'refused (exit 2)' );
    like( $out, qr/--engine 'both' is not one of shared, copy/, 'naming the choices' );
    ok( !-e "$docroot/lazysite/.install-state.json", 'and nothing is installed' );
};

done_testing();

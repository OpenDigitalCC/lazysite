#!/usr/bin/perl
# SM734: a domain with a content_root serves /lazysite-assets/ from THAT root,
# so theme activation has to mirror there too.
#
# Reported from the field on 0.11.10: the same asset returned 200 on the docroot
# host and 404 on the content-root host, for every theme, and the manager
# preview looked correct throughout. The preview renders through the engine
# while the live host serves a static file, which is why the one surface an
# operator naturally checks could not show the fault.
#
# The module already knew how: _host_content_root had read these conf lines
# since SM315, for cache invalidation. The asset mirror seven hundred lines
# above hardcoded $DOCROOT. This asserts the mirror reaches both.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();

my $root = tempdir( CLEANUP => 1 );
make_path("$root/lazysite/layouts/atl/themes/noir/assets");
open my $css, '>', "$root/lazysite/layouts/atl/themes/noir/assets/main.css" or die $!;
print {$css} "body{color:red}\n";
close $css;

open my $conf, '>', "$root/lazysite/lazysite.conf" or die $!;
print {$conf} <<'CONF';
site_name: Test
content_root: sites/primary
alias.two.example.content_root: sites/two
alias.three.example.content_root: sites/primary
CONF
close $conf;

$Lazysite::Manager::Themes::DOCROOT      = $root;
$Lazysite::Manager::Common::DOCROOT      = $root;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$root/lazysite";

subtest 'every distinct content root is enumerated, once' => sub {
    my @cr = Lazysite::Manager::Themes::_all_content_roots();
    is_deeply( \@cr, [ 'sites/primary', 'sites/two' ],
        'both roots, DEDUPLICATED - two hosts share sites/primary' );
};

subtest 'the mirror reaches the docroot and every content root' => sub {
    my $r = Lazysite::Manager::Themes::_mirror_theme_assets( 'atl', 'noir' );
    ok( $r->{mirrored}, 'assets were mirrored' ) or diag explain $r;

    ok( -f "$root/lazysite-assets/atl/noir/main.css",
        'the docroot mirror exists, as it always did' );

    # The defect, directly: these two did not exist before.
    ok( -f "$root/sites/primary/lazysite-assets/atl/noir/main.css",
        'and the primary content root has it' );
    ok( -f "$root/sites/two/lazysite-assets/atl/noir/main.css",
        'and the aliased content root has it' );

    is_deeply( $r->{also_mirrored}, [ 'sites/primary', 'sites/two' ],
        'the acknowledgement names where else it went' );
};

subtest 'a content root that cannot be written is reported, not fatal' => sub {
    # A per-domain fault must not take a working site down: the docroot mirror
    # is already written and the primary host serves. So the activation reports
    # which domain missed out rather than refusing wholesale.
    my $blocked = "$root/sites/blocked";
    make_path($blocked);
    open my $c2, '>>', "$root/lazysite/lazysite.conf" or die $!;
    print {$c2} "alias.four.example.content_root: sites/blocked\n";
    close $c2;
    chmod 0500, $blocked;

    my $r = Lazysite::Manager::Themes::_mirror_theme_assets( 'atl', 'noir' );
    chmod 0700, $blocked;

    SKIP: {
        skip 'running as a user that ignores mode bits', 2
            if -w "$blocked/probe" || $> == 0;
        ok( $r->{mirrored}, 'the activation still succeeded' );
        ok( ( grep { $_ eq 'sites/blocked' } @{ $r->{mirror_failed} // [] } ),
            'and named the content root that did not receive the assets' );
    }
};

subtest 'a content root cannot escape the docroot' => sub {
    # Operator-written config, but it names a directory this code creates.
    open my $c3, '>', "$root/lazysite/lazysite.conf" or die $!;
    print {$c3} "content_root: ../escape\nalias.x.content_root: /etc\n";
    close $c3;
    my @cr = Lazysite::Manager::Themes::_all_content_roots();
    is_deeply( \@cr, [], 'a traversal and an absolute path are both refused' );
};

done_testing();

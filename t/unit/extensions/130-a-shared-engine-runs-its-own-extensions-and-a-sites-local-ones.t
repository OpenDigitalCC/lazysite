#!/usr/bin/perl
# SM1361 (rulings 200, 201, 205, 210): ON A SHARED READ-ONLY ENGINE, X1'S RULE IS
# THE ENGINE'S OWN PAYLOAD PATH ONLY. The shared container belongs to one
# operator and only the image's own extensions run in it (ruling 210); a site
# extension file is refused by name, and `lazysite check` names it.
#
# A fixture engine tree - lib/ and tools/ with the code the rule runs,
# extensions/ with an extension and its payload, and the image's marker at its
# root - and a site beside it with no engine copy of its own, its extensions dir
# holding a local extension and a planted copy of the engine's. Each question is
# asked in a fresh perl with only the engine's lib on @INC, as the container's
# processes have:
#
#   - the engine's extension is found in the engine;
#   - a site's own extension, and a site file with a name the engine ships (a
#     planted shadow), are never found, never registered, and each is named:
#     by refused_site_files, in the log, and by `lazysite check` with its remedy;
#   - links are refused, and an engine name held as a link is nobody's;
#   - a site payload's module that an engine extension's payload lib also holds
#     is refused at the hook check (Hooks::_shadowed), however it got on @INC;
#   - the same trees WITHOUT the marker read as today: the site's dir first
#     (the Hestia and deb hosts, where each site keeps its own copy).
#
# Sabotage: let locate() fall through to the site's dir on a shared engine and
# the local extension is found - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child site_tempdir);

my $repo   = repo_root();
my $t      = site_tempdir() =~ s{/site/public_html\z}{}r;    # the base: engine/ and srv/ below it
my $engine = "$t/engine";
my $site   = "$t/srv";
make_path( "$engine/lib", "$site/html/lazysite" );
system( 'cp', '-a', "$repo/lib/Lazysite", "$engine/lib/" ) == 0 or die 'copy lib';

sub spit {
    my ( $p, $s ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $s;
    close $fh;
}
sub module { my ( $pkg, $says ) = @_; return "package $pkg;\nsub says { '$says' }\n1;\n" }

spit( "$engine/SHARED-ENGINE", "this engine is shared and read-only\n" );
spit( "$engine/extensions/demo.pl", "#!/usr/bin/perl\n# engine\n" );
spit( "$engine/extensions/demo/lib/Demo/Thing.pm", module( 'Demo::Thing', 'engine' ) );
spit( "$site/extensions/mine.pl", "#!/usr/bin/perl\n# local\n" );
spit( "$site/extensions/mine/lib/Mine/Thing.pm", module( 'Mine::Thing', 'local' ) );
spit( "$site/extensions/demo.pl", "#!/usr/bin/perl\n# PLANTED\n" );
spit( "$site/html/lazysite/lazysite.conf", "site_name: Shared\n" );

sub ask {
    my ($code) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    delete local $ENV{LAZYSITE_DEV_SERVER};
    delete local $ENV{LAZYSITE_EXTENSION_DIRS};
    my $r = run_child( [ $^X, "-I$engine/lib", '-e', "use Lazysite::Extensions; $code" ] );
    return ( ( $r->{out} // '' ) . ( $r->{err} // '' ) );
}
my $where = 'print Lazysite::Extensions::locate( $ARGV[0] // "", "' . $site . '" ) // "none", "\n"';
sub found { my ($f) = @_; ( my $c = $where ) =~ s/\$ARGV\[0\] \/\/ ""/"$f"/; return ask($c) }

like( ask('print Lazysite::Extensions::shared_engine() // "no", "\n"'), qr{\A\Q$engine\E/extensions\n},
    'the marker at the engine root makes it a shared engine' );
is( found('demo.pl'), "$engine/extensions/demo.pl\n", 'the engine\'s extension is the engine\'s copy' );
is( found('mine.pl'), "none\n", 'a site\'s own extension is never found (ruling 210)' );
is( found('none.pl'), "none\n",                        'a name in neither is none' );

subtest 'every site extension file is refused by name' => sub {
    is( ask( 'print "$_\n" for Lazysite::Extensions::refused_site_files("' . $site . '")' ),
        join( '', map {"$site/extensions/$_\n"} qw(demo.pl mine mine.pl) ),
        'refused_site_files names each entry of the site\'s extensions dir' );
    is( ask( 'print scalar( () = Lazysite::Extensions::refused_site_files("' . $engine . '") ), "\n"' ), "0\n",
        'and never the engine\'s own directory' );
    my $out = ask( 'require Lazysite::Manager::Extensions; $Lazysite::Manager::Extensions::DOCROOT = "'
            . "$site/html"
            . '"; my $r = Lazysite::Manager::Extensions::extension_registry(); '
            . 'print "$_=$r->{$_}\n" for sort keys %$r' );
    like( $out, qr{^extensions/demo\.pl=\Q$engine\E/extensions/demo\.pl$}m, 'the registry: demo is the engine\'s' );
    unlike( $out, qr{^extensions/mine\.pl=}m,                                'the local extension is not registered' );
    unlike( $out, qr{^extensions/[^=\s]+=\Q$site\E/}m,                       'nor anything of the site\'s' );
    like( $out, qr{a site extension file is refused: only the shared engine's own extensions run here.*\Q$site\E/extensions/mine\.pl},
        'and each is logged by name' );

    # The check runs the engine's own tool, which loads the Odoo extension's
    # modules from the engine's payload, as the image carries them.
    make_path("$engine/tools");
    copy( "$repo/tools/lazysite-check.pl", "$engine/tools/lazysite-check.pl" ) or die $!;
    copy( "$repo/extensions/odoo.pl", "$engine/extensions/odoo.pl" ) or die $!;
    system( 'cp', '-a', "$repo/extensions/odoo", "$engine/extensions/" ) == 0 or die 'copy odoo';
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $r = run_child( [ $^X, "$engine/tools/lazysite-check.pl", '--docroot', "$site/html" ] );
    my $check = ( $r->{out} // '' ) . ( $r->{err} // '' );
    like( $check, qr{\[ warn \] a site extension is refused on this shared engine: \Q$site\E/extensions/mine\.pl - only the engine's own extensions run here},
        'lazysite check names the local extension' );
    like( $check, qr{\[ warn \] a site extension is refused on this shared engine: \Q$site\E/extensions/demo\.pl},
        'and the planted copy' );
    like( $check, qr{remove it; a site that needs its own extension moves to a dedicated service},
        'with the remedy' );
};

subtest 'links are refused' => sub {
    symlink "$site/extensions/mine.pl", "$site/extensions/linked.pl" or die $!;
    is( found('linked.pl'), "none\n", 'a linked local descriptor is not found' );
    unlink "$site/extensions/linked.pl";
    spit( "$t/elsewhere/lib/Mine/Thing.pm", module( 'Mine::Thing', 'elsewhere' ) );
    spit( "$site/extensions/hop.pl", "#!/usr/bin/perl\n" );
    symlink "$t/elsewhere", "$site/extensions/hop" or die $!;
    is( ask( 'print Lazysite::Extensions::payload_lib("' . "$site/extensions/hop.pl" . '") // "none", "\n"' ), "none\n",
        'a linked local payload is no payload' );
    symlink "$site/extensions/mine.pl", "$engine/extensions/elink.pl" or die $!;
    spit( "$site/extensions/elink.pl", "#!/usr/bin/perl\n# local of an engine link\n" );
    is( found('elink.pl'), "none\n", 'a name the engine holds as a link is nobody\'s' );
    unlink "$engine/extensions/elink.pl";
};

subtest 'a site payload\'s module an engine extension also holds is refused' => sub {
    spit( "$site/extensions/mine/lib/Demo/Thing.pm", module( 'Demo::Thing', 'local twin' ) );
    my $out = ask( 'require Lazysite::Extensions::Hooks; my ( $f, $l, @bad ) = Lazysite::Extensions::Hooks::check_functions( '
            . '"mine", "' . "$site/extensions/mine.pl" . '", { page_sources => [ { prefix => "x", resolve => "Demo::Thing::says" } ] } ); '
            . 'print "bad: $_->{error}\n" for @bad; print "lib: ", $l // "none", "\n"' );
    like( $out, qr/bad: .*Demo::Thing is also found outside the extension \(\Q$engine\E\/extensions\/demo\/lib\)/,
        'refused, naming the engine extension\'s payload lib' );
    unlink "$site/extensions/mine/lib/Demo/Thing.pm";
    $out = ask( 'require Lazysite::Extensions::Hooks; my ( $f, $l, @bad ) = Lazysite::Extensions::Hooks::check_functions( '
            . '"mine", "' . "$site/extensions/mine.pl" . '", { page_sources => [ { prefix => "x", resolve => "Mine::Thing::says" } ] } ); '
            . 'print "bad: $_->{error}\n" for @bad; print "lib: ", $l // "none", "\n"' );
    unlike( $out, qr/bad:/, 'its own module passes' );
    like( $out, qr{lib: \Q$site\E/extensions/mine/lib}, 'from its own payload lib' );
};

subtest 'without the marker the same trees read as today' => sub {
    unlink "$engine/SHARED-ENGINE" or die $!;
    like( ask('print Lazysite::Extensions::shared_engine() // "no", "\n"'), qr/\Ano\n/, 'not a shared engine' );
    is( found('demo.pl'), "$site/extensions/demo.pl\n", 'the site\'s own copy comes first, as on every host' );
    symlink "$t/elsewhere", "$engine/SHARED-ENGINE" or die $!;
    like( ask('print Lazysite::Extensions::shared_engine() // "no", "\n"'), qr/\Ano\n/, 'a linked marker is no marker' );
};

done_testing();

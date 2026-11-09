#!/usr/bin/perl
# SM1361 (rulings 200-202): ON A SHARED READ-ONLY ENGINE, X1'S RULE IS THE
# ENGINE'S OWN PAYLOAD PATH OR THE SITE'S OWN EXTENSIONS DIR, STILL NO LINKS.
#
# A fixture engine tree - lib/ with the modules the rule reads, extensions/ with
# an extension and its payload, and the image's marker at its root - and a site
# beside it with no engine copy of its own, its extensions dir holding a local
# extension. Each question is asked in a fresh perl with only the engine's lib
# on @INC, as the container's processes have:
#
#   - the engine's extension is found in the engine, and a site's local one in
#     the site's extensions dir;
#   - a site file with a name the engine ships (a planted shadow) is never the
#     one found, and the manager's registry leaves it out and names it;
#   - a linked local descriptor, and a linked local payload, are refused;
#   - a local extension's hook module that an engine extension's payload lib
#     also holds is refused at the index build's check;
#   - the same trees WITHOUT the marker read as today: the site's dir first
#     (the Hestia and deb hosts, where each site keeps its own copy).
#
# Sabotage: drop the shared branch from locate() and the planted shadow is the
# copy found - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);
use File::Temp qw(tempdir);

my $repo   = repo_root();
my $t      = tempdir( 'lazysite-shared-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
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
is( found('mine.pl'), "$site/extensions/mine.pl\n",   'a site\'s own extension is found in its extensions dir' );
is( found('none.pl'), "none\n",                        'a name in neither is none' );

subtest 'the manager\'s registry: the engine first, the shadow left out and named' => sub {
    my $out = ask( 'require Lazysite::Manager::Extensions; $Lazysite::Manager::Extensions::DOCROOT = "'
            . "$site/html"
            . '"; my $r = Lazysite::Manager::Extensions::extension_registry(); '
            . 'print "$_=$r->{$_}\n" for sort keys %$r' );
    like( $out, qr{^extensions/demo\.pl=\Q$engine\E/extensions/demo\.pl$}m, 'demo is the engine\'s' );
    like( $out, qr{^extensions/mine\.pl=\Q$site\E/extensions/mine\.pl$}m,   'mine is the site\'s' );
    unlike( $out, qr{^extensions/demo\.pl=\Q$site\E/}m,                     'the planted copy is not registered' );
    like( $out, qr{a site file has the name of an extension the engine ships; it is not run.*\Q$site\E/extensions/demo\.pl},
        'and it is named' );
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

subtest 'a local hook module an engine extension also holds is refused' => sub {
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

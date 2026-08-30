#!/usr/bin/perl
# SM698 step one: the manager's stylesheet is chosen by a setting, from a
# CLOSED SET of sheets the engine ships.
#
# WHY A NAME AND NOT A PATH. The chosen value reaches a `<link href>` on every
# manager page. A setting that carried a path or a URL would put a
# config-controlled value into that attribute - a stylesheet-injection surface
# in exchange for flexibility nobody asked for, and CSS is not inert: `url()`
# and `@import` make requests, and `display:none` on a confirm button changes
# what a person believes they are pressing. Uploading a sheet is a later step
# (SM698) and will need its own mechanism; it will not be this setting
# quietly widening.
#
# WHY THE FALLBACK IS `classic`. That is the sheet every instance had before
# this setting existed, so an unknown name, a typo, or a missing conf degrades
# to exactly what the operator has today - never to an unstyled manager.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $proc = "$root/lazysite-processor.pl";
plan skip_all => "no $proc" unless -f $proc;

my $src = do { open my $fh, '<', $proc or die $!; local $/; <$fh> };
my ($fn) = $src =~ /(sub _manager_style \{.*?\n\})/s;
ok( $fn, '_manager_style was found' ) or done_testing(), exit;

subtest 'the set is closed, and named in the code' => sub {
    like( $fn, qr/qw\(classic accessible modern\)/,
        'the three shipped sheets are the whole set' );
    like( $fn, qr/return \$SHIPPED\{\$want\} \? \$want : 'classic'/,
        'anything else falls back to classic' )
        or diag( 'A value outside the set must not reach the href. If this '
            . 'becomes a passthrough, the setting is a stylesheet-injection '
            . 'surface.' );
};

subtest 'the sheets it names all exist' => sub {
    for my $name (qw(classic accessible modern)) {
        my $sheet = "$root/starter/lazysite/manager/assets/manager-$name.css";
        ok( -f $sheet, "manager-$name.css ships" )
            or diag( 'The set names a sheet that is not there, so choosing it '
                . 'gives an unstyled manager - worse than not offering it.' );
        my $css = do { open my $fh, '<', $sheet or die $!; local $/; <$fh> };
        cmp_ok( length($css), '>', 10_000,
            "manager-$name.css is a whole stylesheet, not a stub" );
    }
};

subtest 'the layout asks for the chosen sheet by name' => sub {
    my $lay = "$root/starter/lazysite/manager/layout.tt";
    my $l = do { open my $fh, '<', $lay or die $!; local $/; <$fh> };
    like( $l, qr{/manager/assets/manager-\[% manager_style %\]\.css},
        'the link is built from the setting' );
    unlike( $l, qr{/manager/assets/manager\.css},
        'and nothing still asks for the old unnamed sheet' )
        or diag( 'A page still linking manager.css would 404 its stylesheet '
            . 'after this release - the manager would render unstyled.' );
};

subtest 'the old served sheet is cleaned up on upgrade' => sub {
    my $inst = do {
        open my $fh, '<', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $inst, qr/\$docroot/ && qr/manager\/assets\/manager\.css/,
        'install removes the pre-rename served sheet' )
        or diag( 'Left behind it is a stylesheet in the web root that nothing '
            . 'links to - the stale-manager.css state SM109 removed the copy '
            . 'hack to prevent.' );
};

subtest 'the dev server carries every sheet, not just one' => sub {
    my $dev = "$root/tools/lazysite-server.pl";
    plan skip_all => 'no dev server' unless -f $dev;
    my $d = do { open my $fh, '<', $dev or die $!; local $/; <$fh> };
    like( $d, qr/glob\(.*manager-\*\.css/,
        'it copies all the shipped sheets' )
        or diag( 'Copying only the active one makes a style switch appear to '
            . 'do nothing on the dev server while working on a real install. A '
            . 'difference between the two is the worst kind of bug to chase, '
            . 'because the code is right in both.' );
};

done_testing();

#!/usr/bin/perl
# SM911: activating a layout reported nav 0, meta_title 0 and meta_desc 0, and
# warned that nav.conf would have no effect on pages using it - for a layout
# whose served page in that same activation carried five nav items from nav.conf,
# a resolved title and a resolved description.
#
# The detector required the variable to OPEN the directive, so it missed
# `[% FOREACH item IN nav %]`, which is the only way to render a multi-item
# navigation, and it missed `head_title = page_meta_title || page_title`, which
# is the fallback the layouts briefing itself tells authors to write. It punished
# the two patterns the documentation recommends.
#
# Asserted through the REAL validator over a real layout directory, not against a
# pattern retyped here: a test that carries its own copy of the regex passes while
# the engine uses a different one.
#
# The must-nots matter as much as the musts: a layout that renders no navigation
# is a real trap and has to stay caught.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Themes ();

my $i = 0;

# One layout directory per source, validated the way an activation validates it.
sub renders_of {
    my ($layout_src) = @_;
    my $dir = site_tempdir( leaf => 'layout-' . ++$i );
    open my $fh, '>', "$dir/layout.tt" or die $!;
    print {$fh} $layout_src;
    close $fh;
    my $res = Lazysite::Manager::Themes::_validate_layout_dir($dir);
    return $res->{renders} || {};
}

subtest 'the forms an author actually writes are detected' => sub {
    is( renders_of('<nav>[% nav %]</nav>')->{nav}, 1, 'the bare variable' );
    is( renders_of('<nav>[%nav%]</nav>')->{nav},   1, 'with no spaces' );
    is( renders_of('<nav>[% nav | html %]</nav>')->{nav}, 1, 'through a filter' );

    is( renders_of('[% FOREACH item IN nav %]<a>x</a>[% END %]')->{nav}, 1,
        'THE LOOP - the only way to render a multi-item navigation' )
        or diag( 'This is the case the field reported: the warning told an author '
            . 'their nav work was inert at the moment they had done it right.' );

    my $meta = renders_of(
        '[% head_title = page_meta_title || page_title %]<title>[% head_title %]</title>'
            . '[% head_desc = page_meta_desc || page_subtitle %]' );
    is( $meta->{meta_title}, 1, 'the title assignment the <head> contract teaches' );
    is( $meta->{meta_desc},  1, 'and the description assignment beside it' );
};

subtest 'and a layout that renders none of it is still caught' => sub {
    my $none = renders_of('<body>[% content %]</body>');
    is( $none->{nav}, 0, 'no navigation anywhere is still reported as none' )
        or diag('A showcase layout with no nav is a real trap; it must stay caught.');
    is( $none->{content}, 1, 'while the content it does render is reported' );

    is( renders_of('<div class="navbar">[% navbar_html %]</div>')->{nav}, 0,
        'a longer word containing the name does not count' );
    is( renders_of('[%# nav %]<body>[% content %]</body>')->{nav}, 0,
        'a TT comment mentioning it does not count' );
};

subtest 'the delete action names the parameter it wants' => sub {
    my $root = repo_root();
    my $lay  = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Layouts.pm" or die $!;
        local $/;
        <$fh>;
    };
    like( $lay, qr/Layout name required \(layout=<name>\)/,
        'the refusal names the spelling' )
        or diag( 'A partner tried eight spellings and read the same sentence to '
            . 'every one, then concluded the action was unreachable.' );

    my $api = do {
        open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $api, qr/action_layout_delete\(\s*\$params\{layout\}\s*\/\/\s*\$path\s*\)/,
        'and the action accepts `layout=`, as its siblings do' );
};

subtest 'the layouts briefing describes the token element it actually gets' => sub {
    my $doc = do {
        open my $fh, '<', repo_root() . "/starter/docs/ai-briefing-layouts.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $doc, qr/theme_css.*ready-made element/s, 'it says the variable is an element' );
    like( $doc, qr/rel="stylesheet"/,               'and that the normal case is a link' );
    like( $doc, qr/Do not wrap it/, 'and warns against wrapping it in a style tag' )
        or diag( 'An author following the old wording nests a stylesheet link '
            . 'inside a style element.' );
};

done_testing();

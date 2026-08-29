#!/usr/bin/perl
# SM689 remainder: what a manager page's script asks for must survive the render.
#
# THE DEFECT THIS EXISTS TO CATCH. `Text::MultiMarkdown` pairs `<!--` with a
# LATER `-->` when hashing HTML blocks and DISCARDS everything between. The Data
# page lost 20 of its 46 elements on the way to the browser, `rows-panel` among
# them, and it reached the operator as "Could not load rows: can't access
# property style, panel is null" - a script looking for markup the render had
# eaten.
#
# EVERY TEST OF THAT PAGE READ THE SOURCE, and the source was correct
# throughout: correct markup, correct ids, correct JavaScript. The loss happened
# between the source and the browser, which is where nothing was looking. The
# comment protection (SM689) fixes the known cause; this catches the NEXT thing
# that eats markup, for whatever reason.
#
# The check is derived, not listed: a page's script names the ids it needs by
# calling getElementById, so the dependency list is already written down in the
# only place that cannot drift from it.
use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN {
    eval { require Text::MultiMarkdown; 1 }
        or plan skip_all => 'Text::MultiMarkdown not available';
}

my $root = "$FindBin::Bin/../..";
my @pages = sort glob("$root/starter/manager/*.md");
plan skip_all => 'no manager pages' unless @pages;

# Mirror the processor's protection so this measures the render the engine
# actually performs. Kept in step by t/unit/render/70, which asserts the
# processor still protects comments; if that fails, this one is measuring
# something the engine no longer does.
sub render {
    my ($body) = @_;
    my @raw;
    $body =~ s{(<(script|style)\b[^>]*>)(.*?)(</\2>)}{
        my $p = "RAWBLOCK_" . scalar(@raw) . "_END";
        push @raw, "$1$3$4";
        $p
    }gsei;
    $body =~ s{(<!--.*?-->)}{
        my $p = "RAWBLOCK_" . scalar(@raw) . "_END";
        push @raw, "$1";
        $p
    }gse;
    my $h = Text::MultiMarkdown->new( use_fenced_code_blocks => 1 )->markdown($body);
    for my $i ( 0 .. $#raw ) { my $p = "RAWBLOCK_${i}_END"; $h =~ s/\Q$p\E/$raw[$i]/ }
    return $h;
}

my $checked = 0;
my @lost;

for my $page (@pages) {
    my $name = $page;
    $name =~ s{.*/}{};
    my $src = do {
        open my $fh, '<', $page or next;
        local $/;
        <$fh>;
    };
    $src =~ s/\A---\n.*?\n---\n//s;

    # The ids this page's own script fetches by name. Anything it asks for at
    # runtime, it needs at runtime.
    my %want;
    $want{$_} = 1 for $src =~ /getElementById\(\s*'([\w-]+)'/g;
    $want{$_} = 1 for $src =~ /getElementById\(\s*"([\w-]+)"/g;
    next unless keys %want;

    # Only ids the page DECLARES in its own markup are in scope. A page may
    # legitimately fetch something the layout provides, or something its script
    # inserts later; neither is this test's business.
    my %declared;
    $declared{$_} = 1 for $src =~ /\bid="([\w-]+)"/g;

    my $rendered = render($src);
    $checked++;

    for my $id ( sort keys %want ) {
        next unless $declared{$id};
        next if $rendered =~ /id="\Q$id\E"/;
        push @lost, "$name: #$id";
    }
}

cmp_ok( $checked, '>', 0, 'manager pages were rendered and checked' );

is( "@lost", '',
    'every element a page declares and its script fetches survives the render' )
    or diag( "Declared, fetched at runtime, and ABSENT after rendering:\n  "
        . join( "\n  ", @lost )
        . "\n\nThe page source is not the page. This is how SM689 reached an\n"
        . "operator: 20 of the Data page's 46 elements were discarded by the\n"
        . "markdown pass, and every test of that page read the source and\n"
        . "passed. If this fails, find what is eating the markup before\n"
        . "changing the page - the page is usually not the thing that is wrong." );

done_testing();

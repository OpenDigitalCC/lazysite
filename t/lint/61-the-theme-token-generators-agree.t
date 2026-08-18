#!/usr/bin/perl
# SM352: two implementations of the theme's CSS custom properties, pinned.
#
# `generate_theme_css` in the processor renders them into a <style> block;
# `_write_theme_tokens` in Manager::Themes writes the same properties into the
# theme's asset mirror as a file. The file is what a page links now - the last
# inline block on the site side - and the block survives only as the path for a
# site whose mirror predates the change.
#
# ONE OWNER IS NOT AVAILABLE, the same constraint recorded by t/lint/51 for the
# private-store path, t/lint/55 for the security headers and t/lint/60 for the
# manifest generators: the render path loads no Lazysite modules (ADR 0001).
# So the fact exists twice and this asserts the second copy against the first.
#
# THE ESCAPING IS THE PART THAT MUST NOT DRIFT. A theme value reaching a
# stylesheet unescaped is a theme author writing CSS the engine did not
# sanction - and the two copies could drift silently, because the file is only
# read by a browser and nothing in the suite would compare them.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(repo_root);
use Lazysite::Manager::Themes ();

my $root = repo_root();

# The processor's copy, evaluated out of its source - it cannot be loaded,
# because the file runs its main body at file scope.
my $src = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};
my ($sub) = $src =~ /(\nsub generate_theme_css \{.*?\n\}\n)/s;
ok( $sub, 'the processor carries generate_theme_css' );
eval "package ProcCopy; $sub 1;" or die "eval: $@";

# The mirror's copy, run for real.
sub tokens_via_mirror {
    my ($config) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/theme");
    make_path("$d/dest");
    open my $tj, '>', "$d/theme/theme.json" or die $!;
    print {$tj} encode_json( { name => 't', config => $config } );
    close $tj;
    Lazysite::Manager::Themes::_write_theme_tokens( "$d/theme", "$d/dest" );
    return '' unless -f "$d/dest/theme-tokens.css";
    open my $fh, '<', "$d/dest/theme-tokens.css" or die $!;
    local $/;
    my $out = <$fh>;
    close $fh;
    return $out;
}

sub declarations {
    my ($text) = @_;
    # ANY line opening a --theme- property, well-formed or not. An earlier
    # version matched only `--theme-x: y;` and so silently discarded a line
    # carrying an injected second declaration - which made the two copies
    # compare equal precisely when one of them had stopped refusing a key.
    my @d = ( $text // '' ) =~ /^\s*(--theme-.+?)\s*$/mg;
    return [ sort @d ];
}

subtest 'both emit the same declarations for the same config' => sub {
    # The hostile KEY belongs in this subtest rather than the escaping one:
    # a key is not escaped, it is REFUSED, and the two copies refusing
    # different sets is a divergence the value-escaping check cannot see.
    my %config = (
        colour => {
            ink           => '#222',
            paper         => '#fff',
            'x: red; --y' => 'z',
        },
        type => { body => 'Georgia, serif' },
    );
    my $inline = ProcCopy::generate_theme_css( { config => \%config } );
    my $file   = tokens_via_mirror( \%config );

    is_deeply( declarations($file), declarations($inline),
        'the file and the block declare the same properties' )
        or diag( "file:   @{ declarations($file) }\n"
            . "inline: @{ declarations($inline) }\n"
            . 'A page linking the file and a page carrying the block would be '
            . 'styled differently, and only one of them is tested elsewhere.' );
};

subtest 'and strip the same characters from a value' => sub {
    # The escaping. `;{}<>` out, because a theme value is a VALUE - a theme
    # author closing the declaration and opening a rule of their own is writing
    # CSS the engine did not sanction, and on a multi-tenant instance that is
    # somebody else's page.
    my %config = ( colour => { ink => 'red; } body { display:none' } );
    my $inline = ProcCopy::generate_theme_css( { config => \%config } );
    my $file   = tokens_via_mirror( \%config );

    for my $pair ( [ 'inline', $inline ], [ 'file', $file ] ) {
        my ( $what, $text ) = @$pair;
        # Checked on the DECLARATION LINES, not the whole document - the
        # `:root {` wrapper has braces of its own, and matching those was the
        # first version of this assertion failing on the structure it was
        # asserting about rather than on the values inside it.
        my $decls = join "\n", @{ declarations($text) };
        unlike( $decls, qr/[{}]/, "$what: no brace survives a value" )
            or diag( 'A theme author closing the declaration and opening a '
                . 'rule of their own is writing CSS the engine did not '
                . 'sanction - and on a multi-tenant instance that is somebody '
                . "else's page." );
        my $semis = () = $decls =~ /;/g;
        is( $semis, 1, "$what: one terminator, so no second declaration" );
    }
    is_deeply( declarations($file), declarations($inline),
        'and both mangle it identically' );
};

subtest 'both skip a nested object and a bad key' => sub {
    my %config = (
        good      => { a => '1' },
        'bad key' => { b => '2' },
        nested    => { c => { deep => '3' } },
    );
    my $inline = ProcCopy::generate_theme_css( { config => \%config } );
    my $file   = tokens_via_mirror( \%config );
    is_deeply( declarations($file), declarations($inline),
        'the same subset survives both' );
    like( $inline, qr/--theme-good-a/, 'the good one is there' );
};

subtest 'an empty config produces nothing from either' => sub {
    my $inline = ProcCopy::generate_theme_css( { config => {} } );
    my $file   = tokens_via_mirror( {} );
    is( $inline, '', 'no block' );
    is( $file,   '', 'and no file' );
};

done_testing();

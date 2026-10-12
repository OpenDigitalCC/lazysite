#!/usr/bin/perl
# SM887, from the release manager's real-session run (2026-10-12): with an
# editor's layout and theme pulled into the skill's local tree, every page
# linked /lazysite-assets/<layout>/<theme>/main.css and that URL 404'd - the
# directory is written on a real site when a theme is activated, and nothing
# activates one in the container.
#
# The skill's mirror.pl calls the engine's own mirror step. This drives it
# against a pulled-shaped tree with this checkout's engine library, and asks
# the dev server's own predicate whether it would serve the result.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $skill = "$root/skills/claude-ai/lazysite";
plan skip_all => "no skill folder at $skill" unless -d $skill;

sub spew {
    my ( $p, $c ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

# The shape site-context.md has the agent write: the layout directory as
# read_file returned it, and a reconstructed conf naming layout and theme.
sub pulled_site {
    my (%o) = @_;
    my $s  = tempdir( CLEANUP => 1 );
    my $ld = "$s/lazysite/layouts/demo";
    make_path("$ld/themes/plain/assets", "$ld/themes/spare/assets", "$ld/components");
    spew( "$s/lazysite/lazysite.conf", "site_name: Demo\nlayout: demo\ntheme: plain\n" );
    spew( "$ld/layout.json", qq({"name":"demo"}\n) );
    spew( "$ld/layout.tt",   "<html>[% content %]</html>\n" );
    spew( "$ld/themes/plain/theme.json",
        qq({"name":"plain","config":{"colour":{"bg":"#fff","fg":"#111"}}}\n) );
    spew( "$ld/themes/spare/theme.json", qq({"name":"spare"}\n) );
    spew( "$ld/themes/spare/assets/main.css", "body{}\n" );
    if ( $o{misplaced} ) {
        rmdir "$ld/themes/plain/assets";
        spew( "$ld/themes/plain/main.css", "body{color:red}\n" );
    }
    else {
        spew( "$ld/themes/plain/assets/main.css", "body{color:red}\n" );
        spew( "$ld/themes/plain/assets/fonts.css", "/* fonts */\n" );
    }
    return $s;
}

sub run_mirror {
    my ($site) = @_;
    local $ENV{LAZYSITE_LIB} = "$root/lib";
    my $out = qx{perl "$skill/mirror.pl" "$site" 2>&1};
    return ( $? >> 8, $out );
}

subtest 'the pulled theme is published where its pages link it' => sub {
    my $s = pulled_site();
    my ( $rc, $out ) = run_mirror($s);
    is( $rc, 0, 'mirror.pl exits 0' ) or diag($out);
    my $m = "$s/lazysite-assets/demo/plain";
    ok( -f "$m/main.css",  'main.css is at /lazysite-assets/demo/plain/' );
    ok( -f "$m/fonts.css", 'and fonts.css beside it' );
    like( slurp("$m/theme-tokens.css"), qr/--theme-colour-bg: #fff;/,
        "the engine's theme-tokens stylesheet is written, as activation writes it" );
    ok( -s "$m/.fingerprint", 'and the fingerprint [% theme_version %] reads' );
    ok( -f "$s/lazysite-assets/demo/spare/main.css",
        'every theme the layout carries is mirrored, as the engine does (SM820)' );
    like( $out, qr{mirrored demo/plain: \d+ file}, 'and it says what it did' );

    require "$root/tools/lazysite-server.pl";
    ok( main::_dev_serve_direct( "$m/main.css", $s ),
        'the dev server serves the mirrored stylesheet - the 404 the session saw' );
};

subtest 'a theme with nothing to mirror is a failure, with the reason' => sub {
    my $s = pulled_site( misplaced => 1 );
    my ( $rc, $out ) = run_mirror($s);
    is( $rc, 1, 'exit 1 when the ACTIVE theme has no mirror' );
    like( $out, qr/NOT mirrored demo\/plain:.*not in assets\//s,
        "the engine's reason is passed on - CSS beside theme.json" );
    like( $out, qr/FAIL: the active theme 'plain'/, 'and the verdict names the theme' );
};

subtest 'no layout named is a usage problem, not a verdict' => sub {
    my $s = tempdir( CLEANUP => 1 );
    make_path("$s/lazysite");
    spew( "$s/lazysite/lazysite.conf", "site_name: Starter\n" );
    my ( $rc, $out ) = run_mirror($s);
    is( $rc, 2, 'exit 2' );
    like( $out, qr/names no layout/, 'and it says what is missing' );
    ok( !-e "$s/lazysite-assets", 'nothing is written' );
};

subtest 'serve.sh start mirrors before it serves' => sub {
    my $src = slurp("$skill/serve.sh");
    like( $src, qr/perl "\$SKILL_DIR\/mirror\.pl" "\$SITE"/, 'serve.sh calls mirror.pl' );
    like( $src, qr/^start\)\n\s+\[ -d "\$SITE" \] && mirror\n\s+if running/m,
        'on every start, ahead of the already-running early exit' );
    like( slurp("$skill/reference/site-context.md"), qr/mirror\.pl/,
        'and site-context.md says so' );
};

done_testing();

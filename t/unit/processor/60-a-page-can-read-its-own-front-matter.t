#!/usr/bin/perl
# SM459: a custom front-matter key was readable by every page EXCEPT the one
# that declared it.
#
# The page SCAN passes non-reserved keys through, so an index renders
# [% t.status %] fine. The page's own stash took only tt_page_var plus an
# explicit list, so [% status %] on the declaring page was empty. An author
# wanting one fact in both places wrote it twice - top-level for the index,
# again inside tt_page_var for their own layout - and the two copies drifted
# with nothing comparing them. That is exactly the duplication the metadata
# exists to remove.
#
# TWO THINGS THIS MUST NOT BREAK, both asserted:
#
#   ESCAPING. SEC-2026-07 (H5) escapes author-controllable front matter at the
#   single point it enters the stash, so every layout - including ones we do
#   not ship and cannot edit - emits it safely without needing `| html`.
#   Custom keys arrive escaped, and PREFIXED, so they cannot collide with a
#   site var or a tt_page_var and change the meaning of something an author
#   already depends on.
#
#   ONE RESERVED LIST. The scan and the stash now share it. Two copies would
#   drift, which is the same defect one level up - SM435 and SM457 were both
#   exactly that.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_test_site run_processor);
use File::Temp qw(tempdir);

my $src = do {
    open my $fh, '<', repo_root() . '/lazysite-processor.pl' or die $!;
    local $/;
    <$fh>;
};

subtest 'the reserved list is declared ONCE and shared' => sub {
    my $decls = () = $src =~ /^our %FRONT_MATTER_RESERVED = map/mg;
    is( $decls, 1, 'one declaration' );
    my $uses = () = $src =~ /FRONT_MATTER_RESERVED/g;
    cmp_ok( $uses, '>=', 3, 'used by the scan and by the stash' )
        or diag( 'Two copies of the reserved list would let the scan and the '
            . 'page disagree about what is custom - the very asymmetry this '
            . 'change removes, one level up.' );
    unlike( $src, qr/my %reserved = map \{ \$_ => 1 \} qw\(\s*\n\s*url title/,
        'the scan no longer carries its own copy' );
};

subtest 'custom keys reach the stash, escaped and prefixed' => sub {
    my ($stash) = $src =~ /(page_title\s*=> _esc_html.*?keys %\{\$meta\})/s;
    ok( defined $stash, 'the stash block is present' )
        or BAIL_OUT('cannot find the custom-key block');

    like( $stash, qr/"page_\$_"/,
        'exposed as page_<key>, not bare' )
        or diag( 'A bare key could collide with a site var or a tt_page_var '
            . 'and silently change what an author already depends on.' );
    like( $stash, qr/_esc_html\( \$meta->\{\$_\} \)/,
        'and ESCAPED, like every other author-controllable field here' )
        or diag( 'H5 escapes at this single point precisely so a layout we do '
            . 'not ship cannot emit an author string raw. An unescaped custom '
            . 'key would hand every such layout an injection.' );
    like( $stash, qr/!ref \$meta->\{\$_\}/,
        'scalars only - an array has no single escaped form' );
    like( $stash, qr/!\/\^\(\?:tt_\|_\)\//,
        'control and internal keys stay out' );
};

subtest 'a reserved key is not duplicated as page_<key>' => sub {
    # title already arrives as page_title, escaped, from its own line. Letting
    # the map produce a second one would be harmless today and a divergence
    # waiting to happen.
    my ($stash) = $src =~ /(page_title\s*=> _esc_html.*?keys %\{\$meta\})/s;
    like( $stash, qr/!\$FRONT_MATTER_RESERVED\{\$_\}/,
        'reserved keys are skipped by the map' );
};

# --- BEHAVIOUR, not source text -------------------------------------------
#
# Everything above greps the source, and this week has twice shown that a
# source assertion cannot tell PRESENT from REACHABLE - a call site deleted
# while the definition still matched, and a message left in place after an
# early return made it dead. So the claims that matter are rendered.
subtest 'RENDERED: a page reads its own custom key' => sub {
    my $d = tempdir( CLEANUP => 1 );
    setup_test_site($d);

    # A layout that prints the custom key, as an author's would.
    open my $lt, '>', "$d/lazysite/layouts/test/layout.tt" or die $!;
    print {$lt} '<html><body>STATUS=[% page_status %] '
        . 'OWNER=[% page_owner %] [% content %]</body></html>';
    close $lt;

    open my $pg, '>', "$d/task.md" or die $!;
    print {$pg} "---\ntitle: A task\nstatus: in-progress\n"
        . "owner: <b>alice</b>\n---\n\nbody\n";
    close $pg;

    my $out = run_processor( $d, '/task' );
    like( $out, qr/STATUS=in-progress/,
        'the declaring page can read its own front matter' )
        or diag( 'This is the asymmetry: the scan could read it and the page '
            . 'could not, so the author had to write the fact twice.' );

    # THE SECURITY CLAIM, rendered rather than asserted about the source.
    like( $out, qr/OWNER=&lt;b&gt;alice&lt;\/b&gt;/,
        'and it arrives ESCAPED' )
        or diag( 'H5 escapes author-controllable front matter at the single '
            . 'point it enters the stash, so a layout we do not ship cannot '
            . 'emit it raw. An unescaped custom key would be an injection in '
            . 'every such layout.' );
    unlike( $out, qr/<b>alice<\/b>/,
        'the raw markup does not reach the page' );
};

subtest 'RENDERED: a control key stays out' => sub {
    my $d = tempdir( CLEANUP => 1 );
    setup_test_site($d);
    open my $lt, '>', "$d/lazysite/layouts/test/layout.tt" or die $!;
    print {$lt} '<html><body>L=[% page_layout %] T=[% page_tt_x %]</body></html>';
    close $lt;
    open my $pg, '>', "$d/c.md" or die $!;
    print {$pg} "---\ntitle: C\ntt_x: leaked\n---\n\nbody\n";
    close $pg;
    my $out = run_processor( $d, '/c' );
    unlike( $out, qr/T=leaked/, 'tt_ keys are not re-exposed as page_tt_*' );
    unlike( $out, qr/L=test/,
        'and a reserved key is not duplicated as page_<key>' );
};

done_testing();

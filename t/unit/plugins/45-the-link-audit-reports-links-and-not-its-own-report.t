#!/usr/bin/perl
# SM922: an operator ran the link audit on a live site and got ten broken internal
# links. Two were real. Every other entry traced to a fault in the audit, and the
# count moved 10 -> 8 -> 10 -> 7 across four runs WITH NO CHANGE TO THE SITE -
# because the audit was reading its own last report as site content.
#
# A check whose output is mostly noise does not get read, and then the real entries
# are invisible, which is worse than no check: the absence of a check is at least
# known.
#
# One subtest per fault, because each is a different kind of mistake and a single
# "the count is lower" assertion would pass with any of them still present.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $PLUGIN = repo_root() . '/plugins/audit.pl';
ok( -f $PLUGIN, 'the audit plugin is present' ) or BAIL_OUT('no plugin');

sub w {
    my ( $p, @lines ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r ) unless -d ( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} join( "\n", @lines ), "\n";
    close $fh;
    return;
}

# A docroot with a home page and nothing else wrong.
sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite");
    w( "$d/index.md", '---', 'title: Home', '---', 'home' );
    return $d;
}

sub audit {
    my ($d) = @_;
    return scalar qx{$^X \Q$PLUGIN\E --docroot \Q$d\E 2>/dev/null};
}

sub broken_in {
    my ($out) = @_;
    my ($block) = $out =~ /BROKEN LINKS \(\d+\)(.*?)\n\nWITHHELD/s;
    return () unless defined $block;
    my @rows;
    while ( $block =~ /^\s+(\S+)\s+->\s+(\S+)$/mg ) { push @rows, "$1 -> $2" }
    return @rows;
}

sub withheld_in {
    my ($out) = @_;
    my ($block) = $out =~ /WITHHELD TARGETS \(\d+\)(.*?)\n\nSUMMARY/s;
    return () unless defined $block;
    my @rows;
    while ( $block =~ /^\s+(\S+)\s+->\s+(\S+)$/mg ) { push @rows, "$1 -> $2" }
    return @rows;
}

# --- fault 1 and 2: a link is something in PROSE --------------------------------

subtest 'code and examples are not links' => sub {
    my $d = site();
    w( "$d/page.md",
        '---', 'title: Page', '---',
        'A real [link](/missing-real) in prose.',
        '',
        '```html',
        '<a href="/fenced-example">Book a visit</a>',
        '![photo](img/x)',
        '```',
        '',
        '<script>',
        'body.innerHTML = BUILD[listId](key);',
        '</script>',
        '',
        '    [an indented example](/indented-example)',
        '',
        'And `[an inline code link](/inline-example)` too.',
        '',
        # A TILDE FENCE, which only the fence pass can remove: a backtick fence is
        # also removed by the inline-code-span pass, so a sabotage that deleted the
        # fence pass went UNNOTICED until this case existed. Two mechanisms covering
        # one case means one of them is untested.
        '~~~html',
        '<a href="/tilde-example">also an example</a>',
        '~~~',
    );
    my @broken = broken_in( audit($d) );
    is_deeply( \@broken, ['page.md -> /missing-real'],
        'the prose link is reported and nothing else is' )
        or diag explain \@broken;

    # Named individually, because each was a separate entry on the operator's
    # report and `](key)` is the one that reads as a bug in the site.
    my $out = audit($d);
    unlike( $out, qr{-> /key\b},               'a JS index call is not a link' );
    unlike( $out, qr{-> /fenced-example},      'nor is a fenced example' );
    unlike( $out, qr{-> /indented-example},    'nor an indented one' );
    unlike( $out, qr{-> /inline-example},      'nor one inside backticks' );
    unlike( $out, qr{-> /img/x},               'nor an image path in an example' );
    unlike( $out, qr{-> /tilde-example},
        'nor one in a TILDE fence, which only the fence pass removes - a backtick '
            . 'fence is also caught by the inline-span pass, so without this case '
            . 'deleting the fence pass changed nothing a test could see' );
};

# --- fault 3: relative means relative -------------------------------------------

subtest 'a relative link resolves against the page it is on' => sub {
    my $d = site();
    w( "$d/manager/handlers.md", '---', 'title: Handlers', '---',
        '[the key page](key) and [up one](../index) and [gone](nowhere)' );
    w( "$d/manager/key.md",      '---', 'title: Key',      '---', 'key' );

    my @broken = broken_in( audit($d) );
    is_deeply( \@broken, ['manager/handlers.md -> /manager/nowhere'],
        'the sibling resolves, the parent resolves, and only the real miss is '
            . 'reported - AT ITS REAL PATH, not at the site root' )
        or diag explain \@broken;

    unlike( audit($d), qr{-> /key$}m,
        'the old behaviour reported `/key`, a path nobody ever wrote' );
};

# --- fault 4: the fallback chain -------------------------------------------------

subtest 'a system page answers through the fallback chain' => sub {
    my $d = site();
    w( "$d/lazysite/templates/system/login.md", '---', 'title: Sign in', '---', 'login' );
    w( "$d/page.md", '---', 'title: Page', '---',
        '[sign in](/login) and [claim](/claim)' );

    my $out = audit($d);
    unlike( $out, qr{-> /login\b},
        'the engine default resolves it, and the shipped check already asserted '
            . 'that it answers 200' );
    like( $out, qr{-> /claim\b},
        'and a system page with NO file anywhere is still reported - the chain is '
            . 'consulted, not assumed' );
};

# --- fault 5 and the ruling: withheld is not absent -----------------------------

subtest 'a gated target is its own state, not a broken link' => sub {
    my $d = site();
    ( my $private = $d ) =~ s{/([^/]+)\z}{/$1-lazysite-private};
    w( "$private/docs/secret.md", '---', 'title: Draft', '---', 'draft' );
    w( "$d/links.md", '---', 'title: Links', '---',
        '[the draft](/docs/secret) and [really gone](/docs/no-such-thing)' );

    my $out = audit($d);
    is_deeply( [ broken_in($out) ], ['links.md -> /docs/no-such-thing'],
        'the gated page is NOT in the broken list' );
    is_deeply( [ withheld_in($out) ], ['links.md -> /docs/secret'],
        'it is in its own list' );
    like( $out, qr/declined to judge/,
        'and the section says what it does not know, rather than implying the link '
            . 'is fine - nobody can confirm a gated link resolves from this report' );
};

# --- fault 6: the report is not a page any more ----------------------------------

subtest 'the audit cannot scan its own report, because it is not content' => sub {
    my $d = site();
    w( "$d/page.md", '---', 'title: Page', '---', '[gone](/still-missing)' );

    # The report page a site that ran this plugin before 0.15.2 already has, with
    # last run's findings in it - which is exactly what used to come back as a new
    # set of broken links attributed to the report itself.
    w( "$d/manager/audit-report.md", '---', 'title: Link Audit Report', '---',
        '<td><code>/stale-finding-one</code></td>',
        '<a href="/stale-finding-two">x</a>' );

    my $json = qx{$^X \Q$PLUGIN\E --scan --docroot \Q$d\E 2>/dev/null};
    my $res  = eval { decode_json($json) };
    ok( $res && $res->{ok}, 'the scan answers JSON' ) or diag "output: $json";

    ok( !-e "$d/manager/audit-report.md",
        'the page the plugin used to write is REMOVED - leaving it would leave a '
            . 'stale report at a URL nothing updates' );
    ok( -f "$d/lazysite/audit/link-report.json",
        'and the findings are in a store under lazysite/, which the page walks '
            . 'already skip by path' );

    my @targets = map { $_->{target} } @{ $res->{report}{broken} };
    is_deeply( [ sort @targets ], ['still-missing'],
        'last run\'s findings are not re-reported as this run\'s' )
        or diag explain \@targets;

    # And the second run agrees with the first, which is the property the operator
    # lost: the count moved 10 -> 8 -> 10 -> 7 with no change to the site.
    my $again = decode_json( scalar qx{$^X \Q$PLUGIN\E --scan --docroot \Q$d\E 2>/dev/null} );
    is( scalar @{ $again->{report}{broken} }, scalar @{ $res->{report}{broken} },
        'two runs in a row report the same number' );
};

subtest 'the action returns the findings, so nothing has to fetch a page' => sub {
    my $d = site();
    w( "$d/orphan.md", '---', 'title: Orphan', '---', 'nothing links here' );
    my $res = decode_json( scalar qx{$^X \Q$PLUGIN\E --scan --docroot \Q$d\E 2>/dev/null} );

    ok( exists $res->{report},   'the result carries the report' );
    ok( !exists $res->{report_url},
        'and NOT a URL to fetch - the URL was the report being a page, which is '
            . 'what let the audit find it and why it could not be re-run in place' );
    ok( ( grep { $_->{page} eq 'orphan' } @{ $res->{report}{orphaned} } ),
        'orphans come back as rows the manager can render' );
    ok( $res->{report}{generated_ymd}, 'with a timestamp of its own' );
};

# --- the descriptor matches what the manager now does ---------------------------

subtest 'the run action no longer declares a URL to open' => sub {
    my $desc = decode_json( scalar qx{$^X \Q$PLUGIN\E --describe} );
    my ($run) = grep { $_->{id} eq 'run' } @{ $desc->{actions} // [] };
    ok( $run, 'the run action is declared' );
    ok( !$run->{on_complete},
        'with no on_complete - a declaration the manager ignores is worse than '
            . 'none, and there is no URL to open any more' );
    ok( !$run->{result_key}, 'and no result_key' );
};

done_testing();

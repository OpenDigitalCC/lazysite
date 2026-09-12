#!/usr/bin/perl
# SM853: every manager page's script PARSES, after the engine has rendered it.
#
# The Handlers page shipped in 0.13.13 with its entire 26KB script unable to
# compile: convert_p_links had spliced an anchor into `BUILD[listId](key)`. Every
# panel sat at "Loading...", every button did nothing, and nothing anywhere said
# so - not the engine log, not the browser console the operator never opens, not
# one of 13,893 tests. The site agent found it by compiling the script in a
# browser, two hours after the build was tagged and with beta waiting on the pass.
#
# WHY THE RENDERED PAGE, NOT THE SOURCE. The source was correct. A check that
# read starter/manager/*.md would have passed happily while the served page was
# broken - which is the whole lesson: verify what renders (the source of truth
# for a page is the response, not the file).
#
# WHY `node --check` AND NOT A PARSER OF OUR OWN. A browser's answer is what
# matters, and node's parser is the same family. Where node is absent this skips:
# a release tarball on a host without it still installs, and the gate that runs
# here is the one that matters.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor site_tempdir setup_test_site);

my $root = repo_root();
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;

my @pages = sort glob("$root/starter/manager/*.md");
cmp_ok( scalar @pages, '>=', 15, 'the canary: found the manager pages' );

SKIP: {
    skip 'no node on this host - a parser is not ours to ship', 1 unless length $node;

    my $d = site_tempdir();
    setup_test_site($d);
    my $tmp = tempdir( CLEANUP => 1 );

    # A page whose own script sits behind a capability conditional cannot be
    # reached from a fixture with no session. Named, so that a page that stops
    # being checked for any OTHER reason is a failure rather than a silence.
    my %behind_a_conditional =
        ( config => 'its script is inside [% IF manager_caps.manage_config %]' );

    my ( @broken, @uncovered, $checked );
    $checked = 0;
    for my $page (@pages) {
        ( my $name = $page ) =~ s{.*/}{};
        $name =~ s{\.md\z}{};

        open my $in, '<', $page or die "$page: $!";
        my $src = do { local $/; <$in> };
        close $in;

        # The gate is the page's scripts, not its access rule: a manager page
        # declares `auth: manager` and this fixture has no session.
        $src =~ s/^auth:.*\n//m;

        open my $out, '>', "$d/lint136-$name.md" or die $!;
        print {$out} $src;
        close $out;

        my $rendered = run_processor( $d, "/lint136-$name" );
        my $n        = 0;
        while ( $rendered =~ m{<script\b([^>]*)>(.*?)</script\s*>}gsi ) {
            my ( $attrs, $js ) = ( $1, $2 );
            next if $attrs =~ /\bsrc\s*=/;    # a file, not inline source
            next if $attrs =~ /type\s*=\s*["']?(?:application\/json|text\/template)/i;
            next unless $js =~ /\S/;
            $n++;
            my $f = "$tmp/$name-$n.js";
            open my $jf, '>', $f or die $!;
            print {$jf} $js;
            close $jf;
            my $err = `\Q$node\E --check \Q$f\E 2>&1`;
            $checked++;
            next if $? == 0;
            my ($first) = ( split /\n/, $err )[0] // '';
            push @broken, "$name script $n: $first";
        }
        push @uncovered, $name if $n == 0 && $src =~ /<script/;
    }

    is_deeply( \@broken, [], 'every manager page\'s rendered scripts parse' )
        or diag( join "\n", @broken,
        'A script that does not parse defines none of its functions, so the '
            . 'page renders its chrome and does nothing at all.' );

    is_deeply( [ sort @uncovered ], [ sort keys %behind_a_conditional ],
        'and the pages this cannot reach are the ones named here' )
        or diag( 'Unreached: ' . join( ', ', sort @uncovered )
            . '. A page that renders no script of its own '
            . 'here is either behind a conditional (name it above, with which one) '
            . 'or not rendering - and the second is the defect this gate is for.' );

    cmp_ok( $checked, '>=', 20, "it checked something: $checked script(s) parsed" );
}

done_testing();

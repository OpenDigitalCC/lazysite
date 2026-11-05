#!/usr/bin/perl
# SM1142 (R5): THE WORD IS FREE.
#
# The release manager, 2026-10-17: "prefer full rename, so that the namespace of
# plugin is fully free, in case we need it in future - its tech debt to have it
# hidden inside, sooner its done the cheaper." So the rename was not limited to
# what an operator meets: the directory, the conf key, the module namespace, the
# action names, the template variable, the manager pages, the tests and the
# docs all say extension. CLAUDE.md asks a rename over ten files for an
# invariant; this is it, and it is a census of the whole word, case-blind, in
# every functional file - code, the starter tree, installers, packaging,
# configuration, the docs that are not history, and the tests' own code.
#
# WHAT MAY STILL SAY IT, and only these:
#
#   - HISTORY, which records what was true when it was written: the CHANGELOG,
#     the release archive, debian/changelog, the filings, the reviews, the ADRs,
#     the decision register, the security register, UPGRADE.md's entries and
#     reported-issues.md. A filing's NAME is history too, so a reference to one
#     (`SM640-plugins-should-be-...`) is allowed wherever it appears, and so is a
#     path into docs/feature-requests/ or docs/adr/.
#   - THIRD-PARTY NAMES: Template::Plugin::JSON::Escape and its Debian package,
#     and the website's comparison pages, which are about other products'
#     plugins.
#   - OLD-NAME REGIONS, between `# old-name: begin (...)` and `# old-name: end`,
#     in the files listed in %REGIONS and nowhere else: the upgrade step that
#     converts a site, the check that names a list written back under the old
#     name, the manager API's refusal that tells a caller the new spelling, and
#     the tests that drive each of those. Each must name the old spelling to do
#     its job. A region in any other file fails, so the exemption cannot spread.
#
# Sabotage: put `use Lazysite::Manager::Plugins;` back anywhere under lib/, or
# an old-name region in a file not listed, and this fails naming the line.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @HISTORY = (
    qr{\ACHANGELOG\.md\z},
    qr{\Adebian/changelog\z},
    qr{\Adocs/(?:feature-requests|review|releases|adr)/},
    qr{\Adocs/decision-register\.md\z},
    qr{\Asecurity/},
    qr{\AUPGRADE\.md\z},
    qr{\Areported-issues\.md\z},
    qr{\Awebsite/},
    qr{\Adownload/},
    qr{\At/vendor/},
);

# The files that may carry an old-name region, and how many each carries.
my %REGIONS = (
    'install.pl'                                                => 1,
    'tools/lazysite-check.pl'                                   => 1,
    'lazysite-manager-api.pl'                                   => 1,
    't/lib/PreRenameSite.pm'                                    => 1,
    't/tools/306-an-upgrade-moves-a-site-to-extensions.t'       => 1,
    't/lint/125-the-registry-has-one-meaning.t'                 => 1,
    't/unit/manager/198-enabling-an-extension-does-not-write-a-second-list.t' => 1,
    't/unit/manager/168-the-old-action-spelling-is-refused-by-name.t'         => 1,
);

# Tokens that may contain the word wherever they appear.
my @ALLOWED = (
    qr{Template::Plugin[\w:]*},
    qr{libtemplate-plugin[\w-]*},
    qr{\bSM\d+[a-z]?-[\w-]+},                       # a filing's name
    qr{\bdocs/(?:feature-requests|adr|review|releases)/[\w/.-]+},
    qr{\b[A-Z]+-PLUGINS-[A-Z]+\b},                  # a security register id
    qr{t/lint/307-the-old-name-for-extensions-is-not-used\.t},
);

# SM1142 S2: what the slices still to land in this stack rename - S3 the
# installers and packaging, S4 the docs, the starter docs and the test files'
# names. Each slice deletes its lines; none survives the stack.
my @PENDING = (
    qr{\Ainstallers/}, qr{\Adebian/}, qr{\Atools/lazysite-hestia-domain\.pl\z},    # S3
    qr{\Adocs/}, qr{\AREADME\.md\z}, qr{\Askills/}, qr{\Astarter/lazysite/templates/docs/},
    qr{\Astarter/index\.md\z},                                                     # S4
);
push @ALLOWED, qr{t/unit/plugins\b[\w/.-]*}, qr{\b\d+[a-z]?-[\w-]*[Pp]lugin[\w-]*\.t\b};    # S4

my @files = grep { length } split /\n/, `git -C \Q$root\E ls-files`;
# This file states the rule, so it names the word; it is the one exemption by name.
@files = grep { $_ ne 't/lint/307-the-old-name-for-extensions-is-not-used.t' } @files;

my ( @bad, @stray, %regions, $scanned );
FILE: for my $rel (@files) {
    for my $h ( @HISTORY, @PENDING ) { next FILE if $rel =~ $h }
    my $f = "$root/$rel";
    next unless -f $f && !-l $f && -T $f;
    $scanned++;
    push @bad, "$rel: the file's name" if $rel =~ /plugin/i && $rel !~ m{\At/};    # S4: t/
    open my $fh, '<:raw', $f or do { push @bad, "$rel: unreadable"; next };
    my ( $n, $in ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        $n++;
        if ( $l =~ /^\s*# old-name: begin \(SM\d+/ ) {
            $regions{$rel}++;
            push @stray, "$rel:$n" unless $REGIONS{$rel};
            $in = 1;
            next;
        }
        if ( $l =~ /^\s*# old-name: end\b/ ) { $in = 0; next }
        next if $in;
        next unless $l =~ /plugin/i;
        my $t = $l;
        $t =~ s/$_//g for @ALLOWED;
        push @bad, "$rel:$n: $l" if $t =~ /plugin/i;
    }
    close $fh;
}

cmp_ok( $scanned, '>', 1000, "the tracked files are scanned ($scanned)" );
is_deeply( \@bad, [], 'no functional file uses the old name' )
    or diag( join( '', map { /\n\z/ ? $_ : "$_\n" } @bad[ 0 .. ( $#bad < 60 ? $#bad : 59 ) ] )
        . ( @bad > 60 ? '... and ' . ( @bad - 60 ) . " more\n" : '' )
        . "SM1142 (R5): say extension. History, third-party names and the listed\n"
        . "old-name regions are the only exemptions.\n" );
is_deeply( \@stray, [], 'an old-name region appears only in a file listed for one' )
    or diag "unlisted old-name regions: @stray";
for my $rel ( sort keys %REGIONS ) {
    is( $regions{$rel} // 0, $REGIONS{$rel}, "$rel carries its $REGIONS{$rel} old-name region(s), no more" );
}

done_testing();

#!/usr/bin/perl
# SM1343 (rulings 56-57): ADDRESS LISTS ARE ADDRESS PROFILES, RENAMED OUTRIGHT.
#
# The release manager's request (24 October 2026) made the named address lists
# profiles with no kind, and ruling 56 renamed them outright: no alias for the old
# actions (address-lists, address-list-set, address-list-delete), the MCP tool
# (list_address_lists), the store file (address-lists.json), the users tool's
# commands, the modules, the manager page, the docs or the briefings. CLAUDE.md asks
# a rename over ten files for an invariant; this is it, a census of the old
# spellings in every functional file - code, the starter tree (docs and briefings
# among it), installers, packaging, configuration, the docs that are not history,
# and the tests' own code and names.
#
# WHAT MAY STILL SAY IT, and only these:
#
#   - HISTORY, which records what was true when it was written: the CHANGELOG,
#     the release archive, the filings, the reviews, the ADRs, the security
#     register and the doc index (generated from the titles it lists). A filing's
#     name is history too, so a reference to one is allowed wherever it appears.
#   - THE OLD STORE'S NAME, `address-lists.json`: the upgrade converts it, and the
#     engine and the check must recognise a site where it was left unconverted.
#   - A LINE THAT DATES IT, naming 0.16.5 (the release that renamed it) or SM1343 /
#     SM1345: an upgrade note says what the thing was called before.
#   - OLD-NAME REGIONS, between `# old-address-name: begin (SM1343 ...)` and
#     `# old-address-name: end`, in the files listed in %REGIONS and nowhere else:
#     the refusals that tell a caller the new name (control API and MCP, the users
#     tool's commands), the upgrade that converts the old store (SM1345) and the
#     tests that drive them. A region in any other file
#     fails, so the exemption cannot spread. (A marker of its own, so it is not
#     read as SM1142's `old-name` regions.)
#
# The spellings are case-sensitive: "address list(s)", "Address list(s)",
# address-list(s), address_list(s), AddressLists, list_address_lists, and (ruling
# 105) the template test's old methods visitor.in_list and visitor.in_any.
#
# Sabotage: put `use Lazysite::Auth::AddressLists;` back anywhere under lib/, or an
# old-address-name region in a file not listed, and this fails naming the line.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $SELF = 't/lint/320-address-lists-are-address-profiles-by-name.t';

my $OLD = qr{address[ _-]lists?\b|Address[ _-]lists?\b|AddressLists|list_address_lists|visitor\.in_list\b|visitor\.in_any\b(?!_)};

my @HISTORY = (
    qr{\ACHANGELOG\.md\z},
    qr{\Adebian/changelog\z},
    qr{\Adocs/(?:feature-requests|review|releases|adr)/},
    qr{\Adocs/decision-register\.md\z},
    qr{\Adocs/SECURITY\.md\z},    # the register's entries for 0.15.10 and later
    qr{\Asecurity/},
    qr{\AUPGRADE\.md\z},
    qr{\Areported-issues\.md\z},
    qr{\Awebsite/},
    qr{\Adownload/},
    qr{\At/vendor/},
    qr{\Adocs/INDEX\.md\z},
);

# The files that may carry an old-address-name region, and how many each carries.
my %REGIONS = (
    'lib/Lazysite/ControlApi/Actions.pm' => 1,
    'tools/lazysite-users.pl'            => 1,
    't/integration/266-an-address-profile-is-read-by-a-manager-and-changed-by-the-operator.t'          => 1,
    't/unit/users/52-the-address-profile-store-is-written-by-the-users-tool.t'                       => 1,
    't/unit/odoo/112-an-operation-is-told-whether-the-call-came-from-an-address-profile.t'           => 1,
    'install.pl'                                                                                    => 1,
    't/tools/315-an-upgrade-makes-address-profiles-and-no-site-changes-behaviour.t'                  => 1,
    't/tools/331-an-unreadable-private-folder-is-named-not-warned.t'                               => 1,
    'tools/lazysite-check.pl'                                                                       => 1,
    't/unit/tools/85-the-check-names-an-address-store-left-unconverted.t'                           => 1,
    't/unit/processor/133-a-template-can-test-an-address.t'                                         => 1,
);

# Tokens that may contain an old spelling wherever they appear.
my @ALLOWED = (
    qr{address-lists\\?\.json},                        # the store the upgrade converts (or a regex of it)
    qr{\bSM\d+[a-z]?-[\w-]+},                           # a filing's name
    qr{\bdocs/(?:feature-requests|adr|review|releases)/[\w/.-]+},
);

my @files = grep { length && $_ ne $SELF } split /\n/, `git -C \Q$root\E ls-files`;

my ( @bad, @stray, %regions, $scanned );
FILE: for my $rel (@files) {
    for my $h (@HISTORY) { next FILE if $rel =~ $h }
    my $f = "$root/$rel";
    next unless -f $f && !-l $f && -T $f;
    $scanned++;
    push @bad, "$rel: the file's name" if $rel =~ m{address[-_]lists?}i;
    open my $fh, '<:raw', $f or do { push @bad, "$rel: unreadable"; next };
    my ( $n, $in ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        $n++;
        if ( $l =~ /^\s*# old-address-name: begin \(SM1343/ ) {
            $regions{$rel}++;
            push @stray, "$rel:$n" unless $REGIONS{$rel};
            $in = 1;
            next;
        }
        if ( $l =~ /^\s*# old-address-name: end\b/ ) { $in = 0; next }
        next if $in;
        next unless $l =~ $OLD;
        next if $l =~ /\b0\.16\.5\b|\bSM134[35]\b/;    # a line that dates the rename
        my $t = $l;
        $t =~ s/$_//g for @ALLOWED;
        push @bad, "$rel:$n: $l" if $t =~ $OLD;
    }
    close $fh;
}

cmp_ok( $scanned, '>', 1000, "the tracked files are scanned ($scanned)" );
is_deeply( \@bad, [], 'no functional file uses an address-list name' )
    or diag( join( '', map { /\n\z/ ? $_ : "$_\n" } @bad[ 0 .. ( $#bad < 60 ? $#bad : 59 ) ] )
        . ( @bad > 60 ? '... and ' . ( @bad - 60 ) . " more\n" : '' )
        . "SM1343 (ruling 56): say address profile. History, the old store's name, a line\n"
        . "naming 0.16.5 or SM1343/SM1345, and the listed old-address-name regions are the\n"
        . "only exemptions.\n" );
is_deeply( \@stray, [], 'an old-address-name region appears only in a file listed for one' )
    or diag "unlisted old-address-name regions: @stray";
for my $rel ( sort keys %REGIONS ) {
    is( $regions{$rel} // 0, $REGIONS{$rel}, "$rel carries its $REGIONS{$rel} old-address-name region(s), no more" );
}

done_testing();

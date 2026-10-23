#!/usr/bin/perl
# SM496: lazysite-check warns about a capability NOBODY HAS DECIDED ON, and
# stays silent about one somebody declined. Before, absent was the only state
# and the warning was permanent until a CLI command ran on the box - which is
# exactly the sysadmin dependency the operator's requirement forbids. The
# remedy line now names the Groups page banner first, the CLI second.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Auth::Settings ();
use TestHelper qw(repo_root);

my $check = repo_root() . '/tools/lazysite-check.pl';

sub site_with {
    my (%group_settings) = @_;
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    # manager: enabled - without it the check stops at the bootstrap warning
    # and the capability block under test never runs.
    print {$cf} "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $gf, '>', "$d/lazysite/auth/groups" or die $!;
    print {$gf} "ops: alice\n";
    close $gf;
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print {$uf} "alice:x\n";
    close $uf;
    open my $sf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print {$sf} encode_json( { ops => \%group_settings } );
    close $sf;
    my $cmd = join ' ', map { quotemeta } $^X, $check, '--docroot', $d;
    return scalar `$cmd 2>&1`;
}

# Every capability the check expects, granted - the clean baseline.
#
# SM633: DERIVED, not copied. This was a hand-maintained second list, so the
# release that added a capability made the clean baseline incomplete and this
# whole file failed on the CORRECT behaviour - the check correctly reporting
# an undecided capability that the fixture had simply never granted. The two
# remote channels are excluded for the same reason lazysite-check.pl excludes
# them: they are doors, not decisions a group makes here.
my @all = grep { $_ ne 'api' && $_ ne 'mcp' } @Lazysite::Auth::Settings::CAP_KEYS;
cmp_ok( scalar @all, '>', 5, 'the capability list is real (fixture not vacuous)' );
my %granted = ( manager => 1, map { $_ => 1 } @all );

subtest 'all decided: no warning' => sub {
    my $out = site_with(%granted);
    unlike( $out, qr/have not decided on capabilities/, 'no capability warning' );
    like( $out, qr/carry a decision on every capability/, 'the OK line says decided' );
};

subtest 'ABSENT on a manager group: granted on the next use, no decision asked' => sub {
    # SM1272: the SM645 top-up fills a manager group's absent capabilities on
    # the next use of the manager or the users tool, so there is nothing to
    # decide - and the remedy still names the manager, not a shell, first.
    my %g = %granted;
    delete $g{feedback};    # the store has never seen it - a release-added cap
    my $out = site_with(%g);
    like( $out, qr/do not hold capabilities this release has yet: ops\/feedback/,
        'names the group and the capability' );
    like( $out, qr/granted them on the next use of the manager or the users\s+tool \(opening the Users, Groups or Config page/,
        'says it is granted, and names the use that does it, the manager first' )
        or diag( 'App support must not need a sysadmin: the UI is the remedy, '
            . 'the CLI the fallback.' );
    unlike( $out, qr/have not decided on capabilities|grant or dismiss/,
        'and asks for no decision the code has already taken' );
};

subtest 'a gap the top-up does not fill keeps the decision wording (SM1272)' => sub {
    # Every gap the check can see today is on a manager group, in a capability
    # the top-up fills - so this case cannot be produced through a site, and is
    # held from the source instead: the predicate is the top-up's own rule, and
    # what it rejects is reported with SM496's remedy, the Groups page first.
    my $src = do { open my $fh, '<', $check or die $!; local $/; <$fh> };
    my $users = do {
        open my $fh, '<', repo_root() . '/tools/lazysite-users.pl' or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/return \$have->\{manager\} && \$c ne 'api' && \$c ne 'mcp';/,
        'the check fills a gap exactly where the top-up does: a manager group, not api/mcp' );
    like( $users, qr/return unless \$gs->\{\$group\}\{manager\};/,
        'the top-up acts only on a manager group' );
    like( $users, qr/for my \$c \( grep \{ \$_ ne 'api' && \$_ ne 'mcp' \} \@CAP_KEYS \) \{\s*next if exists \$cfg->\{\$c\};/,
        'and fills every capability but api/mcp it has no decision on' );
    like( $src, qr/if\s+\( \$topup_fills->\( \$have, \$c \) \) \{ push \@filled,  "\$g\/\$c" \}\s*else\s*\{ push \@missing, "\$g\/\$c" \}/,
        'what the predicate rejects goes to the decision bucket' );
    my ($decide) = $src =~ /if \(\@missing\) \{(.*?)\n            \}/s;
    like( $decide // '', qr/have not decided on capabilities this/,
        'which keeps the "have not decided" warning' );
    like( $decide // '', qr/Groups -> the group -> the "new\s*'\s*\.\s*'capabilities" banner \(grant or dismiss\)/,
        'and the Groups page banner as the remedy' );
};

subtest 'DECLINED is a decision, not a warning' => sub {
    my %g = %granted;
    $g{feedback} = 0;       # somebody said no, and the store remembers
    my $out = site_with(%g);
    unlike( $out, qr/have not decided on capabilities/,
        'an explicit 0 does not warn' )
        or diag('Re-warning about a recorded decision is how warnings get ignored.');
    like( $out, qr/1 declined by decision/, 'and is counted as a decision' );
};

done_testing();

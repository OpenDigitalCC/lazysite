#!/usr/bin/perl
# SM891: every systemd unit this project ships must pass `systemd-analyze
# verify` with nothing to say.
#
# TWO DEFECTS SAT IN THE RUNTIME UNIT UNTIL AN OPERATOR RAN THAT COMMAND:
#
#   * StartLimitIntervalSec / StartLimitBurst were in [Service], where systemd
#     has ignored them since v230 (2016) - "Unknown key 'StartLimitIntervalSec'
#     in section [Service], ignoring." The comment above them explains exactly
#     why the limit matters, and it has never been in force.
#
#   * Documentation=man:lazysite(1) names a man page that does not exist and
#     never has - "Command 'man lazysite(1)' failed with code 16".
#
# WHY THE EXIT CODE IS NOT THE TEST. `systemd-analyze verify` exited **0** with
# both of those present. It reports on stderr and still succeeds, so a check
# written the obvious way - run it, assert success - passes on a unit whose
# directives systemd is silently discarding. This asserts the OUTPUT is empty.
#
# Deliberately strict: any output at all fails, rather than a grep for the two
# strings already seen. A unit file is small, this project owns every line of
# them, and the whole lesson here is that the message nobody read was the one
# that mattered.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @units = sort( glob("$root/installers/systemd/*.service"),
    glob("$root/debian/*.service") );

cmp_ok( scalar @units, '>=', 2, 'the shipped unit files were found' )
    or do { done_testing(); exit };

my $analyze = `sh -c 'command -v systemd-analyze 2>/dev/null'`;
chomp $analyze;

SKIP: {
    skip 'systemd-analyze is not installed here', scalar @units
        unless length $analyze && -x $analyze;

    # Copied into a directory of their own: verify resolves a unit's name from
    # its filename, and a template needs to sit somewhere it can be
    # instantiated from without the repo's other files confusing the listing.
    my $dir = tempdir( CLEANUP => 1 );
    for my $u (@units) {
        my $base = $u;
        $base =~ s{.*/}{};
        copy( $u, "$dir/$base" ) or die "copy $u: $!";
    }

    for my $u (@units) {
        my $base = $u;
        $base =~ s{.*/}{};
        ( my $rel = $u ) =~ s{^\Q$root\E/}{};

        my $out = `\Q$analyze\E verify \Q$dir/$base\E 2>&1`;
        $out = '' unless defined $out;

        # The path in any message is the temp copy; say which file it is.
        $out =~ s{\Q$dir\E/}{};

        is( $out, '', "$rel: systemd-analyze verify has nothing to say" )
            or diag( "systemd-analyze verify said:\n$out\n"
                . "A directive systemd does not recognise is DISCARDED, not "
                . "refused - the unit still starts and the line does nothing." );
    }
}

done_testing();

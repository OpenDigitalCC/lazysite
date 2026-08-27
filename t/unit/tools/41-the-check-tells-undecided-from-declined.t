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

subtest 'UNDECIDED warns, and the remedy is the UI first' => sub {
    my %g = %granted;
    delete $g{feedback};    # the store has never seen it - a release-added cap
    my $out = site_with(%g);
    like( $out, qr/have not decided on capabilities this release has: ops\/feedback/,
        'names the group and the capability' );
    like( $out, qr/Groups -> the group -> the "new\s+capabilities" banner/,
        'the remedy names the manager UI, not a shell' )
        or diag( 'App support must not need a sysadmin: the UI is the remedy, '
            . 'the CLI the fallback.' );
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

#!/usr/bin/perl
# SM893 P4: `apt purge` removes the per-site runtime configs; `apt remove` keeps
# them.
#
# THE DEFECT: dpkg does not remove these files, because the package never
# shipped them - lazysite-hestia-domain writes one per provisioned site after
# install. So purging the package and installing it again left every conf in
# place, and the unit templates gate on ConditionPathExists against exactly
# those files. A reinstall therefore SILENTLY RE-ARMED every instance the host
# had ever provisioned, including sites long retired.
#
# It became sharper the day every site started being armed by default (SM893
# P1): before that, a leftover conf only mattered for a site somebody had
# explicitly asked for.
#
# THE REMOVE/PURGE DISTINCTION IS THE WHOLE TEST. `remove` leaves configuration
# by Debian convention - an operator removing the package to reinstall it
# expects their sites intact - and `purge` is the argument that means "and the
# configuration too". A postrm that deleted on both would destroy a working
# fleet's provisioning during an ordinary package upgrade cycle.
#
# Driven: the real postrm is executed with each argument against a fixture
# tree, because what is under test is a shell script's branching and reading it
# proves only that the words are present.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $postrm = repo_root() . '/debian/lazysite-common.postrm';
plan skip_all => "no postrm at $postrm" unless -f $postrm;

# The script uses absolute /etc/lazysite paths, so it is run against a fake
# root: a copy with the prefix rewritten. Rewriting one string is honest about
# what it changes; running the real file as root against the real /etc is not
# something a test may do.
sub run_postrm {
    my ($arg) = @_;

    # site_tempdir() rather than a bare tempdir(): the fixture is a fake
    # filesystem root, not a docroot, but it writes a conf containing a
    # DOCROOT= line, which is exactly the signal t/lint/118 counts. The helper
    # puts everything a level down inside what CLEANUP removes, which is the
    # property that lint is protecting, so taking it costs nothing and keeps
    # the fixture conf realistic.
    my $root = site_tempdir( leaf => 'fakeroot' );
    make_path("$root/etc/lazysite/daemon");
    make_path("$root/etc/lazysite/pools");
    for my $f (
        "$root/etc/lazysite/daemon/a.example.conf",
        "$root/etc/lazysite/daemon/b.example.conf",
        "$root/etc/lazysite/pools/a.example.conf",
        )
    {
        open my $fh, '>', $f or die $!;
        print {$fh} "DOCROOT=/x\nUSER=www-data\n";
        close $fh;
    }
    # Something the package did not put there, to prove the directory is only
    # removed when nothing else is using it.
    open my $keep, '>', "$root/etc/lazysite/daemon/operator-notes.txt" or die $!;
    print {$keep} "hand-written\n";
    close $keep;

    open my $src, '<', $postrm or die $!;
    my $text = do { local $/; <$src> };
    close $src;
    $text =~ s{/etc/lazysite}{$root/etc/lazysite}g;
    $text =~ s{^\#DEBHELPER\#$}{}m;

    my $script = "$root/postrm";
    open my $out, '>', $script or die $!;
    print {$out} $text;
    close $out;
    chmod oct('0755'), $script;

    system( 'sh', $script, $arg );
    return $root;
}

subtest 'remove keeps the per-site configs' => sub {
    my $root = run_postrm('remove');
    ok( -f "$root/etc/lazysite/daemon/a.example.conf",
        'a daemon conf survives `remove`' )
        or diag( 'Deleting on remove would wipe a fleet\'s provisioning during '
            . 'an ordinary package upgrade cycle.' );
    ok( -f "$root/etc/lazysite/pools/a.example.conf",
        'and so does a pool conf' );
};

subtest 'purge removes them' => sub {
    my $root = run_postrm('purge');
    ok( !-e "$root/etc/lazysite/daemon/a.example.conf", 'the daemon conf is gone' );
    ok( !-e "$root/etc/lazysite/daemon/b.example.conf", 'every daemon conf, not just one' );
    ok( !-e "$root/etc/lazysite/pools/a.example.conf", 'and the pool conf' )
        or diag( 'Left behind, these re-arm every instance the host ever '
            . 'provisioned the next time the package is installed.' );
};

subtest 'purge leaves what the package did not put there' => sub {
    my $root = run_postrm('purge');
    ok( -f "$root/etc/lazysite/daemon/operator-notes.txt",
        'an operator\'s own file in that directory is untouched' );
    ok( -d "$root/etc/lazysite/daemon",
        'and the directory stays, because something is still using it' )
        or diag( 'rmdir must fail quietly on a non-empty directory rather than '
            . 'the script forcing it.' );
};

done_testing();

#!/usr/bin/perl
# SM293 step 2b: moving a site's engine tree out of the document root.
#
# `lazysite/` holds config, credentials, the audit log, session state, form
# submissions and pre-install snapshots. Inside the docroot it is kept
# unreachable only by a `deny /lazysite/` in every shipped front-end template -
# configuration lazysite ships, cannot test where it is installed, and mostly
# cannot see. SM283's proxy would have served
# lazysite/backups/preinstall-*.tar.gz on any host whose static extension list
# includes `gz`: the whole site, including the account store.
#
# The dangerous part of this file is not the rename. It is everything that must
# keep working afterwards - so the last subtest INSTALLS OVER a migrated site,
# which is the operation that would otherwise recreate the tree inside the
# docroot and put the site in both places at once.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper      qw(repo_root);
use Lazysite::Paths qw(lazysite_dir external_lazysite_dir stray_lazysite);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";

sub run_cli {
    my (@args) = @_;
    my $err    = File::Temp::tmpnam();
    my $pid    = open my $ph, '-|';
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>', $err or die $!;
        exec $^X, "-I$root/lib", $cli, @args;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    my $rc = $? >> 8;
    my $e  = '';
    if ( open my $eh, '<', $err ) { local $/; $e = <$eh> // ''; close $eh }
    unlink $err;
    return { out => ( $out // '' ) . $e, rc => $rc };
}

sub fresh_site {
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    make_path( "$d/lazysite/auth", "$d/lazysite/backups", "$base/cgi-bin" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    open my $u, '>', "$d/lazysite/auth/users" or die $!;
    print {$u} "alice:x\n";
    close $u;
    return ( $base, $d );
}

subtest 'a dry run reports and moves nothing' => sub {
    my ( $base, $d ) = fresh_site();
    my $r = run_cli( 'migrate-engine-tree', '--docroot', $d );
    is( $r->{rc}, 0, 'it succeeds' ) or diag( $r->{out} );
    like( $r->{out}, qr/would move out/,      'and says what it would do' );
    like( $r->{out}, qr/Re-run with --apply/, 'and how to actually do it' );

    ok( -d "$d/lazysite",              'the tree has not moved' );
    ok( !-d external_lazysite_dir($d), 'and nothing was created beside it' );
};

subtest 'apply moves it, and the engine follows' => sub {
    my ( $base, $d ) = fresh_site();
    my $r = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );
    is( $r->{rc}, 0, 'it succeeds' ) or diag( $r->{out} );

    my $ext = external_lazysite_dir($d);
    ok( -d $ext, 'the tree is beside the document root' );
    ok( !-e "$d/lazysite",
        'and GONE from inside it - one tree, never two, because a copy left '
            . 'behind is what a front end can still serve' );
    ok( -f "$ext/auth/users", 'the account store came with it' );

    is( lazysite_dir($d), $ext, 'and the resolver now points there' );
    ok( !stray_lazysite($d), 'the site is not half-migrated' );
};

subtest 'it is idempotent and reversible' => sub {
    my ( $base, $d ) = fresh_site();
    run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );

    # Idempotent: a fleet run must be safe to repeat, and safe on a fleet where
    # some sites are already migrated.
    my $again = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );
    is( $again->{rc}, 0, 'running it again succeeds' );
    like( $again->{out}, qr/already migrated/, 'and says it was already done' );

    # Reversible. This is not politeness: it is what lets a site be migrated on
    # edge, watched, and put back without needing a release.
    my $back = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply', '--back' );
    is( $back->{rc}, 0, 'moving it back succeeds' ) or diag( $back->{out} );
    ok( -f "$d/lazysite/auth/users",   'the account store is back inside' );
    ok( !-e external_lazysite_dir($d), 'and gone from beside the docroot' );
};

subtest 'a half-migrated site is refused, not "fixed"' => sub {
    my ( $base, $d ) = fresh_site();
    make_path( external_lazysite_dir($d) . '/auth' );

    my $r = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );
    isnt( $r->{rc}, 0, 'it refuses' );
    like( $r->{out}, qr/BOTH places/, 'naming the state' );

    ok( -d "$d/lazysite", 'and touches neither copy - choosing between two '
            . 'account stores is not a decision a migration tool should take' );
    ok( -d external_lazysite_dir($d), 'the outside one is untouched too' );
};

subtest 'the version gate leaves a site the release has not reached' => sub {
    # A site running older code computes "<docroot>/lazysite" and cannot find a
    # moved tree, so migrating it would take it offline. The gate is how a fleet
    # follows a release through its channels.
    my ( $base, $d ) = fresh_site();
    my $r = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply',
        '--min-version', '99.0.0' );
    is( $r->{rc}, 0, 'it succeeds without doing anything' ) or diag( $r->{out} );
    like( $r->{out}, qr/version unknown - skipped/,
        'an unprovable version is skipped rather than assumed safe' );
    ok( -d "$d/lazysite", 'the tree has not moved' );
};

subtest 'installing over a migrated site does not recreate the tree' => sub {
    # THE ONE THAT MATTERS. Every install writes into the engine tree, so an
    # installer that computed "<docroot>/lazysite" would put a migrated site in
    # both places on its very next upgrade - and a site in both places works
    # perfectly while publishing its credentials, so nobody would notice.
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    my $cgi  = "$base/cgi-bin";
    make_path( $d, $cgi );

    my $first = system( $^X, "$root/install.pl", '--docroot', $d,
        '--cgibin', $cgi );
    is( $first, 0, 'a fresh install succeeds' );
    ok( -d "$d/lazysite", 'and puts the engine tree inside the docroot' );

    my $mv = run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );
    is( $mv->{rc}, 0, 'the site migrates' ) or diag( $mv->{out} );

    my $second = system( $^X, "$root/install.pl", '--docroot', $d,
        '--cgibin', $cgi );
    is( $second, 0, 'installing again over the migrated site succeeds' );

    ok( !-e "$d/lazysite",
        'and did NOT recreate the tree inside the document root' );
    ok( !stray_lazysite($d), 'so the site is not left half-migrated' );
    ok( -f external_lazysite_dir($d) . '/lazysite.conf',
        'the config is still the one beside the docroot' );
};


subtest 'the health check still verifies a migrated site' => sub {
    # The permission model is written docroot-relative ("lazysite/auth"), so on
    # a migrated site a bare "$DOC/$rel" does not exist and every check would
    # `next unless -e` its way past the whole engine tree - reporting a clean
    # bill of health while verifying nothing. The auth store's 02770 is the most
    # important mode on the site, so silence there is worse than a failure.
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    my $cgi  = "$base/cgi-bin";
    make_path( $d, $cgi );
    system( $^X, "$root/install.pl", '--docroot', $d, '--cgibin', $cgi );
    run_cli( 'migrate-engine-tree', '--docroot', $d, '--apply' );

    my $gname = getgrgid( ( stat $d )[5] ) // ( stat $d )[5];
    my $out = `$^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E --cgibin \Q$cgi\E --group \Q$gname\E 2>&1`;

    like( $out, qr/held outside the document root/,
        'the check recognises the migrated layout' );

    # Now break a mode INSIDE the moved tree and confirm it is still noticed.
    my $auth = external_lazysite_dir($d) . '/auth';
SKIP: {
        skip 'auth dir absent in this install', 2 unless -d $auth;
        chmod 0777, $auth;
        my $broken = `$^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E --cgibin \Q$cgi\E --group \Q$gname\E 2>&1`;
        like( $broken, qr/lazysite\/auth/,
            'a wrong mode inside the MOVED tree is still reported - the model '
                . 'paths resolve, rather than quietly missing' );
        unlike( $broken, qr/no engine tree for/,
            'and the tool did not refuse the site as "not a lazysite docroot"' );
    }
};

done_testing();

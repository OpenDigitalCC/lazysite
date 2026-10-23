#!/usr/bin/perl
#
# SM939 E2 / R15, SM1285 (ruling 33): THE STARTER PAGES ARE OPT-IN.
#
# A fresh install used to put the demo pages and ~70 pages of /docs on the
# owner's domain, publicly served and in the sitemap from the first minute -
# someone else's content on anybody's site, and seventy-odd deletes to undo.
# SM939 added --no-starter; ruling 33 (2026-10-23) made it the default: a new
# site lays down no starter pages unless `--starter` asks. The /docs manual is
# the engine's since SM1284 and serves either way.
#
# WHAT THIS PINS, AND WHY EACH HALF:
#
#   1. A plain provision leaves the starter pages out and KEEPS what a site
#      needs - forgot, logout, the site search, assets/, .well-known/ - and its
#      front page serves the engine's minimal home, and its seeded menu links no
#      page it has not got. An empty site must still be a working one.
#   2. --no-starter is accepted and means the same, so existing scripts work.
#   3. THE CHOICE SURVIVES A RE-LAY WITHOUT THE FLAG: a reinstall plans every
#      untracked file as a fresh install, so without the recorded choice the
#      default would last exactly until the first one.
#   4. --starter lays them, the full menu with them, and records no opt-out.
#   5. A site installed when they came by default (no recorded choice) keeps
#      them through a re-lay.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard site_tempdir run_processor run_child);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();
my $GROUP    = getgrgid( $) + 0 ) // ( $) + 0 );

sub fixture {
    my $d = site_tempdir();
    make_path( dirname($d) . '/cgi-bin' );
    return $d;
}

sub install {
    my ( $docroot, $mode, @extra ) = @_;
    my $r = run_child(
        [   $^X, $INSTALL, '--mode', $mode, '--docroot', $docroot,
            '--cgibin', dirname($docroot) . '/cgi-bin', '--serving-group', $GROUP, @extra
        ],
        stderr => 'merge',
        label  => "install.pl --mode $mode",
    );
    return ( $r->{out} // '', $r->{status} >> 8 );
}

sub state_of {
    my ($docroot) = @_;
    my $f = "$docroot/lazysite/.install-state.json";    # install.pl state_path
    return {} unless -f $f;
    open my $fh, '<', $f or return {};
    local $/;
    return eval { decode_json(<$fh>) } || {};
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or return '';
    local $/;
    return scalar <$fh>;
}

my @STARTER = qw(index.md lazysite-demo.md payment-demo.md payment-members-demo.md members.md contact.md);

for my $case ( [ 'a plain provision', [] ], [ 'provision --no-starter', ['--no-starter'] ] ) {
    my ( $name, $flags ) = @$case;
    my $bare = fixture();
    my ( $out, $rc ) = install( $bare, 'provision', @$flags );
    is( $rc, 0, "$name succeeded and passed its health check" ) or diag $out;

    subtest "$name: the starter pages are left out" => sub {
        ok( !-e "$bare/$_", "no $_" ) for @STARTER;
        ok( !-e "$bare/docs", 'no /docs tree in the docroot' );
        like( $out, qr/Starter:\s+not installed \((\d+) file/,
            'and the summary says so, so an empty site reads as a choice' );
        my ($n) = $out =~ /not installed \((\d+) file/;
        cmp_ok( $n // 0, '>=', scalar @STARTER, "with a count ($n)" );
        like( $out, qr/--starter installs them/, '...and how to have them' );
    };

    subtest "$name: what a site needs is still there" => sub {
        ok( -f "$bare/forgot.md", 'the password reset page' )
            or diag( 'An opt-out that removed it would ship a broken site, not an '
                . 'empty one: the login flow links to it.' );
        ok( -f "$bare/logout.md",                      'the logout page' );
        ok( -f "$bare/search-index.md",                'the search index' );
        ok( -f "$bare/search-results.md",              'the search results page' );
        ok( -d "$bare/assets",                         'assets/' );
        ok( -d "$bare/.well-known",                    '.well-known/' );
        ok( -d "$bare/manager",                        'the manager' );
        ok( -f "$bare/lazysite/lazysite.conf.example", 'the conf example' );
        ok( -f "$bare/lazysite/templates/docs/ai-briefing-building-sites.md", 'the /docs manual' );
    };

    subtest "$name: the front page and the menu" => sub {
        my $home = run_processor( $bare, '/' );
        like( $home, qr/^Status: 200/m, 'the front page serves' );
        like( $home, qr/has no home page of its own yet/, 'the engine\'s minimal home' );
        my $nav = slurp("$bare/lazysite/nav.conf");
        like( $nav, qr{^Home \| /$}m, 'the seeded menu has its home entry' );
        like( $nav, qr{\| /docs/configuration$}m, '...and its /docs entries' );
        unlike( $nav, qr{\| /(?:lazysite-demo|contact|members)\s*$}m,
            '...and none for a starter page the site has not got' );

        # The site's own home page wins as soon as it has one.
        open my $fh, '>', "$bare/index.md" or die $!;
        print {$fh} "---\ntitle: Ours\n---\nOUR-OWN-HOME\n";
        close $fh;
        like( run_processor( $bare, '/' ), qr/OUR-OWN-HOME/, 'a site that writes index.md is served its own' );
        unlink "$bare/index.md", "$bare/index.html";
    };

    subtest "$name: the choice is recorded, and a later run honours it without the flag" => sub {
        is( state_of($bare)->{starter}, 'none', 'the install state records starter: none' );
        # REINSTALL, not upgrade: an upgrade to the version already installed is
        # a no-op and plans nothing; a reinstall re-lays the whole payload
        # against the state, which is the run that would ship the pages if the
        # recorded choice were ignored.
        my ( $out2, $rc2 ) = install( $bare, 'reinstall' );
        cmp_ok( $rc2, '!=', 1, 'the reinstall ran' ) or diag $out2;
        like( $out2, qr/Install summary/, 'and actually laid files' );
        ok( !-e "$bare/lazysite-demo.md", 'and STILL no demo page' );
        is( state_of($bare)->{starter}, 'none', 'and the choice is still recorded' );
    };
}

subtest '--starter lays the starter pages' => sub {
    my $full = fixture();
    my ( $o3, $rc3 ) = install( $full, 'provision', '--starter' );
    is( $rc3, 0, 'provision --starter succeeded' ) or diag $o3;
    ok( -f "$full/$_", "it ships $_" ) for @STARTER;
    unlike( $o3, qr/Starter:/, 'and says nothing about skipped starter content' );
    ok( !exists state_of($full)->{starter}, 'and records no opt-out' );
    like( slurp("$full/lazysite/nav.conf"), qr{\| /lazysite-demo$}m, 'and the full menu' );
    like( run_processor( $full, '/' ), qr/This site is built with/, 'the starter\'s welcome page is the front page' );
};

subtest 'a site that got them by default keeps them' => sub {
    my $old = fixture();
    my ( $o4, $rc4 ) = install( $old, 'provision', '--starter' );
    is( $rc4, 0, 'provisioned with the starter pages' ) or diag $o4;
    my $st = state_of($old);
    delete $st->{starter};    # as a site installed before SM1285 records it
    open my $fh, '>', "$old/lazysite/.install-state.json" or die $!;
    print {$fh} encode_json($st);
    close $fh;
    my ( $o5, $rc5 ) = install( $old, 'reinstall' );
    cmp_ok( $rc5, '!=', 1, 'the reinstall ran' ) or diag $o5;
    ok( -f "$old/$_", "$_ is kept" ) for @STARTER;
    ok( !exists state_of($old)->{starter}, 'and no opt-out is recorded for it' );
};

done_testing();

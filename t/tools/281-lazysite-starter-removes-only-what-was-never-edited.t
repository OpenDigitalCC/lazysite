#!/usr/bin/perl
# SM1286 (ruling 34): `lazysite starter --list | --remove-unmodified [--dry-run]`.
#
# A new site gets no starter pages (SM1285), and the upgrade that made that the
# default keeps the ones a site already has. This is how an owner clears them
# out: list them, or remove the ones the site never edited, by provenance - the
# `provenance: lazysite-starter` stamp and the checksum the install recorded (or
# the shipped one). theunited.community did it by hand, file by file.
#
# WHAT THIS PINS:
#   - --list names every starter page, unmodified or edited, and changes nothing;
#   - --dry-run says what would go and removes nothing;
#   - the removal takes the unmodified pages and their cached renders, and
#     never an edited page, a page the site needs (forgot, logout, the search
#     pages), the site's own content or the /docs manual;
#   - a second run removes nothing, and a reinstall does not bring them back;
#   - it refuses root for the removal;
#   - with the install state lost, the shipped checksum still identifies them.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard site_tempdir run_child);

my $ROOT    = repo_root();
my $INSTALL = "$ROOT/install.pl";
my $CLI     = "$ROOT/tools/lazysite-cli.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();
my $GROUP    = getgrgid( $) + 0 ) // ( $) + 0 );

sub run {
    my ( $cmd, %env ) = @_;
    local @ENV{ keys %env } = values %env;
    my $r = run_child( $cmd, stderr => 'merge' );
    return ( $r->{out} // '', $r->{status} >> 8 );
}

sub provision {
    my $d = site_tempdir();
    make_path( dirname($d) . '/cgi-bin' );
    my ( $out, $rc ) = run( [ $^X, $INSTALL, '--mode', 'provision', '--docroot', $d,
        '--cgibin', dirname($d) . '/cgi-bin', '--serving-group', $GROUP, '--starter' ] );
    is( $rc, 0, 'provisioned with --starter' ) or diag $out;
    return $d;
}

sub starter { my ( $d, @a ) = @_; return run( [ $^X, $CLI, 'starter', '--docroot', $d, @a ] ) }

sub spit {
    my ( $f, $c ) = @_;
    open my $fh, '>', $f or die "$f: $!";
    print {$fh} $c;
    close $fh;
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }

my @UNMODIFIED = qw(index.md lazysite-demo.md payment-demo.md payment-members-demo.md members.md);
my @NEEDED     = qw(forgot.md logout.md search-index.md search-results.md);

my $d = provision();
spit( "$d/contact.md", slurp("$d/contact.md") . "\nOUR PHONE NUMBER\n" );    # edited
spit( "$d/lazysite-demo.html", "<p>cached render</p>\n" );
spit( "$d/about.md", "---\ntitle: About us\n---\nOURS\n" );                    # the site's own

subtest '--list names them and changes nothing' => sub {
    my ( $out, $rc ) = starter( $d, '--list' );
    is( $rc, 0, 'listed' ) or diag $out;
    like( $out, qr/^unmodified\s+\Q$_\E$/m, "$_ is unmodified" ) for @UNMODIFIED;
    like( $out, qr/^edited\s+contact\.md\s+\(kept: never removed\)$/m, 'contact.md is edited' );
    unlike( $out, qr/\b\Q$_\E\b/, "$_ is not a starter page" ) for @NEEDED, 'about.md';
    ok( -f "$d/$_", "$_ is still there" ) for @UNMODIFIED;
};

subtest '--dry-run removes nothing' => sub {
    my ( $out, $rc ) = starter( $d, '--remove-unmodified', '--dry-run' );
    is( $rc, 0, 'ran' ) or diag $out;
    like( $out, qr/^would remove\s+index\.md$/m, 'says what would go' );
    like( $out, qr/--dry-run: nothing removed/, 'and that nothing did' );
    ok( -f "$d/$_", "$_ is still there" ) for @UNMODIFIED;
};

subtest 'root is refused the removal' => sub {
    my ( $out, $rc ) = run( [ $^X, $CLI, 'starter', '--docroot', $d, '--remove-unmodified' ],
        LAZYSITE_CLI_FAKE_ROOT => 1 );
    isnt( $rc, 0, 'refused' );
    like( $out, qr/refusing to run 'starter --remove-unmodified' as root/, 'naming why' );
    ok( -f "$d/index.md", 'and nothing removed' );
};

subtest '--remove-unmodified takes only what was never edited' => sub {
    my ( $out, $rc ) = starter( $d, '--remove-unmodified' );
    is( $rc, 0, 'ran' ) or diag $out;
    ok( !-e "$d/$_", "$_ is removed" ) for @UNMODIFIED;
    ok( !-e "$d/lazysite-demo.html", 'with its cached render' );
    ok( -f "$d/contact.md", 'the edited page is kept' );
    like( slurp("$d/contact.md"), qr/OUR PHONE NUMBER/, '...unchanged' );
    ok( -f "$d/$_", "$_ (a page the site needs) is kept" ) for @NEEDED;
    is( slurp("$d/about.md"), "---\ntitle: About us\n---\nOURS\n", 'the site\'s own page is untouched' );
    ok( -f "$d/lazysite/templates/docs/ai-briefing-building-sites.md", 'the manual is untouched' );
    like( $out, qr{nav\.conf still links a removed page - edit the menu: Demo \| /lazysite-demo},
        'a menu entry left pointing at a removed page is named' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/\| starter-removed \| 5 page\(s\) \|/, 'and audited' );
};

subtest 'a second run removes nothing, and a reinstall brings none back' => sub {
    my ( $out, $rc ) = starter( $d, '--remove-unmodified' );
    is( $rc, 0, 'ran again' ) or diag $out;
    like( $out, qr/No unmodified starter pages to remove/, 'nothing left to remove' );
    ok( -f "$d/contact.md", 'the edited page is still kept' );
    ( $out, $rc ) = run( [ $^X, $INSTALL, '--mode', 'reinstall', '--docroot', $d,
        '--cgibin', dirname($d) . '/cgi-bin', '--serving-group', $GROUP ] );
    cmp_ok( $rc, '!=', 1, 'reinstalled' ) or diag $out;
    ok( !-e "$d/$_", "$_ stays removed" ) for @UNMODIFIED;
};

subtest 'with the install state lost, the shipped checksum still says unmodified' => sub {
    my $e = provision();
    unlink "$e/lazysite/.install-state.json" or die $!;
    spit( "$e/members.md", slurp("$e/members.md") . "\nedited\n" );
    my ( $out, $rc ) = starter( $e, '--list' );
    is( $rc, 0, 'listed' ) or diag $out;
    like( $out, qr/^unmodified\s+index\.md$/m, 'an unchanged page is still unmodified' );
    like( $out, qr/^edited\s+members\.md/m,   'and an edited one edited' );
};

done_testing();

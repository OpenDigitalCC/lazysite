#!/usr/bin/perl
# SM1284 (rulings 4, 27, 32, 34): THE /docs MANUAL IS THE ENGINE'S.
#
# The agent briefings and the manual they link into are served by the engine
# from lazysite/templates/docs/, versioned with it and refreshed by upgrades, so
# a content cleanup cannot remove them. theunited.community's owner kept 30 of
# 70 docs pages by hand to keep the briefings' links alive; theunited.fund
# deleted docs/ and lost the briefings the partner brief points at.
#
# WHAT THIS PINS:
#   1. a fresh site and a --no-starter site serve the briefings, with no docs/
#      in the docroot at all;
#   2. a site's own page at a /docs path wins, and `lazysite check` warns that
#      it shadows the engine's (ruling 27) - an identical copy is not warned;
#   3. deleting the site's docs/ leaves the manual served;
#   4. the upgrade that ships this removes an UNMODIFIED docroot copy (the
#      install state's checksum still matches), keeps an EDITED one and says so,
#      and touches nothing else - the site's own docs page, a starter page -
#      and running it again changes nothing.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path remove_tree);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use JSON::PP       qw(decode_json encode_json);
use Digest::SHA    qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard site_tempdir run_processor run_child);

my $ROOT    = repo_root();
my $INSTALL = "$ROOT/install.pl";
my $CHECK   = "$ROOT/tools/lazysite-check.pl";
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

sub check_out {
    my ($docroot) = @_;
    return run_child( [ $^X, $CHECK, '--docroot', $docroot ], stderr => 'merge' )->{out} // '';
}

sub get {
    my ( $docroot, $uri ) = @_;
    my $out = run_processor( $docroot, $uri );
    my ($s) = $out =~ /Status:\s*(\d+)/;
    return ( $s // 0, $out );
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "$f: $!";
    local $/;
    return scalar <$fh>;
}

sub spit {
    my ( $f, $c ) = @_;
    make_path( dirname($f) );
    open my $fh, '>:raw', $f or die "$f: $!";
    print {$fh} $c;
    close $fh;
}

my $state_file = sub { "$_[0]/lazysite/.install-state.json" };

# --- 1. a fresh site, and a site without the starter pages ------------------
for my $case ( [ 'a fresh site', [] ], [ 'a --no-starter site', ['--no-starter'] ] ) {
    my ( $name, $flags ) = @$case;
    subtest "$name serves the briefings" => sub {
        my $d = fixture();
        my ( $out, $rc ) = install( $d, 'provision', @$flags );
        is( $rc, 0, 'provisioned' ) or diag $out;
        ok( !-e "$d/docs", 'with no docs/ in the docroot' );
        ok( -f "$d/lazysite/templates/docs/ai-briefing-building-sites.md", 'the manual is in the engine tree' );
        for my $uri (qw(/docs/ai-briefing-building-sites /docs/ai-briefing-authoring /docs/reference /docs/forms /docs/)) {
            my ($s) = get( $d, $uri );
            is( $s, 200, "$uri serves" );
        }
        my ( $s, $body ) = get( $d, '/docs/features/' );
        is( $s, 200, 'the features index serves' );
        like( $body, qr{href="/docs/features/configuration/themes"},
            'and lists the engine\'s features pages (its scan sees the engine tree)' );
        is( ( get( $d, '/docs/no-such-page' ) )[0], 404, 'a /docs page nobody ships is a 404' );
    };
}

# --- 2 and 3. a site's own copy wins and is warned; deleting docs/ ---------
subtest 'a site copy shadows the engine page, and the check says so' => sub {
    my $d = fixture();
    my ( $out, $rc ) = install( $d, 'provision', '--no-starter' );
    is( $rc, 0, 'provisioned' ) or diag $out;
    my $engine = "$d/lazysite/templates/docs/ai-briefing-layouts.md";

    unlike( check_out($d), qr/shadow a newer version of the engine/, 'no site copy: nothing to warn' );

    # An identical copy shadows nothing.
    make_path("$d/docs");
    copy( $engine, "$d/docs/ai-briefing-layouts.md" ) or die $!;
    unlike( check_out($d), qr/shadow a newer version of the engine/, 'an identical copy is not warned' );

    spit( "$d/docs/ai-briefing-layouts.md", "---\ntitle: Our layouts\n---\n\nSITE-OVERRIDE-MARKER\n" );
    my ( $s, $body ) = get( $d, '/docs/ai-briefing-layouts' );
    is( $s, 200, 'the page serves' );
    like( $body, qr/SITE-OVERRIDE-MARKER/, 'from the site\'s own copy, which wins' );
    like( check_out($d), qr/1 site page\(s\) shadow a newer version of the engine's \/docs manual.*docs\/ai-briefing-layouts\.md/,
        'and the check warns, naming it' );

    remove_tree("$d/docs");
    ( $s, $body ) = get( $d, '/docs/ai-briefing-layouts' );
    is( $s, 200, 'deleting the site\'s docs/ leaves the page served' );
    unlike( $body, qr/SITE-OVERRIDE-MARKER/, 'by the engine' );
    ok( !-e "$d/docs", 'and serving it puts no docs/ back into the docroot' );
};

# --- 4. the upgrade that ships this ----------------------------------------
subtest 'the upgrade removes unmodified docs copies and keeps edited ones' => sub {
    my $d = fixture();
    my ( $out, $rc ) = install( $d, 'provision', '--starter' );
    is( $rc, 0, 'provisioned' ) or diag $out;

    # Lay the site out as a release that shipped the manual into the docroot
    # left it: each copy recorded in the install state with its checksum.
    my $st = decode_json( slurp( $state_file->($d) ) );
    my $eng = "$d/lazysite/templates/docs";
    for my $rel (qw(ai-briefing-data.md features/configuration/themes.md auth.md)) {
        my $c = slurp("$eng/$rel");
        spit( "$d/docs/$rel", $c );
        $st->{files}{"$d/docs/$rel"} = 'sha256:' . sha256_hex($c);
    }
    spit( "$d/docs/ai-briefing-data.html", "<p>stale render</p>\n" );    # its cache
    spit( "$d/docs/auth.md", slurp("$d/docs/auth.md") . "\nOUR-OWN-AUTH-NOTES\n" );    # edited
    spit( "$d/docs/our-handbook.md", "---\ntitle: Ours\n---\nOURS\n" );    # the site's own page
    my $home = slurp("$d/index.md");
    $st->{version} = '0.0.1';
    spit( $state_file->($d), encode_json($st) );

    ( $out, $rc ) = install( $d, 'upgrade', '--force' );
    is( $rc, 0, 'the upgrade ran' ) or diag $out;
    ok( !-e "$d/docs/ai-briefing-data.md",              'an unmodified briefing copy is removed' );
    ok( !-e "$d/docs/ai-briefing-data.html",            '...with its stale render' );
    ok( !-e "$d/docs/features/configuration/themes.md", 'an unmodified manual page is removed' );
    ok( -f "$d/docs/auth.md", 'an EDITED copy is kept' );
    like( slurp("$d/docs/auth.md"), qr/OUR-OWN-AUTH-NOTES/, '...unchanged' );
    like( $out, qr{orphan \(edited post-install, left in place\): \Q$d\E/docs/auth\.md}, '...and named in the output' );
    is( slurp("$d/docs/our-handbook.md"), "---\ntitle: Ours\n---\nOURS\n", 'the site\'s own docs page is untouched' );
    is( slurp("$d/index.md"), $home, 'a starter page is untouched' );
    is( ( get( $d, '/docs/ai-briefing-data' ) )[0], 200, 'and the removed page serves from the engine' );
    like( ( get( $d, '/docs/auth' ) )[1], qr/OUR-OWN-AUTH-NOTES/, 'the kept one serves the site\'s copy' );

    # Idempotent: the same upgrade again changes nothing.
    $st = decode_json( slurp( $state_file->($d) ) );
    $st->{version} = '0.0.1';
    spit( $state_file->($d), encode_json($st) );
    ( $out, $rc ) = install( $d, 'upgrade', '--force' );
    is( $rc, 0, 'the upgrade runs again' ) or diag $out;
    like( slurp("$d/docs/auth.md"), qr/OUR-OWN-AUTH-NOTES/, 'the edited copy is still there' );
    ok( -f "$d/docs/our-handbook.md", 'and so is the site\'s own page' );
    is( slurp("$d/index.md"), $home, 'and the starter page' );
};

done_testing();

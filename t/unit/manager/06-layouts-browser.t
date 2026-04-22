#!/usr/bin/perl
# SM037 + D013 + SM046: unit tests for the layouts-releases browser
# and layouts-install endpoints. LWP::UserAgent is stubbed at package
# level so the tests don't require network or the real LWP module,
# and so we can script the exact responses exercised by each case.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

# --- LWP::UserAgent stub ---
# Pre-populate %INC so the lazy `require LWP::UserAgent` inside the
# action subs is a no-op. @MOCK_RESPONSES is consumed FIFO per ->get.
{
    package LWP::UserAgent;
    use strict;
    our @MOCK_RESPONSES;
    sub new { return bless {}, 'LWP::UserAgent' }
    sub get {
        my $r = shift @MOCK_RESPONSES;
        die "mock LWP: no response queued\n" unless defined $r;
        return $r;
    }
}
$INC{'LWP/UserAgent.pm'} = 'mocked';

{
    package MockResponse;
    sub new {
        my ( $class, %args ) = @_;
        return bless { %args }, $class;
    }
    sub is_success { $_[0]->{status} >= 200 && $_[0]->{status} < 300 }
    sub decoded_content { $_[0]->{body} }
    sub content         { $_[0]->{body} }
    sub status_line     { $_[0]->{status} . ' mock' }
}

sub queue_response {
    my ( $status, $body ) = @_;
    push @LWP::UserAgent::MOCK_RESPONSES,
        MockResponse->new( status => $status, body => $body );
}

# --- Fixture setup ---
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
# D013: pre-create the 'default' layout so themes declaring
# layouts:["default"] can install successfully. SM046 scenarios
# also use a 'studio' layout for mismatch and multi-layout tests.
for my $l (qw(default studio)) {
    make_path("$docroot/lazysite/layouts/$l");
    open my $lfh, '>', "$docroot/lazysite/layouts/$l/layout.tt" or die $!;
    print $lfh "<html>[% content %]</html>\n";
    close $lfh;
}

sub write_conf {
    my ($content) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $content;
    close $fh;
}

# SM046: build a GitHub-style zipball with LL v0.3.0+ nested shape.
#   wrapper/layouts/LAYOUT/themes/THEME/theme.json (+ optional assets/main.css)
#
# Spec format: [ { layout => 'default', theme => 'alpha', valid => 1,
#                  declared_layouts => ['default'] }, ... ]
# `valid` 0 means the theme dir is present but theme.json is omitted.
# `declared_layouts` overrides the default of [ layout ] for the
# source-path mismatch test; omit to use the source path's layout.
sub build_zipball_nested {
    my (@theme_specs) = @_;
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    my $wrapper = 'OpenDigitalCC-lazysite-layouts-abc123';
    for my $spec (@theme_specs) {
        my $layout = $spec->{layout} // 'default';
        my $theme  = $spec->{theme};
        my $declared = $spec->{declared_layouts} // [$layout];
        my $dir = "$wrapper/layouts/$layout/themes/$theme";

        if ( $spec->{valid} ) {
            $zip->addString(
                encode_json({
                    name    => $theme,
                    version => '1.0',
                    layouts => $declared,
                    config  => { colours => { primary => '#000' } },
                }),
                "$dir/theme.json"
            );
            $zip->addString( "/* css */\n", "$dir/assets/main.css" );
        }
        else {
            # Theme dir exists but has no theme.json (just a stray file).
            $zip->addString( "readme\n", "$dir/README.md" );
        }
    }
    my $tmpfile = "$docroot/zipball-$$.zip";
    $zip->writeToFileNamed($tmpfile) == Archive::Zip::AZ_OK()
        or die "failed to build mock zipball";
    open my $fh, '<:raw', $tmpfile or die $!;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    unlink $tmpfile;
    return $bytes;
}

# Pre-LL-v0.3.0 flat shape: wrapper/THEME/theme.json (no layouts/
# directory). Used by the rejection subtest only.
sub build_zipball_flat {
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    my $wrapper = 'old-layouts-wrapper';
    $zip->addString(
        encode_json({
            name => 'old', version => '1.0',
            layouts => ['default'],
            config => { colours => { primary => '#000' } },
        }),
        "$wrapper/old/theme.json"
    );
    $zip->addString( "/* css */\n", "$wrapper/old/assets/main.css" );
    my $tmpfile = "$docroot/flat-zip-$$.zip";
    $zip->writeToFileNamed($tmpfile) == Archive::Zip::AZ_OK()
        or die "failed to build flat zipball";
    open my $fh, '<:raw', $tmpfile or die $!;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    unlink $tmpfile;
    return $bytes;
}

# Empty-wrapper zipball (just a README at wrapper root, no layouts/).
sub build_zipball_no_layouts {
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    my $wrapper = 'no-layouts-wrapper';
    $zip->addString( "readme\n",    "$wrapper/README.md" );
    $zip->addString( "scripts...\n", "$wrapper/tools/package.sh" );
    my $tmpfile = "$docroot/no-lay-zip-$$.zip";
    $zip->writeToFileNamed($tmpfile) == Archive::Zip::AZ_OK()
        or die "failed to build no-layouts zipball";
    open my $fh, '<:raw', $tmpfile or die $!;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    unlink $tmpfile;
    return $bytes;
}

# Layouts dir with one LAYOUT that has no themes/ subdir.
sub build_zipball_empty_themes_dir {
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    my $wrapper = 'empty-themes-wrapper';
    $zip->addString( "<html>[% content %]</html>",
        "$wrapper/layouts/default/layout.tt" );
    $zip->addString( '{"name":"default","version":"1.0.0"}',
        "$wrapper/layouts/default/layout.json" );
    my $tmpfile = "$docroot/empty-themes-zip-$$.zip";
    $zip->writeToFileNamed($tmpfile) == Archive::Zip::AZ_OK()
        or die "failed to build empty-themes zipball";
    open my $fh, '<:raw', $tmpfile or die $!;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    unlink $tmpfile;
    return $bytes;
}

sub clean_installed_themes {
    for my $l (qw(default studio)) {
        my $td = "$docroot/lazysite/layouts/$l/themes";
        system( 'rm', '-rf', $td ) if -d $td;
    }
    system( 'rm', '-rf', "$docroot/lazysite-assets" )
        if -d "$docroot/lazysite-assets";
}

# --- Load the manager-api after LWP stub is in place ---
BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';    # placeholder
}
my $root = repo_root();
{
    # Re-assign DOCROOT env to our fixture before load.
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# --- Scenario 1: layouts-releases happy path ---
subtest 'layouts-releases happy path' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $body = encode_json([
        { tag_name => 'v1.0.0', name => 'First release',
          published_at => '2026-04-01T00:00:00Z', body => 'notes' },
        { tag_name => 'v0.9.0', name => 'Preview',
          published_at => '2026-03-15T00:00:00Z', body => '' },
    ]);
    queue_response( 200, $body );

    my $r = main::action_layouts_releases();
    ok( $r->{ok}, 'ok' );
    is( $r->{repo}, 'OpenDigitalCC/lazysite-layouts', 'repo echoed' );
    is( scalar @{ $r->{releases} }, 2, 'two releases parsed' );
    is( $r->{releases}[0]{tag_name}, 'v1.0.0', 'first tag' );
    is( $r->{releases}[0]{name}, 'First release', 'first name' );
};

# --- Scenario 2: layouts-releases missing layouts_repo ---
subtest 'layouts-releases missing layouts_repo' => sub {
    write_conf("site_name: Test\n");
    my $r = main::action_layouts_releases();
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/Check the layouts_repo setting/,
        'error points at layouts_repo' );
};

# --- Scenario 3 (SM046 rewrite): LL v0.3.0 nested happy path ---
subtest 'layouts-install LL v0.3.0 nested happy path' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    clean_installed_themes();

    my $zip = build_zipball_nested(
        { layout => 'default', theme => 'alpha', valid => 1 },
        { layout => 'default', theme => 'beta',  valid => 1 },
    );
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( $r->{ok}, 'ok' );
    is( $r->{tag}, 'v1.0.0', 'tag echoed' );
    is( scalar @{ $r->{themes} }, 2, 'two themes processed' );
    my %by = map { $_->{source} => $_ } @{ $r->{themes} };
    ok( $by{'layouts/default/themes/alpha'}{ok},
        'alpha installed, source path reflects nested location' );
    ok( $by{'layouts/default/themes/beta'}{ok},
        'beta installed' );
    ok( -f "$docroot/lazysite/layouts/default/themes/alpha/theme.json",
        'alpha theme.json on disk at nested target path' );
    ok( -f "$docroot/lazysite/layouts/default/themes/beta/theme.json",
        'beta theme.json on disk at nested target path' );
};

# --- Scenario 4: layouts-install rejects invalid tag ---
subtest 'layouts-install invalid tag' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $body = encode_json({ tag => '../etc/passwd' });
    my $r = main::action_layouts_install($body);
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/Invalid tag/, 'rejects path-traversal in tag' );
};

# --- SM046 Scenario A: source-path / declared-layouts mismatch ---
subtest 'layouts-install rejects source-path / declared-layouts mismatch' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    clean_installed_themes();

    my $zip = build_zipball_nested(
        {
            layout           => 'default',
            theme            => 'mismatched',
            valid            => 1,
            declared_layouts => ['studio'],
        },
    );
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( $r->{ok}, 'overall ok (best-effort walk)' );
    is( scalar @{ $r->{themes} }, 1, 'one theme reported' );
    my $t = $r->{themes}[0];
    ok( !$t->{ok}, 'entry marked failed' );
    like( $t->{error}, qr/mismatching source path/,
        'error names the mismatch' );
    ok( !-d "$docroot/lazysite/layouts/default/themes/mismatched",
        'mismatched theme was not installed' );
};

# --- SM046 Scenario B: missing layouts/ directory (strict rejection) ---
subtest 'layouts-install rejects release without layouts/ dir' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $zip = build_zipball_no_layouts();
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr{layouts/ directory}, 'error mentions layouts/ dir' );
    like( $r->{error}, qr/D013/i,
        'error calls out the D013 expected shape' );
};

# --- SM046 Scenario C: pre-LL-v0.3.0 flat shape rejected ---
subtest 'layouts-install rejects pre-LL-v0.3.0 flat shape' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $zip = build_zipball_flat();
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( !$r->{ok}, 'flat shape rejected' );
    like( $r->{error}, qr{layouts/ directory},
        'error calls out the missing layouts/ dir' );
};

# --- SM046 Scenario D: layouts/LAYOUT/ with no themes/ subdir ---
subtest 'layouts-install silently skips layout without themes dir' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $zip = build_zipball_empty_themes_dir();
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( !$r->{ok}, 'overall not ok (no themes installed)' );
    like( $r->{error}, qr/No themes found/,
        'error reports no themes under layouts/*/themes/' );
};

# --- SM046 Scenario E: partial failure (good + mismatch + no theme.json) ---
subtest 'layouts-install: partial failure reports per-theme results' => sub {
    write_conf("site_name: Test\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    clean_installed_themes();

    my $zip = build_zipball_nested(
        { layout => 'default', theme => 'good',     valid => 1 },
        { layout => 'default', theme => 'wrong',    valid => 1,
          declared_layouts => ['studio'] },
        { layout => 'default', theme => 'no-json',  valid => 0 },
    );
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_layouts_install($body);
    ok( $r->{ok}, 'overall ok (best-effort)' );
    is( scalar @{ $r->{themes} }, 3, 'three entries reported' );

    my %by = map { $_->{source} => $_ } @{ $r->{themes} };
    ok( $by{'layouts/default/themes/good'}{ok},
        'good: installed' );
    ok( !$by{'layouts/default/themes/wrong'}{ok},
        'wrong: mismatch failure' );
    like( $by{'layouts/default/themes/wrong'}{error},
        qr/mismatching source path/,
        'wrong: mismatch error mentions source path' );
    ok( !$by{'layouts/default/themes/no-json'}{ok},
        'no-json: missing-manifest failure' );
    like( $by{'layouts/default/themes/no-json'}{error},
        qr/Missing theme\.json/i,
        'no-json: error mentions theme.json' );

    ok( -f "$docroot/lazysite/layouts/default/themes/good/theme.json",
        'good theme on disk' );
    ok( !-d "$docroot/lazysite/layouts/default/themes/wrong",
        'wrong theme NOT installed' );
    ok( !-d "$docroot/lazysite/layouts/default/themes/no-json",
        'no-json theme NOT installed' );
};

done_testing();

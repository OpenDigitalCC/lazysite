#!/usr/bin/perl
# SM037: unit tests for the views-releases browser and views-install
# endpoints. LWP::UserAgent is stubbed at package level so the tests
# don't require network or the real LWP module, and so we can script
# the exact responses exercised by each case.
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
make_path("$docroot/lazysite/themes");

sub write_conf {
    my ($content) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $content;
    close $fh;
}

# Build a GitHub-style zipball: one top-level wrapper dir, with
# subdirs containing view.tt + theme.json (or not, per test).
sub build_zipball {
    my (@theme_specs) = @_;    # each: { name => ..., valid => 0|1 }
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    my $wrapper = 'OpenDigitalCC-views-abc123';
    for my $spec (@theme_specs) {
        my $dir = "$wrapper/$spec->{name}";
        $zip->addString( "view.tt content\n",    "$dir/view.tt" );
        if ( $spec->{valid} ) {
            $zip->addString(
                encode_json( { name => $spec->{name}, version => '1.0' } ),
                "$dir/theme.json"
            );
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

# The manager-api captures $DOCROOT at load time; inject it into the
# loaded script's package-scoped lexical isn't possible, but since
# the subs read the env-derived $DOCROOT lexical, and we did load with
# DOCUMENT_ROOT=$docroot, it's already correct.

# --- Scenario 1: views-releases happy path ---
subtest 'views-releases happy path' => sub {
    write_conf("site_name: Test\nviews_repo: OpenDigitalCC/lazysite-views\n");
    my $body = encode_json([
        { tag_name => 'v1.0.0', name => 'First release',
          published_at => '2026-04-01T00:00:00Z', body => 'notes' },
        { tag_name => 'v0.9.0', name => 'Preview',
          published_at => '2026-03-15T00:00:00Z', body => '' },
    ]);
    queue_response( 200, $body );

    my $r = main::action_views_releases();
    ok( $r->{ok}, 'ok' );
    is( $r->{repo}, 'OpenDigitalCC/lazysite-views', 'repo echoed' );
    is( scalar @{ $r->{releases} }, 2, 'two releases parsed' );
    is( $r->{releases}[0]{tag_name}, 'v1.0.0', 'first tag' );
    is( $r->{releases}[0]{name}, 'First release', 'first name' );
};

# --- Scenario 2: views-releases missing views_repo ---
subtest 'views-releases missing views_repo' => sub {
    write_conf("site_name: Test\n");
    my $r = main::action_views_releases();
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/Check the views_repo setting/,
        'error points at views_repo' );
};

# --- Scenario 3: views-install happy path, mixed themes ---
subtest 'views-install installs all valid theme dirs' => sub {
    write_conf("site_name: Test\nviews_repo: OpenDigitalCC/lazysite-views\n");
    # Clean any previously-installed themes from prior runs.
    for my $n (qw(alpha beta skipme)) {
        my $p = "$docroot/lazysite/themes/$n";
        system( 'rm', '-rf', $p ) if -d $p;
    }
    my $zip = build_zipball(
        { name => 'alpha',  valid => 1 },
        { name => 'beta',   valid => 1 },
        { name => 'skipme', valid => 0 },   # missing theme.json
    );
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_views_install($body);
    ok( $r->{ok}, 'ok' );
    is( $r->{tag}, 'v1.0.0', 'tag echoed' );
    # skipme dir has no theme.json so it's not treated as a theme;
    # _install_theme_from_dir is only called for alpha and beta.
    is( scalar @{ $r->{themes} }, 2, 'two themes installed' );
    my %by_source = map { $_->{source} => $_ } @{ $r->{themes} };
    ok( $by_source{alpha}{ok}, 'alpha installed' );
    ok( $by_source{beta}{ok},  'beta installed' );
    ok( -f "$docroot/lazysite/themes/alpha/view.tt",
        'alpha view.tt on disk' );
    ok( -f "$docroot/lazysite/themes/beta/view.tt",
        'beta view.tt on disk' );
};

# --- Scenario 4: views-install rejects invalid tag ---
subtest 'views-install invalid tag' => sub {
    write_conf("site_name: Test\nviews_repo: OpenDigitalCC/lazysite-views\n");
    my $body = encode_json({ tag => '../etc/passwd' });
    my $r = main::action_views_install($body);
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/Invalid tag/, 'rejects path-traversal in tag' );
};

# --- Scenario 5: views-install with zipball containing no themes ---
subtest 'views-install reports when no valid themes present' => sub {
    write_conf("site_name: Test\nviews_repo: OpenDigitalCC/lazysite-views\n");
    my $zip = build_zipball(
        { name => 'not-a-theme', valid => 0 },    # no theme.json
    );
    queue_response( 200, $zip );

    my $body = encode_json({ tag => 'v1.0.0' });
    my $r = main::action_views_install($body);
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/No valid themes found/,
        'explains missing theme files' );
};

done_testing();

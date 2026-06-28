#!/usr/bin/perl
# _resolve_manifest_install: the pure layout/theme selection from a manifest.
# (The HTTP fetch + zip extract around it is exercised live, not here.)
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $manifest = {
    schema  => 1,
    layouts => [
        {
            name          => 'nova',
            version       => '1.0.0',
            package       => 'releases/layouts/nova.zip',
            default_theme => 'nova',
            themes => [ { name => 'nova', version => '1.0.0',
                          package => 'releases/nova/nova.zip' } ],
        },
        {
            name          => 'default',
            version       => '1.0.0',
            package       => 'releases/layouts/default.zip',
            default_theme => 'default',
            themes => [
                { name => 'default', version => '1.0.0', package => 'releases/default/default.zip' },
                { name => 'dark',    version => '1.0.0', package => 'releases/default/dark.zip' },
                { name => 'warm',    version => '1.0.0', package => 'releases/default/warm.zip' },
            ],
        },
    ],
};

my $R = \&Lazysite::Manager::Layouts::_resolve_manifest_install;

subtest 'single-theme layout -> layout + its one theme' => sub {
    my $p = $R->( $manifest, 'nova' );
    ok( $p->{ok}, 'ok' );
    is( $p->{layout}{package}, 'releases/layouts/nova.zip', 'layout package' );
    is_deeply( [ map { $_->{name} } @{ $p->{themes} } ], ['nova'], 'one theme' );
};

subtest 'multi-theme layout, no choice -> default_theme only' => sub {
    my $p = $R->( $manifest, 'default' );
    ok( $p->{ok}, 'ok' );
    is_deeply( [ map { $_->{name} } @{ $p->{themes} } ], ['default'],
        'default_theme chosen' );
};

subtest 'explicit theme choice' => sub {
    my $p = $R->( $manifest, 'default', 'dark' );
    ok( $p->{ok}, 'ok' );
    is_deeply( [ map { $_->{name} } @{ $p->{themes} } ], ['dark'], 'dark chosen' );
};

subtest 'all -> every theme' => sub {
    my $p = $R->( $manifest, 'default', undef, 1 );
    ok( $p->{ok}, 'ok' );
    is_deeply( [ sort map { $_->{name} } @{ $p->{themes} } ],
        [qw(dark default warm)], 'all three themes' );
};

subtest 'unknown layout / theme rejected' => sub {
    my $p = $R->( $manifest, 'ghost' );
    ok( !$p->{ok}, 'unknown layout not ok' );
    like( $p->{error}, qr/not in manifest/i, 'error explains' );

    my $q = $R->( $manifest, 'default', 'neon' );
    ok( !$q->{ok}, 'unknown theme not ok' );
    like( $q->{error}, qr/not listed/i, 'error explains' );
};

subtest 'malformed manifest' => sub {
    my $p = $R->( { schema => 1 }, 'nova' );
    ok( !$p->{ok}, 'no layouts[] rejected' );
};

done_testing;

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

open my $fh, '>', "$docroot/kitchen-sink.md" or die $!;
print $fh "---\ntitle: Test\nttl: 300\nraw: true\ncontent_type: text/csv\n";
print $fh "auth: required\nauth_groups:\n  - admins\n";
print $fh "payment: required\npayment_amount: 0.01\n---\nBody.\n";
close $fh;

load_processor($docroot);

# --- peek_ttl ---
is( main::peek_ttl("$docroot/kitchen-sink.md"), 300, 'peek_ttl reads ttl' );

{
    my ( $f, $path ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f "---\ntitle: Test\n---\nBody\n";
    close $f;
    is( main::peek_ttl($path), undef, 'peek_ttl undef when ttl absent' );
}

# --- peek_content_type ---
is( main::peek_content_type("$docroot/kitchen-sink.md"),
    'text/csv', 'peek_content_type reads custom content_type for raw' );

{
    my ( $f, $path ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f "---\ntitle: Plain\n---\nBody\n";
    close $f;
    is( main::peek_content_type($path), undef,
        'peek_content_type undef for normal page' );
}

{
    my ( $f, $path ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f "---\ntitle: Raw only\nraw: true\n---\nBody\n";
    close $f;
    is( main::peek_content_type($path),
        'text/plain; charset=utf-8',
        'peek_content_type defaults text/plain for raw' );
}

{
    my ( $f, $path ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f "---\ntitle: Api\napi: true\n---\n{}\n";
    close $f;
    is( main::peek_content_type($path),
        'application/json; charset=utf-8',
        'peek_content_type defaults application/json for api' );
}

# --- peek_auth ---
{
    my $auth = main::peek_auth("$docroot/kitchen-sink.md");
    is( $auth->{auth}, 'required', 'peek_auth reads auth key' );
    is_deeply( $auth->{groups}, ['admins'], 'peek_auth reads auth_groups' );
}

# --- peek_payment ---
{
    my $p = main::peek_payment("$docroot/kitchen-sink.md");
    is( $p->{payment},        'required', 'peek_payment reads payment' );
    is( $p->{payment_amount}, '0.01',     'peek_payment reads amount' );
}

# --- peek_query_params ---
{
    my ( $f, $path ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f "---\ntitle: T\nquery_params:\n  - q\n  - page\n---\n";
    close $f;
    my $qp = main::peek_query_params($path);
    is_deeply( $qp, [ 'q', 'page' ], 'peek_query_params reads list' );

    my ( $f2, $p2 ) = tempfile( SUFFIX => '.md', UNLINK => 1 );
    print $f2 "---\ntitle: T\n---\n";
    close $f2;
    is( main::peek_query_params($p2), undef,
        'peek_query_params undef when absent' );
}

done_testing();

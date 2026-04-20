#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_auth_site($docroot);

# --- protected without auth → 302 to login ---
{
    my $out = run_processor( $docroot, '/protected' );
    like( $out, qr/Status: 302/,       'no auth → 302' );
    like( $out, qr{Location:[^\n]*login}, 'redirects toward login' );
}

# --- protected with valid user header → 200 ---
{
    my $out = run_processor( $docroot, '/protected',
        HTTP_X_REMOTE_USER   => 'alice',
        HTTP_X_REMOTE_GROUPS => 'members',
    );
    like( $out, qr/Status: 200/, 'valid auth → 200' );
}

# --- admins-only with wrong group → 403 ---
{
    my $out = run_processor( $docroot, '/admins-only',
        HTTP_X_REMOTE_USER   => 'bob',
        HTTP_X_REMOTE_GROUPS => 'members',
    );
    like( $out, qr/Status: 403/, 'wrong group → 403' );
}

# --- admins-only with correct group → 200 ---
{
    my $out = run_processor( $docroot, '/admins-only',
        HTTP_X_REMOTE_USER   => 'alice',
        HTTP_X_REMOTE_GROUPS => 'admins',
    );
    like( $out, qr/Status: 200/, 'correct group → 200' );
}

# --- login page is always accessible ---
{
    my $out = run_processor( $docroot, '/login' );
    like( $out, qr/Status: 200/, 'login page → 200 without auth' );
}

done_testing();

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

sub reset_env {
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_NAME};
    delete $ENV{HTTP_X_REMOTE_EMAIL};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
}

my %sv = ( auth_redirect => '/login' );

# --- auth: none always passes ---
reset_env();
{
    my $r = main::check_auth( '/page', { auth => 'none' }, \%sv );
    is( $r->{ok}, 1, 'auth=none allows through' );
}

# --- auth: required without header redirects to login ---
reset_env();
{
    my $r = main::check_auth( '/page', { auth => 'required' }, \%sv );
    ok( $r->{redirect},        'missing auth → redirect' );
    like( $r->{redirect}, qr{^/login}, 'redirect starts with /login' );
    like( $r->{redirect}, qr{next=},    'next param appended' );
}

# --- auth: required with user header passes ---
{
    local $ENV{HTTP_X_REMOTE_USER}   = 'alice';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'members,admins';
    my $r = main::check_auth( '/page', { auth => 'required' }, \%sv );
    is( $r->{ok}, 1, 'auth with header passes' );
    is( $r->{auth_user}, 'alice', 'auth_user populated' );
    is_deeply( $r->{auth_groups}, [ 'members', 'admins' ],
              'auth_groups split on comma' );
}

# --- group restriction: correct group passes ---
{
    local $ENV{HTTP_X_REMOTE_USER}   = 'alice';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'members,admins';
    my $r = main::check_auth( '/page',
        { auth => 'required', groups => ['admins'] }, \%sv );
    is( $r->{ok}, 1, 'correct group passes' );
}

# --- group restriction: wrong group forbidden ---
{
    local $ENV{HTTP_X_REMOTE_USER}   = 'bob';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'members';
    my $r = main::check_auth( '/page',
        { auth => 'required', groups => ['admins'] }, \%sv );
    is( $r->{forbidden}, 1, 'missing required group → forbidden' );
    is( $r->{auth_denied_reason}, 'insufficient_groups',
        'denied reason populated' );
    is_deeply( $r->{auth_required_groups}, ['admins'],
        'required groups echoed back' );
}

# --- login path always accessible even when auth required ---
reset_env();
{
    my $r = main::check_auth( '/login',
        { auth => 'required' }, { auth_redirect => '/login' } );
    is( $r->{ok}, 1, 'login path bypasses auth' );
}

# --- auth_redirect prefix accessible ---
reset_env();
{
    my $r = main::check_auth( '/login/reset',
        { auth => 'required' }, { auth_redirect => '/login' } );
    is( $r->{ok}, 1, 'auth_redirect prefix bypasses auth' );
}

# --- custom header names ---
reset_env();
{
    local $ENV{HTTP_X_MYAPP_USER}   = 'bob';
    local $ENV{HTTP_X_MYAPP_GROUPS} = 'staff';
    my $r = main::check_auth( '/page',
        { auth => 'required' },
        {
            auth_redirect       => '/login',
            auth_header_user    => 'X-Myapp-User',
            auth_header_groups  => 'X-Myapp-Groups',
        },
    );
    is( $r->{ok}, 1, 'custom headers honoured' );
    is( $r->{auth_user}, 'bob', 'auth_user from custom header' );
}

done_testing();

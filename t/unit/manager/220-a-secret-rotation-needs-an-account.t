#!/usr/bin/perl
# SM944 ITEM 1, a security fix (ruled 2026-10-10, "SECURITY first"): the
# site's auth secret is rotated for an account. Rotating it signs every session
# out. Inside a request the dispatcher has refused an empty $auth_user and
# passes it to the action, so the answer there is unchanged (t/journey/02 and
# t/integration/114 rotate it through requests). Reached outside one - the
# request context as its reset leaves it, nobody - action_rotate_auth_secret('')
# rotated the secret with nobody asking (tmp/sm944-s31-s32-refusal-probe.out).
# Now it refuses before /dev/urandom is opened, and leaves the secret and the
# CSRF secret as they are.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/manager" );
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }
my $SECRET = "$d/lazysite/auth/.secret";
my $CSRF   = "$d/lazysite/manager/.csrf-secret";
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( $SECRET,                     ( 'a' x 64 ) . "\n" );
spit( $CSRF,                       ( 'c' x 64 ) . "\n" );
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $d;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();

# The dispatcher's call: the request's account.
sub rotate {
    no warnings 'once';
    return main::action_rotate_auth_secret($Lazysite::Manager::Common::auth_user);
}

subtest 'outside a request nothing is rotated' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my $r = rotate();
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    is( slurp($SECRET), ( 'a' x 64 ) . "\n", '...the auth secret is unchanged' );
    ok( -e $CSRF, '...and the CSRF secret is still there' );

    $r = main::action_rotate_auth_secret(undef);
    is( $r->{kind} // '', 'forbidden',         'an undefined account is refused too' );
    is( slurp($SECRET),   ( 'a' x 64 ) . "\n", '...the auth secret is unchanged' );
};

subtest 'for an account the secret is rotated; after a reset, refused again' => sub {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    my $r = rotate();
    ok( $r->{ok}, 'rotated' ) or diag explain $r;
    my $new = slurp($SECRET);
    like( $new, qr/\A[0-9a-f]{64}\n\z/, '...a new 32-byte secret' );
    isnt( $new, ( 'a' x 64 ) . "\n", '...not the old one' );
    ok( !-e $CSRF, '...and the CSRF secret was cleared' );

    Lazysite::Manager::Common::reset_request_context();
    spit( $CSRF, ( 'c' x 64 ) . "\n" );
    $r = rotate();
    is( $r->{kind} // '', 'forbidden', 'reset: refused again' );
    is( slurp($SECRET),   $new,        '...the secret is as the account left it' );
    ok( -e $CSRF, '...and the CSRF secret is still there' );
};

done_testing();

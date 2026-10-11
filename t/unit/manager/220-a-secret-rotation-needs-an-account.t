#!/usr/bin/perl
# SM944 ITEM 1, a security fix (ruled 2026-10-10, "SECURITY first"): the
# site's auth secret is rotated for an account. Rotating it signs every session
# out. Inside a request the dispatcher has refused an empty $auth_user and
# passes it to the action, so the answer there is unchanged (t/journey/02 and
# t/integration/114 rotate it through requests). Reached outside one - the
# request context as its reset leaves it, nobody - action_rotate_auth_secret('')
# rotated the secret with nobody asking (tmp/sm944-s31-s32-refusal-probe.out).
# Now it refuses before /dev/urandom is opened, and leaves the secret and the
# CSRF secret as they are. SM944 Q14 n342 (ruled 2026-10-11, "Yes, same as
# whoami"; scope ruled "manage_config may rotate"): and it refuses unless the
# account is the one asking - a named account outside a request and another
# account than the one asking are refused; the signed-in account itself
# rotates, a manager holding manage_config without manage_users included.
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

# SM944 Q14 n342, ruled 2026-10-11 ("Yes, same as whoami"): the account must be
# the one asking. The refusal above trusted the account it was handed, so a
# caller outside a request that named one still rotated.
subtest 'outside a request a named account is refused too' => sub {
    no warnings 'once';
    is( $Lazysite::Manager::Common::auth_user, '', 'nobody is asking' );
    my $r = main::action_rotate_auth_secret('boss');
    is( $r->{kind} // '', 'forbidden', 'an account nobody signed in as is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/the signed-in account that is asking/, '...saying why' );
    is( slurp($SECRET), ( 'a' x 64 ) . "\n", '...the auth secret is unchanged' );
    ok( -e $CSRF, '...and the CSRF secret is still there' );

    $Lazysite::Manager::Common::auth_user = 'alice';

    $r = main::action_rotate_auth_secret('boss');
    is( $r->{kind} // '', 'forbidden',         'with alice asking, boss is refused' );
    is( slurp($SECRET),   ( 'a' x 64 ) . "\n", '...the auth secret is unchanged' );
    Lazysite::Manager::Common::reset_request_context();
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

# SM944 Q14 n342, scope ruled 2026-10-11 ("manage_config may rotate"): the
# dispatcher's cookie gate for rotate-auth-secret asks manage_config, and the
# action asks only that the account is the one asking - so a signed-in manager
# holding manage_config without manage_users rotates through a real request.
subtest 'through a request, the signed-in account with manage_config rotates' => sub {
    require ManagerSession;
    my $s   = ManagerSession::new_site( root => repo_root() );
    my @ALL = qw(ui manage_users manage_config);
    $s->add_user('carol');
    $s->grant( 'carol', 'configurers', [qw(ui manage_config)], \@ALL );
    my $lz     = $s->docroot . '/lazysite';
    my $secret = sub { slurp("$lz/auth/.secret") };
    my $before = $secret->();

    # A real request: the script runs, so it must not be told to load only.
    delete local $ENV{LAZYSITE_API_LOAD_ONLY};
    my $r = $s->call( 'carol', 'rotate-auth-secret', body => {} );
    ok( $r->{ok}, 'carol (manage_config, not manage_users) rotates' ) or diag explain $r;
    my $after = $secret->();
    like( $after, qr/\A[0-9a-f]{64}\n\z/, '...a new 32-byte secret' );
    isnt( $after, $before, '...not the old one' );
};

done_testing();

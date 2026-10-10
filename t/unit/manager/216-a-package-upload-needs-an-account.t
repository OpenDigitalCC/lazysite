#!/usr/bin/perl
# SM944 S28, the established fail-closed pattern (ruled 2026-10-09/10 for S23-
# S26): site-backup-upload stores a package for an account. Inside a request the
# dispatcher has refused an empty $auth_user and required `manage_domains`
# before it runs, so its answer there is unchanged - nothing else drove the
# upload through a request, so the first subtest does, and it passes on the
# manager API before the refusal as after. Reached outside one - the request
# context as its reset leaves it, nobody - action_site_backup_upload wrote a
# package into backups/ (tmp/sm944-s27-s28-refusal-probe.out). Now it refuses
# before it reads the body.
#
# The second half loads the script the way the unit tests load it
# (LAZYSITE_API_LOAD_ONLY: compiled, no request run), and resets the context as
# any process that never sets one leaves it.
use strict;
use warnings;
use Test::More;
use FindBin;
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use JSON::PP   qw(decode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use lib repo_root() . '/lib';

my $s = new_site( root => repo_root() );
my $d = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains)], [qw(ui manage_domains)] );
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

my $B = 'xYzPackageBoundary';
my $MP = "--$B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"site.tar.gz\"\r\n"
    . "Content-Type: application/gzip\r\n\r\nGZBYTES\r\n--$B--\r\n";
sub stored { return glob "$d/lazysite/backups/lazysite-site-uploaded-*" }

# A manager request carrying a raw multipart body, as the browser sends it;
# ManagerSession::call sends JSON, so this is its sequence with the body raw.
sub upload_request {
    my ($user) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION LAZYSITE_AUTH_TOKEN LAZYSITE_API_LOAD_ONLY)};
    $ENV{HTTP_X_REMOTE_USER}    = $user;
    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{LAZYSITE_USERS_TOOL}   = $s->{users};
    $ENV{QUERY_STRING}          = 'action=site-backup-upload';
    $ENV{REQUEST_METHOD}        = 'POST';
    $ENV{CONTENT_TYPE}          = "multipart/form-data; boundary=$B";
    $ENV{CONTENT_LENGTH}        = length $MP;
    $ENV{HTTP_COOKIE}           = $s->cookie_for($user);
    $ENV{HTTP_X_CSRF_TOKEN}     = $s->csrf_for($user);
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $s->{api} );
    print {$w} $MP;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) };
    return ref $res eq 'HASH' ? $res : { _raw => $out };
}

subtest 'inside a request, site-backup-upload answers as before' => sub {
    my $r = upload_request('boss');
    ok( $r->{ok}, 'a manager\'s upload is stored' ) or diag explain $r;
    like( $r->{name} // '', qr/\Alazysite-site-uploaded-\d{8}T\d{6}Z\.tar\.gz\z/, '...under a namespaced name' );
    my @got = stored();
    is( scalar @got, 1, '...in backups/' );
    unlink @got;
};

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $d;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();

subtest 'site-backup-upload, outside a request, stores nothing' => sub {
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$B";
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my $r = main::action_site_backup_upload($MP);
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    is( scalar( () = stored() ), 0, '...and nothing was stored' );

    # The same call for an account stores it - so it is the empty account that
    # is refused, not the fixture.
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    $r                                    = main::action_site_backup_upload($MP);
    ok( $r->{ok}, 'for an account it is stored' ) or diag explain $r;
    is( scalar( () = stored() ), 1, '...in backups/' );
    unlink stored();
    Lazysite::Manager::Common::reset_request_context();
    is( main::action_site_backup_upload($MP)->{kind} // '', 'forbidden', 'reset: refused again' );
    is( scalar( () = stored() ),                            0, '...storing nothing' );
};

done_testing();

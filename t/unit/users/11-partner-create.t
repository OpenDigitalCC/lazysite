#!/usr/bin/perl
# SM071 Phase 2: partner-create - one-step partner provisioning with an
# onboarding brief.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $script = repo_root() . "/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://example.test\n";
    close $cf;
    return $d;
}
sub cli {
    my ( $d, @a ) = @_;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $script, '--docroot', $d, @a );
    close $w; my $o = do { local $/; <$r> }; my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    return { out => $o // '', err => $err // '', code => $? >> 8 };
}
sub api {
    my ( $d, $p ) = @_;
    my ( $co, $ci );
    my $pid = open2( $co, $ci, $^X, $script, '--api', '--docroot', $d );
    print $ci encode_json($p); close $ci;
    my $o = do { local $/; <$co> }; close $co; waitpid $pid, 0;
    return eval { decode_json($o) } // { _raw => $o };
}
sub settings { api( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} }

my $d = fresh_docroot();
cli( $d, 'add', 'boss', 'pw' );
grant_caps( $d, 'boss', 'create_sub_users' );
grant_caps( $d, 'boss', 'delegate_sub_user_creation' );

# --- default partner: webdav + manage_themes, brief, pairing key ------
my $r = api( $d, { action => 'partner-create', username => 'designer', created_by => 'boss' } );
ok( $r->{ok}, 'partner-create ok' );
like( $r->{pairing_key}, qr/^lzp_/, 'pairing key returned' );
like( $r->{onboarding}, qr/designer/, 'brief names the partner' );
like( $r->{onboarding}, qr{https://example\.test/dav/}, 'brief carries the DAV URL' );
like( $r->{onboarding}, qr/\Q$r->{pairing_key}\E/, 'brief embeds the pairing key' );

my $s = settings( $d, 'designer' );
ok( $s->{webdav},        'partner has webdav' );
ok( $s->{manage_themes}, 'partner has manage_themes by default' );
ok( !$s->{manage_layouts}, 'no manage_layouts unless requested' );
is( $s->{created_by}, 'boss', 'provenance recorded' );

# --- extras: layouts, config, scope -----------------------------------
api( $d, { action => 'partner-create', username => 'builder', created_by => 'boss',
    manage_layouts => 1, manage_config => 1, dav_scope => '/content' } );
my $s2 = settings( $d, 'builder' );
ok( $s2->{manage_layouts}, 'builder: manage_layouts on' );
ok( $s2->{manage_config},  'builder: manage_config on' );
is( $s2->{dav_scope}, '/content', 'builder: scope set' );

# --- the pairing key actually works -----------------------------------
my $ex = api( $d, { action => 'token-exchange',
    username => 'designer', pairing_key => $r->{pairing_key} } );
ok( $ex->{ok} && $ex->{token} =~ /^lzs_/, 'partner pairing key exchanges for a token' );

# --- gating: creator without create_sub_users -------------------------
cli( $d, 'add', 'plain', 'pw' );
my $denied = api( $d, { action => 'partner-create', username => 'x', created_by => 'plain' } );
ok( !$denied->{ok}, 'partner-create denied when creator lacks create_sub_users' );

done_testing();

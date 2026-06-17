#!/usr/bin/perl
# SM071 Phase 2: manage_themes / manage_layouts / manage_config capability
# flags (same set/get path as webdav/ui).
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
use TestHelper qw(repo_root);

my $script = repo_root() . "/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    return $d;
}
sub cli {
    my ( $d, @a ) = @_;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $script, '--docroot', $d, @a );
    close $w; my $out = do { local $/; <$r> }; my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    return { out => $out // '', err => $err // '', code => $? >> 8 };
}
sub settings {
    my ( $d, $u ) = @_;
    my ( $co, $ci );
    my $pid = open2( $co, $ci, $^X, $script, '--api', '--docroot', $d );
    print $ci encode_json({ action => 'settings-get', username => $u });
    close $ci; my $out = do { local $/; <$co> }; close $co; waitpid $pid, 0;
    return ( eval { decode_json($out) } // {} )->{settings};
}

my $d = fresh_docroot();
cli( $d, 'add', 'u', 'pw' );

my $s = settings( $d, 'u' );
ok( !$s->{manage_themes},  'manage_themes defaults off' );
ok( !$s->{manage_layouts}, 'manage_layouts defaults off' );
ok( !$s->{manage_config},  'manage_config defaults off' );

cli( $d, 'set', 'u', 'manage_themes',  'on' );
cli( $d, 'set', 'u', 'manage_layouts', 'on' );
$s = settings( $d, 'u' );
ok( $s->{manage_themes},  'manage_themes set on' );
ok( $s->{manage_layouts}, 'manage_layouts set on' );
ok( !$s->{manage_config}, 'manage_config still off (independent)' );

my $bad = cli( $d, 'set', 'u', 'manage_bogus', 'on' );
isnt( $bad->{code}, 0, 'unknown capability key rejected' );

done_testing();

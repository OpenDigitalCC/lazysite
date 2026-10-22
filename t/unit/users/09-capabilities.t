#!/usr/bin/perl
# SM071 Phase 2: manage_themes / manage_layouts / manage_config capability
# flags (same set/get path as webdav/ui).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps run_child);

my $script = repo_root() . "/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    return $d;
}
sub cli {
    my ( $d, @a ) = @_;
    my ( $out, $err ) = @{ run_child( [ $^X, $script, '--docroot', $d, @a ] ) }{qw(out err)};
    return { out => $out // '', err => $err // '', code => $? >> 8 };
}
sub settings {
    my ( $d, $u ) = @_;
    my $out = run_child( [ $^X, $script, '--api', '--docroot', $d ],
        stdin => encode_json({ action => 'settings-get', username => $u }), stderr => 'inherit' )->{out};
    return ( eval { decode_json($out) } // {} )->{settings};
}

my $d = fresh_docroot();
cli( $d, 'add', 'u', 'pw-long-enough' );

my $s = settings( $d, 'u' );
ok( !$s->{manage_themes},  'manage_themes defaults off' );
ok( !$s->{manage_layouts}, 'manage_layouts defaults off' );
ok( !$s->{manage_config},  'manage_config defaults off' );

grant_caps( $d, 'u', 'manage_themes' );
grant_caps( $d, 'u', 'manage_layouts' );
$s = settings( $d, 'u' );
ok( $s->{manage_themes},  'manage_themes set on' );
ok( $s->{manage_layouts}, 'manage_layouts set on' );
ok( !$s->{manage_config}, 'manage_config still off (independent)' );

my $bad = cli( $d, 'set', 'u', 'manage_bogus', 'on' );
isnt( $bad->{code}, 0, 'unknown capability key rejected' );

done_testing();

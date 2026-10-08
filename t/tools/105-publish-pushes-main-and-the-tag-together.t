#!/usr/bin/perl
# SM971: PUBLISH PUSHES MAIN AND THE TAG TOGETHER, AND FORCES NOTHING.
#
# The release commit build makes is on local main and nowhere else, so the
# release manager's one step pushes main and the tag in one atomic push. It
# refuses when origin's main is not an ancestor of local main (that push would
# discard commits on origin, and publish never forces), when the tag is already
# on origin (a burned version is never reused, SM064), and when the tag is not
# on local main. Driven against a stand-in remote: a bare repository on disk,
# so nothing here touches a network.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();

sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; chomp $o; $o }
sub commit { my ( $d, $m ) = @_; spit( "$d/f", "$m\n" ); git( $d, 'add', '-A' ); git( $d, 'commit', '-q', '-m', $m ); git( $d, 'rev-parse', 'HEAD' ) }
sub remote_ref { my ( $r, $ref ) = @_; my $o = run_cmd( 'git', '-C', $r, 'rev-parse', '--verify', '--quiet', $ref ); chomp $o; $? ? '' : $o }

# A repository whose origin (a bare repo) has main one commit behind, and a
# local release commit on main tagged v0.1.1 - what build leaves.
sub setup {
    my $d = tempdir( CLEANUP => 1 );
    my $r = tempdir( CLEANUP => 1 );
    git( $r, 'init',   '-q',         '--bare', '-b', 'main' );
    git( $d, 'init',   '-q',         '-b',     'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/release.sh", "$d/tools/release.sh" ) or die $!;
    spit( "$d/.gitignore", "tmp/\n" );
    my $base = commit( $d, 'base' );
    git( $d, 'remote', 'add', 'origin', $r );
    git( $d, 'push', '-q', 'origin', "$base:refs/heads/main" ); # the fixture, not the subject
    my $rel = commit( $d, 'lazysite 0.1.1 (edge): the release commit' );
    git( $d, 'tag', '-a', 'v0.1.1', '-m', 'lazysite 0.1.1', $rel );
    return ( $d, $r, $base, $rel );
}

sub publish {
    my ( $d, $v ) = @_;
    my $out = run_cmd( 'bash', "$d/tools/release.sh", 'publish', $v // '0.1.1' );
    return ( $? >> 8, $out );
}

subtest 'main and the tag go up together' => sub {
    my ( $d, $r, $base, $rel ) = setup();
    my ( $rc, $out ) = publish($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    is( remote_ref( $r, 'refs/heads/main' ), $rel, 'origin\'s main is the release commit' );
    is( remote_ref( $r, 'refs/tags/v0.1.1^{commit}' ), $rel, 'and the tag is there, on it' );
    like( $out, qr/Pushing main \($rel\) and v0\.1\.1/, 'saying both' );
};

subtest 'a tag already on origin is a burned version' => sub {
    my ( $d, $r, $base ) = setup();
    git( $d, 'push', '-q', 'origin', 'refs/tags/v0.1.1' );
    my ( $rc, $out ) = publish($d);
    is( $rc, 1, 'refused' );
    like( $out, qr/v0\.1\.1 is ALREADY on origin.*never\s+.*reused \(SM064\)/s, 'as burned' );
    is( remote_ref( $r, 'refs/heads/main' ), $base, 'and main was not pushed' );
};

subtest 'an origin main that local main does not contain is never overwritten' => sub {
    my ( $d, $r, $base ) = setup();
    my $o = tempdir( CLEANUP => 1 );
    git( $o, 'clone',  '-q',         $r, '.' );
    git( $o, 'config', 'user.email', 't@example.invalid' );
    git( $o, 'config', 'user.name',  't' );
    my $theirs = commit( $o, 'pushed from elsewhere' );
    git( $o, 'push', '-q', 'origin', 'HEAD:refs/heads/main' );
    my ( $rc, $out ) = publish($d);
    is( $rc, 1, 'refused' );
    like( $out, qr/origin's main \($theirs\) is not an ancestor of local main/, 'naming both' );
    like( $out, qr/publish never forces/, 'and why it stops' );
    is( remote_ref( $r, 'refs/heads/main' ),  $theirs, 'origin\'s main is untouched' );
    is( remote_ref( $r, 'refs/tags/v0.1.1' ), '', 'and the tag was not pushed either' );
};

subtest 'a tag that is not on local main is not published' => sub {
    my ( $d, $r, $base ) = setup();
    git( $d, 'checkout', '-q', '-b', 'side', $base );
    my $side = commit( $d, 'off main' );
    git( $d, 'tag', '-a', 'v0.1.2', '-m', 'off main', $side );
    my ( $rc, $out ) = publish( $d, '0.1.2' );
    is( $rc, 1, 'refused' );
    like( $out, qr/v0\.1\.2 .* is not on local main/, 'saying so' );
    is( remote_ref( $r, 'refs/tags/v0.1.2' ), '', 'nothing pushed' );
};

subtest 'a tag that was never built cannot be published' => sub {
    my ($d) = setup();
    my ( $rc, $out ) = publish( $d, '0.9.9' );
    is( $rc, 1, 'refused' );
    like( $out, qr/v0\.9\.9 not found locally/, 'it cannot invent one' );
};

done_testing();

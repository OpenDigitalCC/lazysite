#!/usr/bin/perl
# SM1174 (ruling 2026-10-18: "Shown in the manager's page status"; the
# operator's view of a page is the editor's status bar): the file read and the
# file save answer `camera: "self"` for a page whose front matter grants the
# camera, decided on the server by the validator's reader, and the editor shows
# "Camera allowed on this page (https only)". An unreadable value shows the
# validator's issue instead. The editor holds no copy of the rule.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                qw(site_tempdir repo_root);
use PageScript                ();
use Lazysite::Paths           ();
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
my $d  = site_tempdir();
my $lz = Lazysite::Paths::external_lazysite_dir($d);
make_path( $d, "$lz/cache", "$lz/manager/locks" );
spit( "$lz/lazysite.conf", "site_name: T\n" );
{
    no warnings 'once';
    $Lazysite::Manager::Files::DOCROOT       = $d;
    $Lazysite::Manager::Files::LAZYSITE_DIR  = $lz;
    $Lazysite::Manager::Files::LOCK_DIR      = "$lz/manager/locks";
    $Lazysite::Manager::Common::DOCROOT      = $d;
    $Lazysite::Manager::Common::LAZYSITE_DIR = $lz;
}
spit( "$d/scan.md",  "---\ntitle: S\ncamera: self\n---\nx\n" );
spit( "$d/plain.md", "---\ntitle: P\n---\nx\n" );
spit( "$d/star.md",  "---\ntitle: X\ncamera: *\n---\nx\n" );
spit( "$d/data.txt", "camera: self\n" );

subtest 'the file read carries the flag for a camera page and no other' => sub {
    my $r = Lazysite::Manager::Files::action_read( 'scan.md', 'op' );
    is( $r->{camera}, 'self', 'camera page: camera self' ) or diag explain $r;
    for my $p (qw(plain.md data.txt)) {
        my $o = Lazysite::Manager::Files::action_read( $p, 'op' );
        ok( !exists $o->{camera} && !exists $o->{camera_issue}, "$p: nothing" );
    }
    my $x = Lazysite::Manager::Files::action_read( 'star.md', 'op' );
    ok( !exists $x->{camera}, 'an unreadable value grants nothing' );
    like( $x->{camera_issue} // '', qr/camera: \*.*self/, '...and carries the validator issue' ) or diag explain $x;
};
subtest 'the save answers the same' => sub {
    my $s = Lazysite::Manager::Files::action_save( 'new.md', 'op', "---\ntitle: N\ncamera: self\n---\nb\n" );
    ok( $s->{ok}, 'saved' ) or diag explain $s;
    is( $s->{camera}, 'self', 'camera self on the save answer' );
    my $p = Lazysite::Manager::Files::action_save( 'new2.md', 'op', "---\ntitle: N\n---\nb\n" );
    ok( !exists $p->{camera}, 'a page without it: nothing' );
    my $b = Lazysite::Manager::Files::action_save( 'new3.md', 'op', "---\ntitle: N\ncamera: https://x\n---\nb\n" );
    ok( $b->{ok} && !exists $b->{camera} && $b->{camera_issue}, 'a bad value saves (advisory) and names the issue' ) or diag explain $b;
};

# --- the editor, in node
my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 1 unless length $node && -x $node;
    my $page = PageScript::page_source("$root/starter/manager/edit.md");
    my $fn   = PageScript::extract_function( $page, 'edShowCamera' );
    my $dir  = File::Temp->newdir;
    open my $fh, '>', "$dir/t.js" or die $!;
    print {$fh} <<'JS', $fn, <<'JS2';
var el = { textContent: 'stale' };
var document = { getElementById: function (id) { return id === 'ed-camera' ? el : null; } };
JS
console.log(JSON.stringify([
  (edShowCamera({ ok: 1, camera: 'self' }), el.textContent),
  (edShowCamera({ ok: 1 }), el.textContent),
  (edShowCamera({ ok: 1, camera_issue: "'camera: *' is not one of self, none" }), el.textContent)
]));
JS2
    close $fh;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $r = eval { JSON::PP::decode_json($out) } || [];
    is( $r->[0], 'Camera allowed on this page (https only)', 'the editor shows the sentence' ) or diag $out;
    is( $r->[1], '', 'and clears it for a page without' );
    like( $r->[2] // '', qr/camera: \*/, 'and shows the validator issue for a bad value' );
}
done_testing;

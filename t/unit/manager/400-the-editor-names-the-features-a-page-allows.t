#!/usr/bin/perl
# SM1266: the editor's status bar - the manager's view of a page, as SM1174 made
# it for the camera - names every feature a page allows. The file read and the
# file save answer `permissions` (the features, camera among them) and
# `permission_issues` (the validator's sentence for any other feature's value it
# cannot read, or a `<key>: self` that is no feature), decided on the server by
# the validator's reader. The camera's own fields and sentence are unchanged.
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
spit( "$d/clock.md", "---\ntitle: C\ngeolocation: self\nmicrophone: self\n---\nx\n" );
spit( "$d/scan.md",  "---\ntitle: S\ncamera: self\n---\nx\n" );
spit( "$d/plain.md", "---\ntitle: P\n---\nx\n" );
spit( "$d/typo.md",  "---\ntitle: T\ngeolocaton: self\nmicrophone: *\n---\nx\n" );

subtest 'the file read names the features a page allows' => sub {
    my $r = Lazysite::Manager::Files::action_read( 'clock.md', 'op' );
    is_deeply( $r->{permissions}, [qw(geolocation microphone)], 'geolocation and microphone' ) or diag explain $r;
    ok( !exists $r->{camera} && !exists $r->{permission_issues}, 'and nothing else' );
    my $s = Lazysite::Manager::Files::action_read( 'scan.md', 'op' );
    is( $s->{camera}, 'self', "a camera page keeps SM1174's field" );
    is_deeply( $s->{permissions}, ['camera'], '...and is listed with the rest' );
    my $p = Lazysite::Manager::Files::action_read( 'plain.md', 'op' );
    ok( !exists $p->{permissions} && !exists $p->{permission_issues}, 'a plain page: nothing' );
};
subtest 'an unreadable value or an unknown name carries the validator issue' => sub {
    my $x = Lazysite::Manager::Files::action_read( 'typo.md', 'op' );
    ok( !exists $x->{permissions}, 'grants nothing' );
    my @i = @{ $x->{permission_issues} || [] };
    is( scalar @i, 2, 'two issues' ) or diag explain $x;
    like( "@i", qr/microphone: \*.*self/, 'the bad value' );
    like( "@i", qr/geolocaton: self' grants nothing/, 'and the unknown name' );
};
subtest 'the save answers the same' => sub {
    my $s = Lazysite::Manager::Files::action_save( 'new.md', 'op', "---\ntitle: N\ngeolocation: self\n---\nb\n" );
    ok( $s->{ok}, 'saved' ) or diag explain $s;
    is_deeply( $s->{permissions}, ['geolocation'], 'on the save answer' );
    my $b = Lazysite::Manager::Files::action_save( 'new2.md', 'op', "---\ntitle: N\ngeolocation: yes\n---\nb\n" );
    ok( $b->{ok} && !exists $b->{permissions} && @{ $b->{permission_issues} || [] },
        'a bad value saves (advisory) and names the issue' ) or diag explain $b;
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
  (edShowCamera({ ok: 1, permissions: ['geolocation', 'microphone'] }), el.textContent),
  (edShowCamera({ ok: 1, camera: 'self', permissions: ['camera'] }), el.textContent),
  (edShowCamera({ ok: 1, camera: 'self', permissions: ['camera', 'geolocation'] }), el.textContent),
  (edShowCamera({ ok: 1, permission_issues: ["'geolocaton: self' grants nothing"] }), el.textContent),
  (edShowCamera({ ok: 1 }), el.textContent)
]));
JS2
    close $fh;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $r = eval { JSON::PP::decode_json($out) } || [];
    is( $r->[0], 'Allowed on this page (https only): geolocation, microphone', 'the editor names the features' )
        or diag $out;
    is( $r->[1], 'Camera allowed on this page (https only)', "a camera page: SM1174's sentence, unchanged" );
    is( $r->[2], 'Camera allowed on this page (https only); Allowed on this page (https only): geolocation',
        'the camera and another' );
    like( $r->[3] // '', qr/geolocaton: self/, 'an issue is shown' );
    is( $r->[4], '', 'and a page without any: cleared' );
}
done_testing;

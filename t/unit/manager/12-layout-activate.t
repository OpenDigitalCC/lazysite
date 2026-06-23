#!/usr/bin/perl
# SM071 Phase 3 (P3.5): layout-activate - layout.tt-compiles gate and the
# compatible-(layout, theme) pair rule.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $utool   = "$root/tools/lazysite-users.pl";
my $mscript = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return decode_json($out);
}
sub mapi {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mscript );
    close $w;
    my $out = do { local $/; <$r> }; close $e; waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/layouts/base/themes/baseonly");
make_path("$d/lazysite/layouts/alt/themes/shared");
make_path("$d/lazysite/layouts/bad");

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: baseonly\nbackup_retention: 3\n";
close $cf;
_w( "layouts/base/layout.tt",   '<html>[% content %]</html>' );
_w( "layouts/alt/layout.tt",    '<html><main>[% content %]</main></html>' );
_w( "layouts/bad/layout.tt",    '[% IF foo %]never closed' );
_w( "layouts/base/themes/baseonly/theme.json", '{"name":"baseonly","layouts":["base"]}' );
_w( "layouts/alt/themes/shared/theme.json",    '{"name":"shared","layouts":["base","alt"]}' );
sub _w { my ( $rel, $c ) = @_; open my $f, '>', "$d/lazysite/$rel" or die $!; print $f $c; close $f; }

uapi( $d, { action => 'add', username => 'p', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'p', key => 'manage_layouts', value => 'on' } );
uapi( $d, { action => 'settings-set', username => 'p', key => 'manage_themes',  value => 'on' } );
my $tok  = uapi( $d, { action => 'token', username => 'p' } )->{token};
my $auth = basic( 'p', $tok );

sub active {
    my ( $l, $t ) = ( '', '' );
    open my $fh, '<', "$d/lazysite/lazysite.conf" or return ( '', '' );
    while (<$fh>) { $l = $1 if /^layout\s*:\s*(\S+)/; $t = $1 if /^theme\s*:\s*(\S+)/ }
    close $fh; return ( $l, $t );
}

# --- compile gate via artifact-validate ------------------------------
my $vb = mapi( $d, QUERY_STRING => 'action=artifact-validate&layout=bad', HTTP_AUTHORIZATION => $auth );
ok( !$vb->{valid}, 'artifact-validate: broken layout.tt invalid' );
my $vg = mapi( $d, QUERY_STRING => 'action=artifact-validate&layout=alt', HTTP_AUTHORIZATION => $auth );
ok( $vg->{valid}, 'artifact-validate: good layout valid' );

# --- layout-activate refuses an uncompilable layout ------------------
my $ab = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=layout-activate&path=bad',
    HTTP_AUTHORIZATION => $auth );
ok( !$ab->{ok} && $ab->{error} =~ /compile|invalid/i, 'activate refuses uncompilable layout' );

# --- incompatible pair: current theme not declared for new layout ----
my $inc = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=layout-activate&path=alt',
    HTTP_AUTHORIZATION => $auth );
ok( !$inc->{ok} && $inc->{incompatible}, 'incompatible (layout, theme) pair refused' );
is( ( active() )[0], 'base', 'layout unchanged after incompatible activate' );

# --- the activation cache-clear must spare author .html partials -----
# (SM072 report: activation deleted author include-partials, gutting pages).
# Files at the DOCROOT root (not under lazysite/, which the clear skips).
make_path("$d/partials");
open my $cm, '>', "$d/about.md"           or die $!; print $cm "---\ntitle: About\n---\nhi\n"; close $cm;
open my $ch, '>', "$d/about.html"         or die $!; print $ch '<cached>';                     close $ch;
open my $cp, '>', "$d/partials/note.html" or die $!; print $cp '<p>author partial</p>';        close $cp;

# --- compatible: name a theme that declares the new layout -----------
my $okr = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=layout-activate&path=alt&theme=shared',
    HTTP_AUTHORIZATION => $auth );
ok( $okr->{ok}, 'activate with a compatible theme succeeds' );
ok( !-f "$d/about.html",         'activation cleared the generated cache (.html with a .md source)' );
ok(  -f "$d/partials/note.html", 'activation preserved the author .html partial (no .md source)' );
my ( $L, $T ) = active();
is( $L, 'alt',    'layout flipped to alt' );
is( $T, 'shared', 'theme switched to the compatible one' );
my @lbk = glob("$d/lazysite/layouts/base-backup-*");
ok( @lbk >= 1, 'outgoing layout snapshotted' );

done_testing();

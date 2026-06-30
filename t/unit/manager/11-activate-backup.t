#!/usr/bin/perl
# SM071 Phase 3: activate-with-backup - validation, base-manifest
# conditional, artifact lock, outgoing-theme snapshot.
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
use TestHelper qw(repo_root grant_caps);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
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
for my $t (qw(live new broken)) {
    make_path("$d/lazysite/layouts/base/themes/$t");
}
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: live\nbackup_retention: 3\n";
close $cf;
# live + new declare base; broken declares a different layout (invalid here)
_theme( 'live', '["base"]' );
_theme( 'new',  '["base"]' );
_theme( 'broken', '["other"]' );
sub _theme {
    my ( $name, $layouts ) = @_;
    open my $f, '>', "$d/lazysite/layouts/base/themes/$name/theme.json" or die $!;
    print $f qq({"name":"$name","layouts":$layouts}); close $f;
}

uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
grant_caps( $d, 'partner', 'manage_themes' );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
my $auth = basic( 'partner', $tok );

sub active_theme {
    my ($l, $t) = ('','');
    open my $fh, '<', "$d/lazysite/lazysite.conf" or return '';
    while (<$fh>) { $t = $1 if /^theme\s*:\s*(\S+)/ }
    close $fh; return $t;
}
sub backups { grep { /^live-backup-/ } map { s{.*/}{}r } glob("$d/lazysite/layouts/base/themes/live-backup-*") }

# --- validation gate: invalid candidate is refused --------------------
my $bad = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=theme-activate&path=broken', HTTP_AUTHORIZATION => $auth );
ok( !$bad->{ok} && $bad->{error} =~ /invalid/i, 'invalid theme refused' );
is( active_theme(), 'live', 'active theme unchanged after invalid activate' );

# --- lock gate: a held lock blocks activation -------------------------
make_path("$d/lazysite/manager/locks");
open my $lf, '>', "$d/lazysite/manager/locks/lazysite:layouts:base:themes:new.lock" or die $!;
print $lf encode_json({ user => 'someoneelse', at => time(), origin => 'dav', timeout => 300 });
close $lf;
my $locked = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=theme-activate&path=new', HTTP_AUTHORIZATION => $auth );
ok( !$locked->{ok} && $locked->{locked}, 'held lock blocks activation' );
unlink "$d/lazysite/manager/locks/lazysite:layouts:base:themes:new.lock";

# --- base-manifest conditional: wrong base -> conflict ----------------
my $man = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=new',
    HTTP_AUTHORIZATION => $auth );
ok( $man->{digest}, 'artifact-manifest returns a digest' );
my $conflict = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=theme-activate&path=new&base=deadbeef', HTTP_AUTHORIZATION => $auth );
ok( !$conflict->{ok} && $conflict->{conflict}, 'wrong base manifest -> conflict' );
is( active_theme(), 'live', 'active theme unchanged after conflict' );

# --- successful activate with correct base + backup -------------------
my $ok = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => "action=theme-activate&path=new&base=$man->{digest}",
    HTTP_AUTHORIZATION => $auth );
ok( $ok->{ok}, 'activate with correct base succeeds' );
is( active_theme(), 'new', 'pointer flipped to new' );
ok( scalar( backups() ) >= 1, 'outgoing live theme snapshotted as a backup' );

done_testing();

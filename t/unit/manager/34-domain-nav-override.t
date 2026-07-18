#!/usr/bin/perl
# SM169: a domain with its own nav_file override must be read (and written) by
# the nav editor from THAT file, not the shared base nav.conf. Reproduces the
# reported mismatch: the domain's nav_file (empty) vs the editor showing the
# base file's entry.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi_s = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; $t }

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi_s );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub post {
    my ( $d, $user, $groups, $qs, $obj ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN => csrf($user), body => encode_json( $obj // {} ) );
}
sub get {
    my ( $d, $user, $groups, $qs ) = @_;
    return mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups );
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nnav_file: lazysite/nav.conf\n" );
spit( "$d/lazysite/auth/.secret",  $secret );
spit( "$d/lazysite/nav.conf",      "Base Home | /\n" );    # the shared base menu

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_domains', 'manage_nav' );

# Register a subdomain with its own content root, then give it its own nav file.
ok( post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'sub.example.com', content_root => 'sites/sub' } )->{ok},
    'subdomain registered' );
ok( post( $d, 'op', 'role-op', 'action=domain-set',
        { host => 'sub.example.com', key => 'nav_file', value => 'lazysite/nav-2.conf' } )->{ok},
    'nav_file override set for the subdomain' );
like( slurp("$d/lazysite/lazysite.conf"),
    qr/^alias\.sub\.example\.com\.nav_file:\s*lazysite\/nav-2\.conf/m,
    'the override is written as alias.<host>.nav_file' );

# The override file has its OWN entry: the editor must read THAT, not the base.
spit( "$d/lazysite/nav-2.conf", "Sub Home | /welcome\n" );
my $r = get( $d, 'op', 'role-op', 'action=nav-read&host=sub.example.com' );
ok( $r->{ok}, 'nav-read for the subdomain' ) or diag encode_json($r);
is( $r->{nav_file},        'lazysite/nav-2.conf', 'resolves the domain override file' );
is( $r->{inherited},       0,                     'the domain nav is its own, not inherited' );
is( $r->{items}[0]{label}, 'Sub Home',            'reads the override file, not the base' );

# THE REPORTED CASE: the override file is EMPTY. The editor must show an empty
# menu - NOT leak the base file's entry.
spit( "$d/lazysite/nav-2.conf", "" );
my $r2 = get( $d, 'op', 'role-op', 'action=nav-read&host=sub.example.com' );
is( $r2->{nav_file}, 'lazysite/nav-2.conf', 'still resolves the override file when empty' );
is( scalar @{ $r2->{items} }, 0,
    'an empty override yields an empty menu (no base-nav leak)' );

# SM168: saving the nav invalidates the rendered HTML cache, so the new menu is
# published immediately instead of lingering behind stale page caches.
{
    spit( "$d/index.md",   "# Home\n" );
    spit( "$d/index.html", "<html>stale cache</html>" );    # a fake render cache
    my $sv = post( $d, 'op', 'role-op', 'action=nav-save',
        { items => [ { label => 'Home', url => '/', children => [] } ] } );
    ok( $sv->{ok}, 'nav-save ok' ) or diag encode_json($sv);
    ok( !-f "$d/index.html", 'the stale page cache is invalidated by the nav save' );
    ok( ( $sv->{cache_cleared} // 0 ) >= 1, 'nav-save reports the pages it refreshed' );
}

done_testing();

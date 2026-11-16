#!/usr/bin/perl
# SM1455: the bad-URL guard reads the request's path behind real Apache.
#
# lazysite-auth.pl took its path from REDIRECT_URL, which Apache sets only on an
# internal redirect. On the Hestia template's two routes into the wrapper - the
# SM797 source-type RewriteRule [PT] and FallbackResource - it is unset, so the
# guard asked whether "/" is a probe on every request and never counted one.
# t/integration/14 passed all along because it sets REDIRECT_URL itself.
#
# This runs the REAL wrapper and the REAL processor behind REAL Apache, with the
# two routing lines read out of installers/hestia/lazysite-cgi.tpl (so the test
# cannot drift from what ships), and sends probes by each route from one address.
# The visitor's address is the X-Forwarded-For hop, the loopback peer being a
# trusted proxy (SM929), so one server holds several addresses.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_test_site site_tempdir);

my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
plan skip_all => 'apache2 not installed' unless $APACHE;
my $MODS = '/usr/lib/apache2/modules';
plan skip_all => 'apache2 modules not found' unless -f "$MODS/mod_rewrite.so";

my $root = repo_root();

# The two routes, as the template ships them: the source-type rule with its
# condition, and FallbackResource.
my $tpl = do {
    open my $fh, '<', "$root/installers/hestia/lazysite-cgi.tpl" or die "template: $!";
    local $/;
    <$fh>;
};
my ($source_route) = $tpl =~ m{^(\s*RewriteCond \%\{REQUEST_URI\} !\^/\(\?:cgi-bin\|dav\|lazysite\)\(\?:/\|\$\)\n\s*RewriteRule \\\.\(\?:md\|[^\n]*\[NC,PT,L\])$}m;
my ($fallback)     = $tpl =~ m{^(\s*FallbackResource /cgi-bin/lazysite-auth\.pl)$}m;
ok( $source_route && $fallback, 'the template carries the source-type rule and FallbackResource' )
    or BAIL_OUT('cannot read the routes out of the template');

my $d = site_tempdir();
setup_test_site("$d/docroot");
make_path( "$d/cgi-bin/lib", "$d/logs", "$d/docroot/lazysite/logs" );

sub spit {
    my ( $p, $t, $mode ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return scalar <$fh>;
}

{
    open my $cf, '>>',"$d/docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "trusted_proxies: 127.0.0.1\nbad_url_threshold: 3\nbad_url_window: 3600\n";
    close $cf;
}
spit( "$d/docroot/about.md", "---\ntitle: About\n---\nABOUT-BODY\n" );

# The real engine, laid out as Hestia does: docroot and cgi-bin side by side. The
# wrapper's default processor is ../cgi-bin/lazysite-processor.pl from the docroot.
for my $f (qw(lazysite-auth.pl lazysite-processor.pl)) {
    spit( "$d/cgi-bin/$f", do { open my $fh, '<', "$root/$f" or die "$f: $!"; local $/; <$fh> }, 0755 );
}
system( 'cp', '-r', "$root/lib/Lazysite", "$d/cgi-bin/lib/" ) == 0 or die 'cannot stage lib';
system( 'cp', '-r', "$root/lazysite-processor", "$d/cgi-bin/" ) == 0 or die 'cannot stage the processor modules';

my $PORT = do {
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new( LocalAddr => '127.0.0.1', Proto => 'tcp' ) or die 'no port';
    my $p = $s->sockport;
    close $s;
    $p;
};

spit( "$d/httpd.conf", <<"CONF" );
ServerRoot "$d"
ServerName 127.0.0.1
Listen 127.0.0.1:$PORT
PidFile "$d/httpd.pid"
ErrorLog "$d/logs/error.log"
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule authz_host_module $MODS/mod_authz_host.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule dir_module $MODS/mod_dir.so
LoadModule cgi_module $MODS/mod_cgi.so
LoadModule rewrite_module $MODS/mod_rewrite.so
TypesConfig /etc/mime.types
DocumentRoot "$d/docroot"
ScriptAlias /cgi-bin/ "$d/cgi-bin/"
<Directory "$d/cgi-bin">
    Options +ExecCGI
    Require all granted
</Directory>
<Directory "$d/docroot">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
DirectoryIndex index.htm index.shtml
RewriteEngine On
$source_route
$fallback
CONF

sub apache {
    my ($verb) = @_;
    return system( $APACHE, '-f', "$d/httpd.conf", '-k', $verb ) == 0;
}

# The status line and body of one request as one visitor address.
sub hit {
    my ( $path, $ip ) = @_;
    my $out = qx{curl -s --max-time 15 --path-as-is -o - -w '\\nSTATUS=%{http_code}' -H 'X-Forwarded-For: $ip' http://127.0.0.1:$PORT$path 2>&1};
    my ($st) = $out =~ /STATUS=(\d+)\s*\z/;
    return { status => $st // 0, body => $out };
}

unless ( apache('start') ) {
    my $err = '';
    if ( open my $fh, '<', "$d/logs/error.log" ) { local $/; $err = <$fh>; close $fh }
    plan skip_all => "apache2 would not start here: $err";
}
END { apache('stop') if $APACHE && -f "$d/httpd.pid" }
for ( 1 .. 50 ) {
    last if hit( '/about', '198.51.100.250' )->{status};
    sleep 0.1;
}

{
    my $r = hit( '/about', '198.51.100.250' );
    is( $r->{status}, 200, 'control: a page is served through the wrapper and the processor' )
        or diag $r->{body}, slurp("$d/logs/error.log");
}

# One probe path for each route into the wrapper. /wp-login.php ends in a source
# type (.php), so the rewrite [PT] takes it; /.kube/config is no source type and
# reaches FallbackResource. Both are in the guard's built-in patterns, and neither
# is a file on the site.
for my $case ( [ 'the source-type rewrite [PT]', '/wp-login.php', '198.51.100.1' ],
    [ 'FallbackResource', '/.kube/config', '198.51.100.2' ] )
{
    my ( $route, $probe, $ip ) = @$case;
    subtest "$route: $probe is counted and the address is refused" => sub {
        my @st = map { hit( $probe, $ip )->{status} } 1 .. 3;
        isnt( $st[0], 403, 'the first probe is answered, not refused' );
        is( hit( $probe, $ip )->{status}, 403, 'after three, the address is refused' );
        is( hit( '/about', $ip )->{status}, 403, '...for a normal page too' );
        is( hit( '/about', '198.51.100.99' )->{status}, 200, 'a fresh address on a normal page is not refused' );
    };
}

done_testing();

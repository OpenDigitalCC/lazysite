#!/usr/bin/perl
# SM293 step 5: a front end with ONE rule, driven through real Apache.
#
# The whole claim of this step is that an operator can replace a vhost full of
# routing decisions with a single "forward everything to lazysite". A claim like
# that cannot be checked by reading the config: SM268 H15 was a rewrite block
# that read correctly and was dead, and SM283 was a proxy that answered before
# the engine was consulted. Both were found by driving a real server.
#
# So this runs real Apache with exactly one routing rule and asserts that each
# surface still gets the request it should. The surfaces are stubs that announce
# themselves, so "who answered" is unambiguous - the question here is the
# ROUTING, not what each surface then does with it.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(sleep);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $APACHE = -x '/usr/sbin/apache2' ? '/usr/sbin/apache2' : '';
plan skip_all => 'apache2 not installed' unless $APACHE;
my $MODS = '/usr/lib/apache2/modules';
plan skip_all => 'apache2 modules not found' unless -f "$MODS/mod_rewrite.so";

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/docroot/lazysite/auth", "$d/docroot/assets", "$d/cgi-bin",
    "$d/logs" );

sub spit {
    my ( $p, $t, $mode ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}

# Free port, the same way the other real-server tests find one.
my $PORT = do {
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new( LocalAddr => '127.0.0.1', Proto => 'tcp' )
        or die 'no port';
    my $p = $s->sockport;
    close $s;
    $p;
};

spit( "$d/docroot/lazysite/lazysite.conf", "site_name: F\n" );
spit( "$d/docroot/assets/logo.png",        "PNGBYTES\n" );
spit( "$d/docroot/lazysite/auth/.secret",  "SHOULD-NEVER-BE-SERVED\n" );

# The real front door, with stub surfaces behind it. Each stub names itself, so
# an assertion about routing cannot pass because two surfaces happen to produce
# similar output.
spit( "$d/cgi-bin/lazysite-front.pl", do {
        open my $fh, '<', "$root/lazysite-front.pl" or die $!;
        local $/;
        <$fh>;
}, 0755 );
make_path("$d/cgi-bin/lib");
system( 'cp', '-r', "$root/lib/Lazysite", "$d/cgi-bin/lib/" ) == 0
    or die 'cannot stage lib';

for my $s (qw(processor manager-api dav mcp oauth)) {
    spit( "$d/cgi-bin/lazysite-$s.pl", <<"CGI", 0755 );
#!/usr/bin/perl
print "Content-Type: text/plain\\r\\n\\r\\nSURFACE=$s WRAPPED=\$ENV{LAZYSITE_WRAPPED}\\n";
CGI
}

# The auth wrapper stub: announces that it ran, marks the environment, and
# execs whatever LAZYSITE_PROCESSOR names - the real contract, minus the cookie
# validation this test is not about.
spit( "$d/cgi-bin/lazysite-auth.pl", <<'CGI', 0755 );
#!/usr/bin/perl
$ENV{LAZYSITE_WRAPPED} = 1;
my $t = $ENV{LAZYSITE_PROCESSOR} or die "no LAZYSITE_PROCESSOR\n";
exec { $^X } $^X, $t or die "cannot exec $t: $!\n";
CGI

# ONE RULE. Everything that is not already the front door goes to the front
# door; lazysite decides the rest.
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
LoadModule env_module $MODS/mod_env.so
LoadModule rewrite_module $MODS/mod_rewrite.so
TypesConfig /etc/mime.types
DocumentRoot "$d/docroot"
ScriptAlias /lazysite-front "$d/cgi-bin/lazysite-front.pl"
SetEnv LAZYSITE_CGIBIN "$d/cgi-bin"
<Directory "$d/cgi-bin">
    Options +ExecCGI
    Require all granted
</Directory>
<Directory "$d/docroot">
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
FallbackResource /lazysite-front
RewriteEngine On
RewriteRule ^/(?!lazysite-front) /lazysite-front [PT,L]
CONF

sub apache { return system( $APACHE, '-f', "$d/httpd.conf", '-k', $_[0] ) == 0 }

# List-form exec, so no shell is involved. The first version built a qx string
# and interpolated a header array into it - the space in "Host: front.test"
# split into separate shell words, curl was handed nonsense, and EVERY route
# assertion failed at once. That reads exactly like a broken front door, and the
# front door was fine: driving the same vhost by hand answered correctly.
sub fetch {
    my ( $path, %o ) = @_;
    my @cmd = (
        'curl', '-s', '--max-time', '10', '--path-as-is',
        '-H',   'Host: front.test',
        ( $o{cookie} ? ( '-H', "Cookie: $o{cookie}" ) : () ),
        "http://127.0.0.1:$PORT$path",
    );
    my $pid = open my $ph, '-|';
    return '' unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>', '/dev/null' or exit 127;
        exec @cmd;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    return $out // '';
}

unless ( apache('start') ) {
    my $err = '';
    if ( open my $fh, '<', "$d/logs/error.log" ) { local $/; $err = <$fh>; close $fh }
    plan skip_all => "apache2 would not start here: $err";
}
END { apache('stop') if $APACHE && -f "$d/httpd.pid" }

for ( 1 .. 50 ) {
    last if fetch('/') =~ /\S/;
    sleep 0.1;
}

subtest 'one rule still reaches every surface' => sub {
    like( fetch('/'), qr/SURFACE=processor/, 'a page reaches the processor' );

    like( fetch('/dav/content/x.md'), qr/SURFACE=dav/,
        'and /dav reaches WebDAV, which the vhost used to ScriptAlias by hand' );
    unlike( fetch('/dav/content/x.md'), qr/WRAPPED=1/,
        'unwrapped - a wrapper round dav would strip the Authorization header '
            . 'its Basic auth depends on' );

    like( fetch('/cgi-bin/lazysite-mcp.pl'),   qr/SURFACE=mcp/,   'mcp' );
    like( fetch('/cgi-bin/lazysite-oauth.pl'), qr/SURFACE=oauth/, 'oauth' );

    like( fetch('/cgi-bin/lazysite-manager-api.pl'),
        qr/SURFACE=manager-api.*WRAPPED=1/s,
        'the manager API is reached AND wrapped - the rewrite the vhost used '
            . 'to do with an E= flag' );
};

subtest 'the engine tree is not reachable through the front door' => sub {
    my $out = fetch('/lazysite/auth/.secret');
    unlike( $out, qr/SHOULD-NEVER-BE-SERVED/,
        'the account store is not served - this is the file SM283 would have '
            . 'handed out as a backup tarball' );
    like( $out, qr/Not found/i, 'and it 404s rather than confirming it exists' );
};

subtest 'statics: served plainly, gated once the site protects anything' => sub {
    # SM223's condition, now decided inside lazysite instead of by two
    # RewriteConds. With no store the request still reaches the engine here,
    # because ONE RULE means the front end forwards everything - that is the
    # documented cost, and correctness is unaffected.
    like( fetch('/assets/logo.png'), qr/SURFACE=processor/,
        'the engine is asked for the asset' );

    spit( "$d/docroot/lazysite/auth/acls.json", "{}\n" );
    my $gated = fetch('/assets/logo.png');
    like( $gated, qr/SURFACE=processor/, 'and still is once a store exists' );
    like( $gated, qr/WRAPPED=1/,
        'now WRAPPED, so an identity is available to the ACL decision - '
            . 'without this a protected asset is served to anyone (SM283)' );
    unlink "$d/docroot/lazysite/auth/acls.json";
};

subtest 'a signed-in visitor is wrapped even on a miss' => sub {
    my $anon = fetch('/nothing-here');
    like( $anon, qr/SURFACE=processor/, 'an anonymous miss reaches the engine' );
    unlike( $anon, qr/WRAPPED=1/, 'unwrapped' );

    my $in = fetch( '/nothing-here', cookie => 'lazysite_auth=abc' );
    like( $in, qr/WRAPPED=1/,
        'a session cookie means wrapped, or the admin bar and the manager '
            . 'never work' );
};

done_testing();

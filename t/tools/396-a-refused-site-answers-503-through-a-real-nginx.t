#!/usr/bin/perl
# SM1361 (rulings 206, 208 Q-E): A REFUSED SITE ANSWERS 503, THROUGH A REAL NGINX.
#
# The container walk found a refused site answering 404. Its 503 server block
# named no log, so it inherited nginx's compiled-in /var/log/nginx/access.log,
# which the read-only root cannot open. nginx refused the reload, kept the old
# configuration, and the host fell to the default server - and nothing said so.
#
# The real entrypoint, with the recipe's own nginx.conf, run by the host's real
# nginx as this (unprivileged) user, on a loopback port: /var/log/nginx is no
# more writable to it than the container's read-only root is. The engine is a
# stub - only nginx is real here:
#   - a site newer than the image is refused, and its host answers 503;
#   - an unknown host answers 404, and the health location 204;
#   - a configuration nginx will not load is never silent: the log names it,
#     `lazysite-sites status` names it and exits 1, and once it is mended the
#     next reload clears it.
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use IO::Socket::INET ();
use POSIX      ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_root site_tempdir);
use PreRenameSite qw(slurp spit);

my $NGINX_BIN = '/usr/sbin/nginx';
plan skip_all => "no nginx at $NGINX_BIN" unless -x $NGINX_BIN;
plan skip_all => 'running as root, where the default log path may be writable' if $> == 0;

my $root = repo_root();
my $pkg  = "$root/installers/docker";
my $t    = site_tempdir() =~ s{/site/public_html\z}{}r;    # the base; everything below it
my $ngx  = "$t/ngx";
make_path("$ngx/sites");

# A free loopback port.
my $port = do {
    my $s = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' ) or die $!;
    my $p = $s->sockport;
    close $s;
    $p;
};

# The recipe's nginx.conf, its /tmp/nginx paths moved here.
( my $conf = slurp("$pkg/nginx.conf") ) =~ s{/tmp/nginx}{$ngx}g;
spit( "$t/nginx.conf", $conf );
spit( "$t/nginx", "#!/bin/bash\nexec '$NGINX_BIN' -c '$t/nginx.conf' -p '$ngx/' \"\$\@\"\n" );
spit( "$t/curl",  "#!/bin/bash\nprintf 200\n" );
chmod 0755, "$t/nginx", "$t/curl";

my $eng = "$t/engine";
make_path( "$eng/tools", "$eng/installers/nginx" );
copy( "$root/installers/nginx/vhost-one-rule-pool.conf.example", "$eng/installers/nginx/" ) or die $!;
spit( "$eng/VERSION",               "9.9.9\n" );
spit( "$eng/release-manifest.json", qq({"version":"9.9.9"}) );
spit( "$eng/install.pl",            "exit 0;\n" );
spit( "$eng/tools/lazysite-pool.pl", "\$SIG{TERM} = sub { exit 0 }; sleep 1 while 1;\n" );
spit( "$eng/tools/lazysited.pl",     "\$SIG{TERM} = sub { exit 0 }; sleep 1 while 1;\n" );

my $sites = "$t/sites";
make_path("$sites/alpha/html-lazysite");
spit( "$sites/alpha/html-lazysite/.install-state.json", qq({"version":"10.0.0"}) );    # newer than the image
spit( "$sites/sites.conf", "alpha alpha.example.test www.alpha.example.test\n" );

my $run  = "$t/run";
my %ENVS = (
    LAZYSITE_ENGINE => $eng, LAZYSITE_SITES => $sites, LAZYSITE_RUN_DIR => $run,
    LAZYSITE_NGINX_DIR => "$ngx/sites", LAZYSITE_PERL => $^X, LAZYSITE_NGINX => "$t/nginx",
    LAZYSITE_CURL => "$t/curl", LAZYSITE_PORT_INTERNAL => "127.0.0.1:$port", LAZYSITE_DAEMON_RETRY => 60,
);

my $ep = fork() // die;
if ( !$ep ) {
    delete $ENV{PERL5LIB};
    @ENV{ keys %ENVS } = values %ENVS;
    open STDOUT, '>', "$t/run.log";
    open STDERR, '>&', \*STDOUT;
    exec 'bash', "$pkg/entrypoint.sh", 'run';
    exit 127;
}
END {
    if ($ep) {
        kill 'TERM', $ep;
        for ( 1 .. 100 ) { last if waitpid( $ep, POSIX::WNOHANG() ) == $ep; select undef, undef, undef, 0.1 }
    }
    my $np = slurp("$ngx/nginx.pid");
    kill 'TERM', $np + 0 if defined $np && $np =~ /^\d+/;
}

# curl, which lets the Host header be set (HTTP::Tiny refuses it).
sub get {
    my ( $host, $path ) = @_;
    my $cmd = join ' ', map {quotemeta} 'curl', '-s', '-m', 5, '-o', '/dev/null', '-w', '%{http_code}',
        '-H', "Host: $host", "http://127.0.0.1:$port" . ( $path // '/' );
    my $code = `$cmd`;
    $main::LAST = $code;
    return ( $code // '' ) =~ /\A(\d{3})\z/ ? $1 + 0 : 0;
}
sub until_status {
    my ( $host, $want ) = @_;
    my $got = 0;
    for ( 1 .. 150 ) { $got = get($host); return $got if $got == $want; select undef, undef, undef, 0.1 }
    return $got;
}
sub sites_cmd {
    my (@args) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    local @ENV{ keys %ENVS } = values %ENVS;
    my $cmd = join ' ', map {quotemeta} 'bash', "$pkg/lazysite-sites", @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

is( until_status( 'alpha.example.test', 503 ), 503, 'a refused site answers 503 through a real nginx' )
    or diag( "last: $main::LAST\n" . ( slurp("$t/run.log") // '' ) . join( "\n", glob("$ngx/sites/*") ) );
is( get('www.alpha.example.test'),     503, 'and so does its alias' );
is( get('nobody.example.test'),        404, 'an unknown host answers 404' );
is( get( '127.0.0.1', '/lazysite-health' ), 204, 'the health location answers 204' );
ok( !-e "$run/nginx-config", 'nginx loaded every block: nothing is named' );

# ---- a configuration nginx will not load ---------------------------------------------
spit( "$ngx/sites/zz-broken.conf", "this is not nginx;\n" );
my ( $rc, $out ) = sites_cmd( 'restart', 'alpha' );
for ( 1 .. 100 ) { last if -e "$run/nginx-config"; select undef, undef, undef, 0.1 }
ok( -e "$run/nginx-config", 'a refused reload is recorded' );
like( slurp("$t/run.log") // '', qr/nginx refused the new configuration and still serves the last one it loaded: .*zz-broken\.conf/,
    'the log names it, in nginx\'s words' );
( $rc, $out ) = sites_cmd('status');
is( $rc, 1, 'status exits 1' );
like( $out, qr/^nginx: refused the last configuration, and serves the one before it: .*zz-broken\.conf/m, 'and names it first' );
is( get('alpha.example.test'), 503, 'the last good configuration still serves' );

unlink "$ngx/sites/zz-broken.conf";
sites_cmd( 'restart', 'alpha' );
for ( 1 .. 100 ) { last unless -e "$run/nginx-config"; select undef, undef, undef, 0.1 }
ok( !-e "$run/nginx-config", 'mended, the next reload clears it' );

done_testing();

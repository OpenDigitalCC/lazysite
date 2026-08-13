#!/usr/bin/perl
# Every shipped nginx config must actually parse.
#
# SM283 is the argument for this file. A defect in an nginx config was found on
# a live site by an agent probing from outside, on a repo whose entire coverage
# of front-end configs was text matching - and text matching had already
# reported all-green, because the rules it looked for were present, in the wrong
# file, for the wrong layer. A config that will not start takes a site down at
# the front door rather than degrading, and nothing in the suite could have said
# so before the operator did.
#
# nginx is not a build dependency, so this skips where it is absent. That is a
# real limit and it is the reason t/lint/33 still pins the same files by text:
# this check is the stronger one where it runs, not a replacement.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(repo_root);
use NginxHarness qw(nginx_bin render write_conf);

my $NGINX = nginx_bin();
plan skip_all => 'nginx not installed (apt install nginx-light to run this)'
    unless $NGINX;

my $root = repo_root();

# The four shipped nginx configs: two Hestia proxy templates (the SM283 layer)
# and the two standalone examples the lazysite-nginx package renders.
my @CONFIGS = (
    { rel => 'installers/hestia/lazysite-proxy.tpl',  hestia => 1 },
    { rel => 'installers/hestia/lazysite-proxy.stpl', hestia => 1, tls => 1 },
    { rel => 'installers/nginx/vhost-cgi.conf.example' },
    { rel => 'installers/nginx/vhost-fcgi.conf.example' },

    # SM293 step 5: the one-rule config. A shipped config that does not parse
    # is broken for whoever copies it, and this one is deliberately unlike the
    # others - no try_files, no extension list - so it is exactly the kind that
    # needs the real parser rather than a reading.
    { rel => 'installers/nginx/vhost-one-rule.conf.example' },
);

# One self-signed cert for the SSL template; nginx LOADS certificates during a
# config test, so a placeholder path is not enough.
my $certdir      = tempdir( CLEANUP => 1 );
my $have_openssl = `sh -c 'command -v openssl 2>/dev/null'` =~ /\S/ ? 1 : 0;
my $have_cert    = 0;
if ($have_openssl) {
    qx{openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout \Q$certdir/key.pem\E -out \Q$certdir/cert.pem\E -subj /CN=lazysite.test 2>/dev/null};
    $have_cert = ( -s "$certdir/cert.pem" && -s "$certdir/key.pem" ) ? 1 : 0;
    # If openssl is here, making a throwaway certificate must WORK. Letting this
    # fall through to a skip is how the SSL template silently stops being
    # tested while the file still reports all-green.
    ok( $have_cert, 'harness certificate generated' );
}

for my $c (@CONFIGS) {
    my $path = "$root/$c->{rel}";
    unless ( -f $path ) {
        fail("$c->{rel} is missing - a config was renamed without updating this test");
        next;
    }
SKIP: {
        skip "$c->{rel}: no openssl, cannot make a test certificate", 1
            if $c->{tls} && !$have_openssl;

        my $prefix = tempdir( CLEANUP => 1 );
        make_path( "$prefix/docroot/lazysite/auth", "$prefix/logs",
            "$prefix/home/siteuser/conf/web/lazysite.test" );

        my $conf = render(
            $path,
            '%ip%'               => '127.0.0.1',
            '%proxy_ssl_port%'   => 8443,
            '%proxy_port%'       => 8080,
            '%web_ssl_port%'     => 8444,
            '%web_port%'         => 8081,
            '%domain_idn%'       => 'lazysite.test',
            '%alias_idn%'        => 'www.lazysite.test',
            '%domain%'           => 'lazysite.test',
            '%sdocroot%'         => "$prefix/docroot",
            '%docroot%'          => "$prefix/docroot",
            '%home%'             => "$prefix/home",
            '%user%'             => 'siteuser',
            '%web_system%'       => 'apache2',
            '%proxy_extensions%' => 'jpg|jpeg|png|pdf|txt|gz|xml',
            '%ssl_pem%'          => "$certdir/cert.pem",
            '%ssl_key%'          => "$certdir/key.pem",
            '__DOMAIN__'         => 'lazysite.test',
            '__DOCROOT__'        => "$prefix/docroot",
            '__CGIBIN__'         => "$prefix/cgi-bin",
            '__PORT__'           => 8080,
            '%%LOGDIR%%'         => "$prefix/logs/",
        );
        write_conf( $prefix, $conf, hestia => $c->{hestia} );

        my $out = `\Q$NGINX\E -t -p \Q$prefix\E -c \Q$prefix/nginx.conf\E 2>&1`;
        my $rc  = $? >> 8;
        is( $rc, 0, "$c->{rel}: nginx accepts it" )
            or diag($out);
    }
}

done_testing();

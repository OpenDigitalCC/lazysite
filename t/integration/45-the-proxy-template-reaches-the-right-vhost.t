#!/usr/bin/perl
# The nginx->Apache hop in lazysite-proxy.stpl, driven for real.
#
# WHAT HAPPENED. The operator applied lazysite-proxy to edge on 2026-08-18,
# exactly as INSTALL-RUNBOOK.md documents. Every request to the domain returned
# 421 Misdirected Request - pages, MCP, WebDAV and the control API - on HTTP/2,
# on forced HTTP/1.1 and on a fresh --no-alpn connection. Rolled back, the site
# recovered completely.
#
# THE HOP IS TLS, ADDRESSED BY IP. nginx defaults proxy_ssl_server_name to OFF,
# so the handshake carried no SNI and Apache answered from its DEFAULT vhost.
#
# WHAT THE FIELD REPORT GOT RIGHT, AND THE ONE THING MEASURING CHANGED. The
# report named the missing Host header as part of the cause. Measured here,
# that is not what produces a 421 - it produces something quieter and worse:
#
#   Host absent (nginx sends the backend's IP)  -> 200, serving the WRONG SITE
#   Host present, SNI absent                    -> 421
#
# So on edge the Host header was already being set, by the front end's own
# global configuration, and SNI alone was missing. Both rows are failures and
# the fix closes both, but only one of them announces itself. A front end that
# sets no proxy defaults gets no error at all - just another site's pages.
#
# WHY IT SHIPPED, and what this fixture does about it: a host with ONE TLS
# vhost cannot show any of it, because the default vhost is also the right one.
# So this builds TWO, and asserts against the SECOND - which is the position
# every real site is in except one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use NginxHarness qw(nginx_bin free_port render write_conf start_nginx stop_nginx http_get);
use ApacheHarness qw(apache_bin apache_module_dir make_certs start_apache stop_apache);
use TestHelper    qw(repo_root);

my $nginx = nginx_bin();
plan skip_all => 'nginx not installed'      unless $nginx;
plan skip_all => 'apache2 not installed'    unless apache_bin();
plan skip_all => 'apache mod_ssl not found' unless apache_module_dir();
plan skip_all => 'openssl not installed'
    unless system('sh -c "command -v openssl >/dev/null 2>&1"') == 0;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';

my $root = repo_root();
my $tpl  = "$root/installers/hestia/lazysite-proxy.stpl";
plan skip_all => "no $tpl" unless -f $tpl;

my $prefix = tempdir( 'lazysite-sni-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $certs  = "$prefix/certs";

# DEFAULT-FIRST is the point: 'other.test' is declared first, so it is the
# vhost Apache falls back to when no SNI arrives. 'site.test' is the lazysite
# domain and must be reached deliberately.
my $DEFAULT = 'other.test';
my $SITE    = 'site.test';

make_path( "$prefix/docroot-other", "$prefix/docroot-site", "$prefix/sdocroot" );
for my $p (
    [ "$prefix/docroot-other/index.html", 'THE DEFAULT VHOST' ],
    [ "$prefix/docroot-site/index.html",  'THE LAZYSITE DOMAIN' ],
    )
{
    open my $fh, '>', $p->[0] or die $!;
    print {$fh} "$p->[1]\n";
    close $fh;
}

make_certs( $certs, $DEFAULT, $SITE );

my $apache_port = free_port();
my ( $arc, $aout ) = start_apache(
    $prefix, $apache_port, $certs,
    [ $DEFAULT, "$prefix/docroot-other" ],
    [ $SITE,    "$prefix/docroot-site" ],
);
if ( $arc != 0 ) {
    plan skip_all => "apache would not start: $aout";
}

END { stop_apache($prefix) if $prefix }

# The fixture is only meaningful if Apache really does discriminate. Proven
# here rather than assumed, because if it answered everything from one vhost
# every assertion below would pass while testing nothing.
subtest 'the backend really does distinguish its two vhosts' => sub {
    my ( $s1, $b1 ) = http_get( $apache_port, '/', tls => 1, host => $SITE, sni => $SITE );
    is( $s1, 200, "$SITE answers over its own SNI" );
    like( $b1, qr/THE LAZYSITE DOMAIN/, 'and serves its own docroot' );

    my ( $s2, $b2 )
        = http_get( $apache_port, '/', tls => 1, host => $DEFAULT, sni => $DEFAULT );
    like( $b2, qr/THE DEFAULT VHOST/, "$DEFAULT serves the other docroot" );
    is( $s2, 200, 'and answers 200' );
};

sub render_site_conf {
    return render(
        $tpl,
        '%ip%'               => '127.0.0.1',
        '%web_ssl_port%'     => $apache_port,
        '%proxy_ssl_port%'   => $_[0],
        '%domain_idn%'       => $SITE,
        '%alias_idn%'        => '',
        '%domain%'           => $SITE,
        '%ssl_pem%'          => "$certs/$SITE.crt",
        '%ssl_key%'          => "$certs/$SITE.key",
        '%sdocroot%'         => "$prefix/sdocroot",
        '%home%'             => $prefix,
        '%user%'             => 'u',
        '%web_system%'       => 'apache2',
        '%proxy_extensions%' => 'jpg|png|css|js|txt',
        '%%LOGDIR%%'         => "$prefix/nlogs/",
    );
}

# The two front ends a lazysite template actually meets. SM286: the template
# must state what it needs rather than inherit it, so it has to hold up in the
# left-hand column too.
for my $case (
    [ 'a front end that sets no proxy defaults' => undef ],
    [ 'a front end that sets Host globally'     => 'proxy_set_header Host $host;' ],
    )
{
    my ( $label, $extra ) = @$case;

    subtest "the lazysite domain is reached through the proxy: $label" => sub {
        my $np     = free_port();
        my $ngxdir = "$prefix/ngx-" . ( $extra ? 'host' : 'bare' );
        make_path( $ngxdir, "$prefix/nlogs" );

        write_conf( $ngxdir, render_site_conf($np),
            hestia => 1, extra_http => $extra );
        my ( $rc, $out ) = start_nginx( $nginx, $ngxdir );
        is( $rc, 0, 'nginx started' ) or do { diag $out; return };

        my ( $status, $body )
            = http_get( $np, '/', tls => 1, host => $SITE, sni => $SITE );
        stop_nginx( $nginx, $ngxdir );

        is( $status, 200, 'the request is answered, not misdirected' )
            or diag( '421 here is Apache refusing a request whose Host names '
                . 'a vhost the handshake did not select. That is what every '
                . 'surface on edge returned until the template was rolled '
                . 'back.' );
        like( $body, qr/THE LAZYSITE DOMAIN/,
            'and it is answered by the RIGHT vhost' )
            or diag( 'A 200 from the DEFAULT vhost is the quiet form of this '
                . 'defect: the site is up, and serving another site\'s pages. '
                . 'Asserting on the status alone would call that a pass.' );
    };
}

done_testing();

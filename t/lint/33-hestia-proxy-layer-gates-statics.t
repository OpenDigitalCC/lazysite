#!/usr/bin/perl
# SM283: on Hestia the request path is nginx -> Apache, and lazysite shipped a
# template for the second layer only. Hestia's stock proxy answers a fixed list
# of static EXTENSIONS straight off the docroot, so the ACL rules in the Apache
# template - which t/lint/31 proves are correct and present in all eight of
# them - were unreachable for images, PDFs, text and archives. Measured on a
# live site: identical bytes under five extensions in one ACL'd folder, four
# served anonymously.
#
# The lesson this file exists to pin is not "add a rule" but "cover the LAYER".
# A protection that lives in one of two layers is absent from the deployment,
# and every check we had asked only about the layer we had a file for.
#
# Three guards:
#
# 1. THE LAYER SHIPS. A Hestia proxy template exists for both the plain and SSL
#    server, or Hestia falls back to its own - which is the defect verbatim.
# 2. THE PROTECTIONS ARE AT THIS LAYER TOO. Everything the Apache template
#    denies (the engine directory, .brief sidecars, the registries) has to be
#    denied here as well, because a request the proxy answers never reaches
#    Apache to be denied. Deciding by extension cannot be made safe: any list is
#    a list of the types that happen to be protected.
# 3. THE OBSERVABLE MEANS SOMETHING. The filing's own second finding was that
#    an operator had no way to tell a fixed front end from a broken one - three
#    rebuilds produced byte-identical responses. The template answers with an
#    X-Lazysite-Front header; this test binds that header to the ACL branch, so
#    it is a statement about the file rather than a decoration on it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

# Comments are stripped before matching, so a template cannot pass by
# describing the problem while still exhibiting it.
sub code_of {
    my ($text) = @_;
    return join "\n", grep { !/^\s*#/ } split /\n/, $text;
}

# --- 1. the proxy layer ships at all ----------------------------------------

my %PROXY = (
    'installers/hestia/lazysite-proxy.tpl'  => 'plain',
    'installers/hestia/lazysite-proxy.stpl' => 'ssl',
);

for my $rel ( sort keys %PROXY ) {
    ok( -f "$root/$rel",
        "$rel ships - without it Hestia uses its own proxy template, which "
            . 'serves static extensions off the docroot with no ACL decision' );
}

# The Apache templates are the ORIGIN layer. Their presence is what made the
# gap invisible: every check passed because every check asked about them.
ok( -f "$root/installers/hestia/lazysite-cgi.tpl",
    'the origin (Apache) templates still ship alongside - both layers, not one' );

# --- 2. and 3. the proxy templates carry the protections --------------------

for my $rel ( sort keys %PROXY ) {
    my $path = "$root/$rel";
    next unless -f $path;
    my $text = slurp($path);
    my $code = code_of($text);

    subtest $rel => sub {

        # Braces balance, since a proxy template that will not parse takes the
        # site down at the front door rather than degrading.
        my $open  = () = $code =~ /\{/g;
        my $close = () = $code =~ /\}/g;
        is( $open, $close, "balanced braces ($open)" );

        # The ACL branch, in the form nginx actually supports: `if` cannot be
        # combined with try_files and rewrite cannot target a named location,
        # so error_page + return is the conditional jump.
        like( $code, qr{-f\s+\$document_root/lazysite/auth/acls\.json},
            'gates on the ACL store existing, so a site with no ACLs keeps '
                . 'direct static serving at full speed' );
        like( $code, qr{error_page\s+418\s*=\s*\@fallback},
            'and hands the request back to the origin when it does' );

        # The branch must be INSIDE the static-extension location. Placed at
        # server level it would never see the requests that leak.
        my ($static) = $code =~ m{(location\s+~\*\s+\^\.\+\\\.\(%proxy_extensions%\)\$\s*\{.*?\n\s{8}\})}s;
        ok( $static, 'the static-extension location is present' );
        like( $static, qr{acls\.json},
            'the ACL branch is inside it - at server level it would never see '
                . 'the requests that leak' ) if $static;

        # The engine directory - config, credentials, audit logs, and the
        # pre-install snapshot at lazysite/backups/*.tar.gz. What refuses it is
        # this being a longer prefix match than `location /`, inside which the
        # static-extension regex is nested; `^~` is defence against a future
        # top-level regex. t/integration/42 establishes which is which against
        # a running server - this file can only see that the line is here.
        like( $code, qr{location\s+\^~\s+/lazysite/\s*\{[^\}]*deny all},
            'denies the engine directory' );

        # SM073 and SM248, which live in the Apache template and are equally
        # unreachable when the proxy answers first.
        like( $code, qr{location\s+~\s+\\\.brief\$\s*\{[^\}]*deny all},
            'denies .brief sidecars' );
        for my $reg (qw(sitemap.xml llms.txt robots.txt feed.rss feed.atom)) {
            my $q = quotemeta $reg;
            like( $code, qr{location\s+=\s+/$q\s*\{[^\}]*proxy_pass},
                "routes /$reg to the origin (SM248: on a multi-domain instance "
                    . "the file exists and belongs to the PRIMARY site)" );
        }

        # The script surfaces are Apache's; a docroot file under either path
        # must not be served in their place.
        like( $code, qr{location\s+\^~\s+/cgi-bin/\s*\{[^\}]*proxy_pass},
            '/cgi-bin/ is proxied, never served' );
        like( $code, qr{location\s+\^~\s+/dav\b[^\{]*\{[^\}]*proxy_pass},
            '/dav is proxied, never served' );

        # WebDAV uploads whole files; nginx caps a request body at 1m by
        # default and the cap applies at the proxy, before Apache sees it.
        like( $code, qr{client_max_body_size\s+\S+},
            'raises the body cap so /dav uploads reach the origin' );

        # The observable, bound to the thing it claims.
        like( $code, qr{add_header\s+X-Lazysite-Front\s+"hestia-proxy/acl"\s+always},
            'answers with X-Lazysite-Front, so an operator can confirm which '
                . 'front end replied instead of trusting that a rebuild landed' );

        # WHO WE SAY WE ARE ON THE HOP TO THE ORIGIN. The backend picks a
        # vhost by name, and nginx's default Host for a proxied request is
        # $proxy_host - the backend's IP and port, which names no vhost at
        # all. t/integration/45 drives this against a real Apache with two TLS
        # vhosts; here we can only see that the line is present.
        like( $code, qr{proxy_set_header\s+Host\s+\$host\s*;},
            'sets Host from the request, so the origin can pick the vhost' )
            or diag( 'Without it the origin serves its DEFAULT vhost: the '
                . "site is up and serving another site's pages, with a 200." );

        # SSL pairing.
        if ( $PROXY{$rel} eq 'ssl' ) {
            like( $code, qr{^\s*ssl_certificate\s+}m, 'stpl configures TLS' );
            like( $code, qr{listen\s+\S+ssl_port%\s+ssl}, 'stpl listens on the SSL proxy port' );
            like( $code, qr{proxy_pass\s+https://}, 'stpl proxies to the SSL origin' );

            # The TLS hop needs the name TWICE - once in the handshake and once
            # in the request - and nginx defaults SNI on an upstream connection
            # to OFF. Applied to edge on 2026-08-18 without these, every
            # surface returned 421 until the template was rolled back.
            like( $code, qr{proxy_ssl_server_name\s+on\s*;},
                'sends SNI upstream (nginx defaults this OFF)' );
            like( $code, qr{proxy_ssl_name\s+%domain_idn%\s*;},
                'and names the DOMAIN in it, not the IP it dialled' );
        }
        else {
            unlike( $code, qr{^\s*ssl_certificate\s+}m, 'tpl configures no TLS' );
            like( $code, qr{proxy_pass\s+http://}, 'tpl proxies to the plain origin' );
        }
    };
}

# The header may not appear on a template that lacks the branch: that is the
# whole point of an observable. Checked across every shipped front-end config,
# not just the two above, so a future template cannot claim the guarantee.
{
    my @all = (
        glob("$root/installers/hestia/*.tpl"),
        glob("$root/installers/hestia/*.stpl"),
        glob("$root/installers/nginx/vhost-*.conf.example"),
        glob("$root/installers/apache/vhost-*.conf.example"),
    );
    for my $path (@all) {
        my $code = code_of( slurp($path) );
        next unless $code =~ /X-Lazysite-Front/;
        ( my $name = $path ) =~ s{.*/}{};
        like( $code, qr{acls\.json},
            "$name declares X-Lazysite-Front and carries the ACL branch - the "
                . 'header asserts the branch, so it may never appear without it' );
    }
}

done_testing();

package Lazysite::FrontDoor;

# SM293 step 5: lazysite decides which surface handles a request, so the front
# end's whole job becomes "forward everything".
#
# WHAT THIS REPLACES. Every shipped vhost template carries roughly a dozen
# routing decisions - which URLs reach the processor, which reach the manager
# API, which go through the auth wrapper, when an existing static file must be
# handed to the engine instead of served, what is denied outright. Those are
# lazysite's decisions, expressed in a language lazysite does not control, in a
# file it ships as a template, cannot test where it is installed, and on most
# deployments cannot see.
#
# That arrangement produced SM248 (a secondary domain served the primary's
# registries), SM268 H17 (a routing rule that silently resolved to the wrong
# path and 404'd every static file), and SM283 (a proxy answering by file
# extension before the engine was consulted - live across a fleet for weeks).
# Three incidents, one cause, and none of them a coding error: each was a
# correct engine and a front end that had not been told, or had been told and
# answered first.
#
# A PURE FUNCTION, deliberately. route() takes the request and the site's shape
# and returns a decision; it opens no sockets, execs nothing and prints nothing.
# That is what lets the whole routing table be tested directly - which the vhost
# templates never could be, because testing them means installing them on the
# web server the operator actually runs.
#
# THE ORDER BELOW IS THE VHOST'S ORDER, and it is load-bearing. The templates are
# the authority for what lazysite does today; t/lint/39 asserts that this module
# and the shipped templates agree, so the migration cannot quietly change
# behaviour while claiming to preserve it.

use strict;
use warnings;
use Lazysite::Paths ();
use Exporter 'import';

our @EXPORT_OK = qw(route);

# The generated registries no longer exist as files (SM293 step 3), so they fall
# through to the engine like any other miss. Kept named here because the shipped
# templates still carry an explicit rule for them, and t/lint/39 has to know that
# this module deliberately does NOT need one - the first vhost rule this work has
# earned the right to delete.
our @RETIRED_REGISTRY_ROUTES =
    qw(sitemap.xml llms.txt robots.txt feed.rss feed.atom);

# Is this a path the engine owns and nothing may fetch?
#
# On a site migrated by SM293 step 2 the engine tree is not under the docroot at
# all and this can never match - which is the point of that step. It still
# matters for every site that has not migrated, and costs one string compare.
sub _denied {
    my ($uri) = @_;
    return 1 if $uri =~ m{\A/lazysite(?:/|\z)};
    return 1 if $uri =~ /\.brief\z/;
    return 0;
}

# route( \%req ) -> \%decision
#
# %req: docroot, uri, method, cookie (the raw Cookie header, or '')
#
# %decision: surface  - what handles it
#            target   - the script or file, where the surface needs one
#            wrapped  - 1 when it must go through the auth wrapper first
#            why      - the rule that decided, for logging and for tests
sub route {
    my ($req)   = @_;
    my $docroot = $req->{docroot} // '';
    my $uri     = $req->{uri}     // '/';
    my $cookie  = $req->{cookie}  // '';
    $docroot =~ s{/+\z}{};

    # Strip the query string: every decision below is about the path.
    $uri =~ s/\?.*\z//s;

    return { surface => 'denied', why => 'engine-owned path' }
        if _denied($uri);

    # 1. The CGI surfaces, by name. The processor and the manager API are the
    #    two that carry a signed-in identity, so they go through the wrapper;
    #    dav, mcp and oauth authenticate themselves and must NOT (a wrapper
    #    round dav would strip the Authorization header it needs).
    if ( $uri =~ m{\A/cgi-bin/(lazysite-[a-z-]+\.pl)\z} ) {
        my $script = $1;
        my $wrap = ( $script =~ /\A lazysite-(?:processor|manager-api)\.pl \z/x ) ? 1 : 0;
        return { surface => 'cgi', target => $script, wrapped => $wrap,
            why => 'named cgi surface' };
    }

    # 2. WebDAV, at its own prefix. Its Basic auth is its own.
    return { surface => 'cgi', target => 'lazysite-dav.pl', wrapped => 0,
        why => 'dav prefix' }
        if $uri =~ m{\A/dav(?:/|\z)};

    my $lz       = Lazysite::Paths::lazysite_dir($docroot);
    my $has_acls = ( -f "$lz/auth/acls.json" ) ? 1 : 0;
    ( my $rel = $uri ) =~ s{\A/+}{};

    # 3. SM223: on a site that has an ACL store, an EXISTING static file goes to
    #    the engine rather than being served, because a file the web server
    #    hands over directly cannot be gated by anything the engine decides.
    #
    #    Conditional on the store existing, so a site that has never protected
    #    anything keeps serving its assets straight from disk. That condition is
    #    what made SM223 safe to ship to every existing site, and it is why this
    #    is not simply "always ask the engine".
    if ( $has_acls && length $rel && -f "$docroot/$rel" ) {
        return { surface => 'processor', wrapped => 1,
            why => 'existing static, acl store present' };
    }

    # 4. An extensionless URL backed by a legacy .html/.shtml (a migrated static
    #    site) is content too, and is gated the same way when a store exists.
    if ( $uri =~ m{\A/([^.]+)\z} ) {
        my $stem = $1;
        if ( !-f "$docroot/$stem.md" ) {
            my $legacy = ( -f "$docroot/$stem.html" ) ? "$stem.html"
                : ( -f "$docroot/$stem.shtml" ) ? "$stem.shtml"
                :                                 undef;
            if ( defined $legacy ) {
                return { surface => 'processor', wrapped => 1,
                    why => 'legacy static page, acl store present' }
                    if $has_acls;
                return { surface => 'static', target => $legacy,
                    why => 'legacy static page' };
            }
        }
    }

    # 5. The root, where index.md does not exist but a legacy index.html does.
    if ( $uri eq '/' && !-f "$docroot/index.md" && -f "$docroot/index.html" ) {
        return { surface => 'processor', wrapped => 1,
            why => 'legacy index, acl store present' }
            if $has_acls;
        return { surface => 'static', target => 'index.html',
            why => 'legacy index' };
    }

    # 6. A signed-in visitor gets the engine even for a miss, so the admin bar
    #    and the manager work. Checked before the plain fallback because the
    #    fallback does not wrap.
    if ( $cookie =~ /lazysite_auth=/ && !( length $rel && -f "$docroot/$rel" ) ) {
        return { surface => 'processor', wrapped => 1,
            why => 'session cookie present' };
    }

    # 7. An existing file on a site with NO acl store: serve it. This is the
    #    common case on most sites and the reason the engine is not in the path
    #    of every asset request.
    return { surface => 'static', target => $rel, why => 'existing static' }
        if length $rel && -f "$docroot/$rel";

    # 8. Everything else is a page. The generated registries land here too now
    #    that they are no longer files (SM293 step 3), which is why this module
    #    needs no rule for them.
    return { surface => 'processor', wrapped => 0, why => 'page miss' };
}

1;

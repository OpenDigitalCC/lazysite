package Lazysite::DomainRewrites;

# SM151 P6b: generate per-Host static-file rewrite rules for a multi-site
# instance. In production the web server should serve each alias domain's real
# static files (sitemap.xml, feeds, robots.txt, images, css, downloads) directly
# from that domain's content-root subtree, instead of routing them through the
# processor (which is correct - see _serve_content_static - but goes via CGI).
# Clean page URLs and the /lazysite, /cgi-bin, /manager surfaces are NOT
# rewritten: they still flow to the processor via FallbackResource / the app
# location. The rules are generated from lazysite.conf's alias_hosts +
# alias.<host>.content_root, so they stay in step with the site's configuration.
#
# NOTE: these are config-text generators. They are unit-tested on their output
# but must be validated against a live Apache/nginx before production use.

use strict;
use warnings;

# Paths that must never be rewritten to a content root - the management surface
# and the app entry points. Kept as a bare alternation for both back ends.
our @EXEMPT = qw(lazysite cgi-bin manager);

# SM248: docroot-ROOT files that identify the SITE rather than the instance, and
# so must never be inherited by a domain that has a content root of its own.
#
# The generic rule below already serves a domain's own copy when it has one. The
# gap is the domain that has NONE: the request falls through to the docroot, the
# web server serves the PRIMARY's file, and the browser tab shows a different
# organisation's emblem. That was the reported symptom on harmony2050.org, and
# it is a misrepresentation rather than a cosmetic fault - the visitor is being
# told whose site this is, incorrectly.
#
# Showing nothing is the better failure. A missing favicon is unremarkable and
# browsers handle it; the wrong organisation's is a claim.
#
# These stay OFF the CGI path deliberately. The registries were routed to the
# engine because crawlers fetch them rarely; an icon is fetched by every visitor,
# so it is answered by the web server either way - from the domain's own file, or
# not at all.
#
# A host with NO content root of its own is untouched by any of this: it shares
# the docroot and SHOULD inherit, which is the SM110 chrome-only alias case.
our @SITE_IDENTITY = qw(
    favicon.ico
    favicon.svg
    apple-touch-icon.png
    apple-touch-icon-precomposed.png
    site.webmanifest
);

# Parse a lazysite.conf and return an ordered list of { host, root } for every
# alias host that declares a content_root. Chrome-only aliases (no content_root)
# are skipped - they share the docroot and need no static rewrite.
sub read_domain_roots {
    my ($conf_path) = @_;
    open my $fh, '<', $conf_path or return [];
    my ( @hosts, %root );
    while ( my $line = <$fh> ) {
        if ( $line =~ /^alias\.(\S+)\.content_root\s*:\s*(.+?)\s*$/ ) {
            my ( $h, $r ) = ( lc $1, $2 );
            $r =~ s{^/+|/+$}{}g;    # docroot-relative, no leading/trailing slash
            $root{$h} = $r if length $r;
        }
        elsif ( $line =~ /^alias_hosts\s*:\s*(.+?)\s*$/ ) {
            for my $h ( split /,/, lc $1 ) {
                $h =~ s/^\s+|\s+$//g;
                push @hosts, $h if length $h;
            }
        }
    }
    close $fh;
    # Preserve alias_hosts order; only those with a content_root.
    return [ map { { host => $_, root => $root{$_} } }
        grep { defined $root{$_} } @hosts ];
}

# Apache: a mod_rewrite block, intended inside the <VirtualHost> that serves the
# alias hosts. A rule fires only when the Host matches, the path is not an app/
# management surface, and the target file actually exists (-f) - so clean page
# URLs fall through to FallbackResource untouched.
sub apache_snippet {
    my ($roots) = @_;
    my $exempt  = join '|', @EXEMPT;
    my @out     = (
        '# SM151 multi-site static rewrites - GENERATED from lazysite.conf.',
        '# Serve each alias domain\'s real static files from its content root;',
        '# app paths and clean page URLs fall through to the processor.',
        '# Place inside the <VirtualHost> serving these hosts. Needs mod_rewrite.',
        'RewriteEngine On',
    );
    if ( !@$roots ) {
        push @out, '# (no alias domains with a content_root are configured)';
        return join( "\n", @out ) . "\n";
    }
    my $identity = join '|', map { my $x = $_; $x =~ s/\./\\./g; $x } @SITE_IDENTITY;
    for my $d (@$roots) {
        my ( $h, $r ) = ( $d->{host}, $d->{root} );
        push @out,
            '',
            "# $h -> $r",
            # SM268 H15: SM223 routes a static file through the engine when the
            # site has an ACL store, and the ten shipped vhost templates do that
            # for the PRIMARY docroot. This generator emits the per-domain serve
            # rules, and did not - so on a multi-site instance, which is the shape
            # SM151 exists for, every alias domain's own assets were served
            # directly and no ACL could reach them. Proven against real Apache.
            #
            # Must precede the serve rule below: that rule ends in [L], so
            # anything after it would serve an ACL'd file before the ACL was
            # consulted. The exempt list already excludes /cgi-bin, so the
            # rewrite target cannot match itself.
            "# $h: route this domain's statics through the engine when ACLs exist",
            "RewriteCond %{HTTP_HOST} =$h [NC]",
            'RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f',
            "RewriteCond %{REQUEST_URI} !^/(?:$exempt)(?:/|\$)",
            "RewriteCond %{DOCUMENT_ROOT}/$r%{REQUEST_URI} -f",
            # PT, not a bare [L]: in vhost context mod_rewrite treats a
            # substitution beginning with / as a LOCAL PATH and prefixes
            # DocumentRoot before mod_alias ever sees it, so without PT the
            # target resolves to <docroot>/cgi-bin/lazysite-auth.pl. Where
            # cgi-bin is a sibling of the docroot - which is what the Hestia
            # templates produce - that file does not exist and every request
            # this rule catches 404s.
            'RewriteRule ^/(.*)$ /cgi-bin/lazysite-auth.pl [PT,L]',
            '',
            "# $h: serve this domain's own static files",
            "RewriteCond %{HTTP_HOST} =$h [NC]",
            "RewriteCond %{REQUEST_URI} !^/(?:$exempt)(?:/|\$)",
            "RewriteCond %{DOCUMENT_ROOT}/$r%{REQUEST_URI} -f",
            "RewriteRule ^/?(.*)\$ /$r/\$1 [L]",
            # SM248: this domain has no icon of its own, so the request would
            # otherwise fall through and be answered with the PRIMARY's - another
            # organisation's emblem in this domain's browser tab. Refuse instead.
            # Placed AFTER the serve rule, which ends in [L], so a domain that
            # does have its own file never reaches this.
            "# $h: never inherit the primary's site identity",
            "RewriteCond %{HTTP_HOST} =$h [NC]",
            "RewriteCond %{DOCUMENT_ROOT}/$r%{REQUEST_URI} !-f",
            "RewriteRule ^/(?:$identity)\$ - [R=404,L]";
    }
    return join( "\n", @out ) . "\n";
}

# nginx: a map from Host to content root, plus the try_files line to use in the
# content location. try_files tries the content-root-prefixed path first, then
# the plain path, then hands off to the app - so per-host statics win, clean
# URLs reach the processor.
sub nginx_snippet {
    my ($roots) = @_;
    my @out = (
        '# SM151 multi-site static rewrites - GENERATED from lazysite.conf.',
        '# Put the map in the http{} block; use $lz_content_root in try_files',
        '# in the server{} content location (see the commented example below).',
        'map $http_host $lz_content_root {',
        '    default "";',
    );
    for my $d (@$roots) {
        push @out, sprintf( '    %-24s %s;', $d->{host}, '/' . $d->{root} );
    }
    my $identity = join '|', map { my $x = $_; $x =~ s/\./\\./g; $x } @SITE_IDENTITY;
    push @out,
        '}',
        '',
        '# In the server{} block, serve per-host statics first, then the app:',
        '#   location / {',
        '#       error_page 418 = @lazysite;',
        '#       if (-f $document_root/lazysite/auth/acls.json) { return 418; }',
        '#       try_files $lz_content_root$uri $uri @lazysite;',
        '#   }',
        '#',
        '# SM268 H15: the two ACL lines are not optional. This example REPLACES',
        '# the shipped `location /`, so leaving them out deletes SM223 rather',
        '# than merely out-competing it: on a site with an ACL store every',
        '# per-domain static would be served directly, with no auth decision able',
        '# to reach it. A site with no ACLs never enters the branch and keeps',
        '# direct static serving at full speed.',
        '# The /lazysite, /cgi-bin and /manager locations must be declared',
        '# BEFORE this one so they are never prefixed with a content root.',
        '',
        '# SM248: the site identity must never be INHERITED. The location above',
        '# falls back to $uri, which on a multi-domain instance is the PRIMARY',
        '# site\'s file - so a domain with no favicon of its own shows another',
        '# organisation\'s emblem in the browser tab. This location drops that',
        '# fallback: the domain\'s own file, or 404.',
        '#',
        '# A host with NO content root has $lz_content_root empty, so it reads as',
        '# `try_files $uri =404` and still inherits - which is correct, that is',
        '# the chrome-only alias case.',
        "#   location ~ ^/(?:$identity)\$ {",
        '#       error_page 418 = @lazysite;',
        '#       if (-f $document_root/lazysite/auth/acls.json) { return 418; }',
        '#       try_files $lz_content_root$uri =404;',
        '#   }';
    return join( "\n", @out ) . "\n";
}

1;

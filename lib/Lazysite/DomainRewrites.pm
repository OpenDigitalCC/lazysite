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
    for my $d (@$roots) {
        my ( $h, $r ) = ( $d->{host}, $d->{root} );
        push @out,
            '',
            "# $h -> $r",
            "RewriteCond %{HTTP_HOST} =$h [NC]",
            "RewriteCond %{REQUEST_URI} !^/(?:$exempt)(?:/|\$)",
            "RewriteCond %{DOCUMENT_ROOT}/$r%{REQUEST_URI} -f",
            "RewriteRule ^/?(.*)\$ /$r/\$1 [L]";
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
    push @out,
        '}',
        '',
        '# In the server{} block, serve per-host statics first, then the app:',
        '#   location / {',
        '#       try_files $lz_content_root$uri $uri @lazysite;',
        '#   }',
        '# The /lazysite, /cgi-bin and /manager locations must be declared',
        '# BEFORE this one so they are never prefixed with a content root.';
    return join( "\n", @out ) . "\n";
}

1;

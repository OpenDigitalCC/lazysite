#!/usr/bin/perl
# SM151 P6b: per-Host static-file rewrite generation for multi-site instances.
# Lazysite::DomainRewrites parses lazysite.conf's aliases and emits Apache /
# nginx config that serves each alias domain's real static files from its
# content root (clean page URLs and the /lazysite, /cgi-bin, /manager surfaces
# are never rewritten). These are config-text generators - asserted on their
# output here; they still need validation against a live Apache/nginx before
# production use.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use TestHelper               qw(repo_root run_cmd);
use Lazysite::DomainRewrites ();

# --- Fixture: a docroot whose conf has two first-class aliases (own
#     content_root) and one chrome-only alias (no content_root). -------------
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf <<'CONF';
site_name: Agency
alias_hosts: cafe.example, firm.example, brand.example
alias.cafe.example.content_root: sites/clienta
alias.cafe.example.site_url: https://cafe.example
alias.firm.example.content_root: sites/clientb
alias.brand.example.site_name: Brand Only
CONF
close $cf;

# --- read_domain_roots: only aliases WITH a content_root ------------------
{
    my $roots = Lazysite::DomainRewrites::read_domain_roots("$d/lazysite/lazysite.conf");
    is_deeply(
        $roots,
        [ { host => 'cafe.example', root => 'sites/clienta' },
            { host => 'firm.example', root => 'sites/clientb' } ],
        'read_domain_roots: first-class aliases in alias_hosts order; chrome-only alias excluded'
    );
}

# --- apache_snippet -------------------------------------------------------
{
    my $roots = Lazysite::DomainRewrites::read_domain_roots("$d/lazysite/lazysite.conf");
    my $ap    = Lazysite::DomainRewrites::apache_snippet($roots);
    like( $ap, qr/RewriteEngine On/, 'apache: enables mod_rewrite' );
    like( $ap, qr/RewriteCond %\{HTTP_HOST\} =cafe\.example \[NC\]/, 'apache: matches the alias Host' );
    like( $ap, qr{!\^/\(\?:lazysite\|cgi-bin\|manager\)}, 'apache: exempts the app/management surfaces' );
    like( $ap, qr{RewriteCond %\{DOCUMENT_ROOT\}/sites/clienta%\{REQUEST_URI\} -f},
        'apache: only rewrites when the target file exists (-f), so clean URLs fall through' );
    like( $ap, qr{RewriteRule \^/\?\(\.\*\)\$ /sites/clienta/\$1 \[L\]},
        'apache: rewrites the request into the content root' );
    like( $ap, qr/firm\.example/, 'apache: emits a rule for every first-class alias' );
    unlike( $ap, qr/brand\.example/, 'apache: no rule for a chrome-only alias' );
}

# --- nginx_snippet --------------------------------------------------------
{
    my $roots = Lazysite::DomainRewrites::read_domain_roots("$d/lazysite/lazysite.conf");
    my $ng    = Lazysite::DomainRewrites::nginx_snippet($roots);
    like( $ng, qr/map \$http_host \$lz_content_root \{/, 'nginx: emits the host->root map' );
    like( $ng, qr/cafe\.example\s+\/sites\/clienta;/, 'nginx: maps the alias host to its content root' );
    like( $ng, qr/firm\.example\s+\/sites\/clientb;/, 'nginx: maps the second alias' );
    like( $ng, qr/try_files \$lz_content_root\$uri \$uri/, 'nginx: try_files serves per-host statics first' );
    unlike( $ng, qr/brand\.example/, 'nginx: no entry for a chrome-only alias' );
}

# --- empty case: no first-class aliases -----------------------------------
{
    my $ap = Lazysite::DomainRewrites::apache_snippet( [] );
    like( $ap, qr/no alias domains with a content_root/, 'apache: says so when there are none' );
    unlike( $ap, qr/RewriteRule/, 'apache: emits no rules when there are none' );
}

# --- the `rewrites` verb on each vhost tool -------------------------------
sub run_tool {
    my ( $tool, @args ) = @_;
    my $path = repo_root() . "/tools/$tool";
    # List form: @args interpolated into a shell string re-splits on any space.
    return run_cmd( $^X, $path, @args );
}
{
    my $ap = run_tool( 'lazysite-apache-vhost.pl', 'rewrites', '--docroot', $d );
    like( $ap, qr/RewriteCond %\{HTTP_HOST\} =cafe\.example/,
        'apache tool: rewrites verb emits the block from the docroot conf' );

    my $ng = run_tool( 'lazysite-nginx-vhost.pl', 'rewrites', '--docroot', $d );
    like( $ng, qr/map \$http_host \$lz_content_root/,
        'nginx tool: rewrites verb emits the map from the docroot conf' );
}

# --- SM248: a domain never inherits the primary's site identity -------------
# The generic rule above already serves a domain's OWN favicon when it has one.
# The reported defect was the domain that has none: the request falls through to
# the docroot and the web server answers with the PRIMARY's file, so the browser
# tab shows a different organisation's emblem. That is a misrepresentation, not a
# cosmetic fault - the visitor is being told whose site this is, incorrectly.
#
# These stay OFF the CGI path on purpose. The registries were routed to the
# engine because crawlers fetch them rarely; an icon is fetched by every visitor.
{
    my $roots = Lazysite::DomainRewrites::read_domain_roots("$d/lazysite/lazysite.conf");
    my $ap    = Lazysite::DomainRewrites::apache_snippet($roots);

    like( $ap, qr/never inherit the primary's site identity/,
        'apache: the identity rule is emitted and says why' );
    like( $ap, qr{RewriteCond %\{DOCUMENT_ROOT\}/sites/clienta%\{REQUEST_URI\} !-f},
        'apache: it fires only when the domain has NO file of its own' );
    like( $ap, qr{RewriteRule \^/\(\?:favicon\\\.ico\|},
        'apache: and refuses the identity paths' );
    like( $ap, qr/\[R=404,L\]/,
        'apache: with a 404 - showing nothing beats showing the wrong emblem' );

    # Ordering is the whole thing: the serve rule ends in [L], so a domain that
    # HAS its own icon must reach it before the refusal.
    my $serve  = index( $ap, 'RewriteRule ^/?(.*)$ /sites/clienta/$1 [L]' );
    my $refuse = index( $ap, 'never inherit' );
    cmp_ok( $serve, '>=', 0, 'apache: the serve rule is present' );
    cmp_ok( $serve, '<', $refuse,
        'apache: serve comes BEFORE refuse, so a domain with its own icon gets it' );

    # A chrome-only alias shares the docroot and SHOULD inherit - that is the
    # SM110 case and breaking it would trade one defect for another.
    unlike( $ap, qr/brand\.example.*never inherit/s,
        'apache: a chrome-only alias gets no refusal rule' );

    my $ng = Lazysite::DomainRewrites::nginx_snippet($roots);
    like( $ng, qr/the site identity must never be INHERITED/,
        'nginx: the guidance is emitted' );
    like( $ng, qr/try_files \$lz_content_root\$uri =404;/,
        'nginx: the identity location drops the bare $uri fallback' );
    # And the same one line covers the chrome-only case, because an unmapped host
    # gets an empty $lz_content_root - so it reads as `try_files $uri =404`.
    like( $ng, qr/chrome-only alias case/,
        'nginx: and says why that still lets a chrome-only alias inherit' );
}

done_testing();

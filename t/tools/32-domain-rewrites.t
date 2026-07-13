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
use TestHelper               qw(repo_root);
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
    return scalar qx($^X \Q$path\E @args 2>&1);
}
{
    my $ap = run_tool( 'lazysite-apache-vhost.pl', 'rewrites', '--docroot', $d );
    like( $ap, qr/RewriteCond %\{HTTP_HOST\} =cafe\.example/,
        'apache tool: rewrites verb emits the block from the docroot conf' );

    my $ng = run_tool( 'lazysite-nginx-vhost.pl', 'rewrites', '--docroot', $d );
    like( $ng, qr/map \$http_host \$lz_content_root/,
        'nginx tool: rewrites verb emits the map from the docroot conf' );
}

done_testing();

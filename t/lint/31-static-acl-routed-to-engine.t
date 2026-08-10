#!/usr/bin/perl
# SM223: every shipped front-end config routes an EXISTING static file to the
# engine when the site has an ACL store - and the processor's local ACL reader
# agrees with the shared one it copies.
#
# Two guards, one filing, because SM223 has two ways to fail silently.
#
# 1. THE ROUTING. Ten near-identical front-end configs ship, and a rule that
#    lands in nine of them is the defect, not the fix. This is the third time
#    this exact structural cause has produced a leak: the .brief sidecar served
#    raw, the per-domain registries answered by the primary's files, and now a
#    private static served to anyone who knows its path. In every case a routing
#    rule was conditioned on the request mapping to NO file, which is correct for
#    pages and wrong for a file that exists. t/lint/28 pins the registry remedy;
#    this pins SM223's.
#
# 2. THE SEMANTICS. The processor cannot load Lazysite::Auth::Acl (ADR 0001), so
#    it carries a local copy of the read decision. A copy that drifts is how
#    "protected" comes to mean two different things depending on which surface
#    you ask - and the public path is the one where being wrong is an exposure
#    rather than an inconvenience.
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

# Comments are stripped before matching, so a template cannot pass by describing
# the problem while still exhibiting it.
sub code_of {
    my ($text) = @_;
    return join "\n", grep { !/^\s*#/ } split /\n/, $text;
}

# --- 1. every front-end config routes on the ACL store ----------------------

my @APACHE = qw(
    installers/apache/vhost-cgi.conf.example
    installers/apache/vhost-fcgi.conf.example
    installers/hestia/lazysite-app.tpl
    installers/hestia/lazysite-app.stpl
    installers/hestia/lazysite-cgi.tpl
    installers/hestia/lazysite-cgi.stpl
    installers/hestia/lazysite-fcgi.tpl
    installers/hestia/lazysite-fcgi.stpl
);

my @NGINX = qw(
    installers/nginx/vhost-cgi.conf.example
    installers/nginx/vhost-fcgi.conf.example
);

for my $rel (@APACHE) {
    my $path = "$root/$rel";
    unless ( -f $path ) {
        fail("$rel is missing - a template was renamed without updating this test");
        next;
    }
    my $code = code_of( slurp($path) );

    like( $code, qr{RewriteCond\s+%\{DOCUMENT_ROOT\}/lazysite/auth/acls\.json\s+-f},
        "$rel gates the routing on the ACL store existing" );
    like( $code, qr{RewriteRule\s+\^/\(\.\*\)\$\s+/cgi-bin/lazysite-auth\.pl},
        "$rel routes an existing file to the AUTH WRAPPER, not the processor" );

    # SM268: every ACL routing rule must carry PT. In vhost context mod_rewrite
    # treats a substitution beginning with / as a LOCAL PATH and prefixes
    # DocumentRoot before mod_alias sees it, so without PT the target resolves
    # to <docroot>/cgi-bin/lazysite-auth.pl. Where cgi-bin is a SIBLING of the
    # docroot - which is exactly what the Hestia templates produce - that file
    # does not exist and every static request on an ACL'd site 404s. Verified
    # against Apache 2.4.67; t/integration/40 drives the real server.
    for my $rule ( $code =~ m{^\s*(RewriteRule\s+\S+\s+/cgi-bin/lazysite-auth\.pl[^\n]*)$}mg ) {
        like( $rule, qr{\[(?:[^\]]*,)?PT(?:,[^\]]*)?\]},
            "$rel: '$rule' carries PT, so ScriptAlias still maps /cgi-bin/" );
    }

    # Ordering is the whole game. Every rule in these files terminates with [L],
    # so an ACL rule placed after the SM133 static fallbacks would never be
    # reached for the .html files that fallback serves.
    my $acl_at   = index( $code, 'lazysite/auth/acls.json' );
    my $sm133_at = index( $code, '.shtml -f' );
    cmp_ok( $acl_at, '>=', 0, "$rel has the ACL rule" );
    if ( $sm133_at >= 0 ) {
        cmp_ok( $acl_at, '<', $sm133_at,
            "$rel puts the ACL routing BEFORE the static fallbacks - every rule "
                . "below ends in [L], so anything after them serves first" );
    }
}

for my $rel (@NGINX) {
    my $path = "$root/$rel";
    unless ( -f $path ) {
        fail("$rel is missing - a template was renamed without updating this test");
        next;
    }
    my $code = code_of( slurp($path) );

    like( $code, qr{-f\s+\$document_root/lazysite/auth/acls\.json},
        "$rel gates on the ACL store existing" );
    like( $code, qr{error_page\s+418\s*=\s*\@lazysite},
        "$rel jumps to the engine when it does - if cannot be combined with "
            . "try_files, so this is the supported conditional named-location form" );
}

# --- 1b. the GENERATED per-domain rules too (SM268 H15) ---------------------
#
# The ten templates above cover the primary docroot. On a multi-site instance
# the per-domain static rules come from Lazysite::DomainRewrites, and they were
# not updated for SM223 - so every alias domain's own assets were served
# directly by the web server, with no auth decision able to reach them. That is
# the shape SM151 exists for, which makes the generator the more important half.
# The filing's own diagnosis - "the third leak from the same structural cause" -
# applies to the generator as much as to the files it pins.
{
    require Lazysite::DomainRewrites;
    my $roots = [ { host => 'alias.test', root => 'sites/foo' } ];

    my $apache = code_of( Lazysite::DomainRewrites::apache_snippet($roots) );
    like( $apache, qr{RewriteCond\s+%\{DOCUMENT_ROOT\}/lazysite/auth/acls\.json\s+-f},
        'the generated Apache block gates on the ACL store' );
    like( $apache, qr{RewriteRule\s+\S+\s+/cgi-bin/lazysite-auth\.pl\s+\[PT,L\]},
        'and routes to the auth wrapper, not straight to the file' );

    # Order is the whole defect: the serve rule ends in [L], so an ACL rule
    # placed after it never runs.
    my $acl_at   = index( $apache, '/cgi-bin/lazysite-auth.pl' );
    my $serve_at = index( $apache, 'RewriteRule ^/?(.*)$ /sites/foo/$1 [L]' );
    cmp_ok( $acl_at,   '>=', 0, 'the ACL rule is present' );
    cmp_ok( $serve_at, '>=', 0, 'the serve rule is present' );
    cmp_ok( $acl_at, '<', $serve_at,
        'and the ACL rule comes FIRST - after the [L] serve rule it would be dead' );

    my $nginx = Lazysite::DomainRewrites::nginx_snippet($roots);
    like( $nginx, qr{-f\s+\$document_root/lazysite/auth/acls\.json},
        'the generated nginx guidance keeps the ACL test' );
    like( $nginx, qr{error_page\s+418\s*=\s*\@lazysite},
        'and the 418 branch - the operator is told to REPLACE location /, so '
            . 'omitting these deletes SM223 rather than out-competing it' );
}

# --- 2. the processor's local copy matches the shared decision --------------

{
    my $proc = slurp("$root/lazysite-processor.pl");
    my $acl  = slurp("$root/lib/Lazysite/Auth/Acl.pm");

    like( $proc, qr/sub _acl_allows_read/,
        'the processor carries a local read-decision copy (ADR 0001)' );

    # The four rules that make up the decision, each of which is a silent
    # exposure if the copy loses it.
    my ($local) = $proc =~ /(sub _acl_allows_read\b.*?\n\})/s;
    ok( defined $local, 'the local copy was found' );

    like( $local, qr/return 1 unless.*\$map/s,
        'no ACL store, or an empty one, means ALLOWED - auth_default does not '
            . 'reach static files and an unmentioned file is served as before' );
    like( $local, qr/\$a->\{owner\}/,
        'the owner is allowed, as in the shared implementation' );
    like( $local, qr/return 1 unless ref \$list eq 'ARRAY' && \@\$list/,
        'an entry with no read list does not restrict - matching Auth::Acl, '
            . 'where an owner-only entry is not a read restriction either' );
    like( $local, qr/\A\\\@|\\A\\\@\(\.\+\)/,
        'a @group entry is honoured' );

    # The trap that would make the whole feature inert. _acl_denied routes
    # through _is_operator, which returns 1 on a site where no group grants
    # manager access - so on an ANONYMOUS request it would treat the public as
    # an operator and skip the ACL entirely, on exactly the sites least equipped
    # to notice.
    # Comments stripped: the processor DESCRIBES this trap at length, and the
    # description must not be what satisfies the check.
    unlike( code_of($proc), qr/_acl_denied/,
        'the public path never uses _acl_denied - it bypasses via _is_operator '
            . 'on an unsecured site' );

    # And the shared implementation still has the shape the copy was made from.
    like( $acl, qr/return 1 unless \$a;/,
        'Auth::Acl still treats "no entry" as allowed' );
    like( $acl, qr/return 1 unless ref \$list eq 'ARRAY' && \@\$list;/,
        'Auth::Acl still treats "no list for this mode" as allowed' );
}

done_testing();

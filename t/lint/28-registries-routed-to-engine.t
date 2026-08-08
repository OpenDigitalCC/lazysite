#!/usr/bin/perl
# SM248: every shipped vhost template routes the per-domain registries to the
# engine unconditionally.
#
# The defect is structural and easy to reintroduce, because every routing rule in
# these files is naturally conditioned on the request mapping to NO file -
# FallbackResource by definition, nginx's try_files by construction, and the
# fcgi template's RewriteConds explicitly. That is correct for pages and wrong
# for exactly these five paths: on a multi-domain instance $DOCROOT/sitemap.xml
# EXISTS, because it is the primary site's, so a secondary domain's request
# matches a real file and the web server answers with the wrong site's sitemap,
# llms.txt or feeds. The engine's per-Host handler (SM151 P6) is correct and
# never runs, because the request never reaches it.
#
# The same structural cause produced the .brief leak (an existing sidecar served
# raw) and SM223's auth bypass. It will produce the next one too, so this pins
# the remedy in every template at once rather than in whichever was edited last.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Fetched by crawlers, not visitors, so routing them through the engine costs
# nothing anyone notices. Hot assets are deliberately absent: favicon.ico and
# friends stay static and are handled by the `rewrites` verb, which keeps them
# on the fast path.
my @REGISTRIES = qw(sitemap.xml llms.txt robots.txt feed.rss feed.atom);

my @TEMPLATES = qw(
    installers/apache/vhost-cgi.conf.example
    installers/apache/vhost-fcgi.conf.example
    installers/nginx/vhost-cgi.conf.example
    installers/nginx/vhost-fcgi.conf.example
);

for my $rel (@TEMPLATES) {
    my $path = "$root/$rel";
    unless ( -f $path ) {
        fail("$rel is missing - a template was renamed without updating this test");
        next;
    }
    open my $fh, '<', $path or die "$rel: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    for my $r (@REGISTRIES) {
        # The path must appear in a ROUTING position, not merely in a comment.
        # Comments are stripped first so a template cannot pass by mentioning
        # the problem while still exhibiting it.
        my $code = join "\n", grep { !/^\s*#/ } split /\n/, $text;
        my $q = quotemeta $r;
        # nginx writes `location = /sitemap.xml`; apache writes ScriptAlias or a
        # RewriteRule alternation with the dot escaped.
        ( my $esc = $r ) =~ s/\./\\\\?\./;
        like( $code, qr/\Q$r\E|$esc/,
            "$rel routes /$r to the engine" )
            or diag(
            "  /$r is served by the web server for whichever Host asks, so a\n"
                . "  secondary domain gets the PRIMARY site's copy." );
    }
}

# And the reason is written down where the next editor will see it, in each
# family - a rule with no explanation gets removed as clutter.
for my $rel (@TEMPLATES) {
    my $path = "$root/$rel";
    next unless -f $path;
    open my $fh, '<', $path or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr/SM248/, "$rel explains WHY those paths are routed" );
}

done_testing();

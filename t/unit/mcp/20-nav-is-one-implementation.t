#!/usr/bin/perl
# SM318: one navigation implementation, reachable per domain from both surfaces.
#
# THE REPORTED DEFECT. `nav-read` and `nav-save` take a `host` on the control
# API; `read_nav` and `set_nav` refused one. `set_nav` declares
# additionalProperties: false, so the refusal was explicit and correct (SM278) -
# and that is the whole problem: an agent holding manage_nav on a multi-domain
# instance is told plainly that the thing it needs cannot be expressed.
# `read_nav` took no parameters at all, so an MCP-only account could not even
# READ the nav of the domain it had been asked to work on.
#
# WHAT READING IT FOUND, which the report could not see from outside: MCP had its
# OWN implementation, and it was the poorer of the two.
#
#                              control API          MCP (before)
#   per-domain nav_file        yes, via `host`      hard-coded lazysite/nav.conf
#   reports `inherited`        yes                  no
#   content history (SM085)    explicit commit      via the generic file save
#   cache invalidation (SM168) yes, with a count    NONE
#
# The last row is worse than the reported one and nobody had noticed. The nav is
# baked into every page's rendered HTML, so a nav change is invisible on the live
# site until each page re-renders. SM168 taught the control API to bust the cache
# and report how many pages it refreshed, precisely so the UI could say the
# change was PUBLISHED rather than merely saved. An MCP nav edit returned ok:1
# and the site carried on serving the old menu - the file really had been
# written, so nothing looked wrong from outside.
#
# SO THIS IS NOT "ADD A HOST PARAMETER". Two implementations of one operation
# drift, and the drift is silent by construction because each surface is
# individually consistent. SM301 established the answer when the gap ran the
# other way: one implementation serves both channels, so they cannot answer
# differently.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $mcp = slurp("$root/lazysite-mcp.pl");
my $api = slurp("$root/lazysite-manager-api.pl");

subtest 'there is exactly ONE implementation, in a module' => sub {
    ok( -f "$root/lib/Lazysite/Manager/Nav.pm",
        'the nav implementation is a module both surfaces can use' );

    my $nav = slurp("$root/lib/Lazysite/Manager/Nav.pm");
    like( $nav, qr/sub action_nav_read/,  'it holds the reader' );
    like( $nav, qr/sub action_nav_save/,  'and the writer' );
    like( $nav, qr/sub _nav_conf_info/,
        'and the per-domain nav_file resolution they share' );

    # Neither surface may keep a private copy. This is the assertion that stops
    # the drift returning: a second implementation is always individually
    # correct, which is why nobody notices it diverge.
    unlike( $mcp, qr/\nsub _read_nav\b/,
        'MCP has no private reader' );
    unlike( $mcp, qr/\nsub _set_nav\b/,
        'MCP has no private writer' );
    unlike( $api, qr/\nsub action_nav_read\b/,
        'the control API does not define its own either - it imports' );

    like( $mcp, qr/use Lazysite::Manager::Nav/, 'MCP imports the module' );
    like( $api, qr/use Lazysite::Manager::Nav/, 'the control API imports it' );
};

subtest 'both MCP tools accept a host' => sub {
    my ($read) = $mcp =~ /read_nav\s*=>\s*\{(.*?)\n    \},/s;
    ok( $read, 'read_nav is declared' ) or return;
    like( $read, qr/host\s*=>\s*\{/, 'read_nav accepts host' );
    like( $read, qr/action_nav_read\(\s*\$_\[0\]->\{host\}/,
        'and passes it through' );

    my ($set) = $mcp =~ /set_nav\s*=>\s*\{(.*?)\n    \},/s;
    ok( $set, 'set_nav is declared' ) or return;
    like( $set, qr/host\s*=>\s*\{/, 'set_nav accepts host' );
    like( $set, qr/action_nav_save\(\s*\$_\[0\]->\{items\},\s*\$_\[0\]->\{host\}/,
        'and passes both items and host' );

    # additionalProperties stays false. The refusal was never the defect - SM278
    # is right that an unknown argument should be refused rather than ignored.
    # What was wrong is that `host` was unknown.
    like( $set, qr/additionalProperties\s*=>\s*JSON::PP::false/,
        'unknown arguments are still refused (SM278 is unchanged)' );
};

subtest 'omitting host is a stated choice, not a silent default' => sub {
    # activate_layout set the precedent and the wording: "WITHOUT `host` this is
    # INSTANCE-WIDE". The ambiguity being resolved is identical, so the
    # description resolves it the same way rather than inventing a second
    # convention for the same question.
    my ($read) = $mcp =~ /read_nav\s*=>\s*\{(.*?)\n    \},/s;
    my ($set)  = $mcp =~ /set_nav\s*=>\s*\{(.*?)\n    \},/s;

    like( $read, qr/WITHOUT `host`/, 'read_nav says what omitting it means' );
    like( $set,  qr/WITHOUT `host`/, 'set_nav says what omitting it means' );
    like( $set,  qr/list_domains/,
        'and points at the tool that shows whether it matters' );
};

subtest 'the MCP path now gets what only the control API had' => sub {
    # The unreported half. Asserted on the shared implementation, because that is
    # now the only place either surface can get it from.
    my $nav = slurp("$root/lib/Lazysite/Manager/Nav.pm");

    like( $nav, qr/action_cache_invalidate/,
        'a nav save busts the render cache (SM168)' )
        or diag( 'Without this an MCP nav edit returns ok:1 and the site serves '
            . 'the old menu until every page happens to re-render.' );
    like( $nav, qr/cache_cleared/,
        'and reports how many pages were refreshed, so the caller can tell '
            . 'PUBLISHED from merely saved' );
    like( $nav, qr/Lazysite::Git::commit_paths/,
        'and records the change in content history (SM085)' );
    like( $nav, qr/inherited/,
        'the reader says whether the nav_file is inherited from the primary' );

    # SM268: the reader returns the docroot-RELATIVE path only. A regression here
    # leaks the filesystem layout and the system username to token clients, and
    # this module is now on a surface where that matters more, not less.
    like( $nav, qr/never the server-absolute one/,
        'and the no-absolute-paths reasoning travelled with the code' );
};

done_testing();

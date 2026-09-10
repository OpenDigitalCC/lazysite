#!/usr/bin/perl
# SM817: `extension-*` is the name, `plugin-*` is the old one, and both work.
#
# The fourteen are not plugged in by anybody: they ship in the package, the engine
# declares their capabilities, and the operator's act is switching one off rather
# than installing one. What IS true is that the core renderer requires nothing
# from them, so they extend it - which is what the new name says.
#
# NORMALISED IN ONE PLACE rather than declared twice. The whole risk of an alias
# is two declarations drifting apart, and this codebase has a filing for every
# time that was tried - SM666, SEC-2026-07 F3, SM662. Below the normaliser only
# one spelling exists, so they cannot drift. This asserts that shape rather than
# asserting a list of pairs, because a list of pairs is the thing that rots.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $api  = "$root/lazysite-manager-api.pl";
plan skip_all => "no $api" unless -f $api;

open my $fh, '<:utf8', $api or die $!;
my $src = do { local $/; <$fh> };
close $fh;

# --- the normaliser exists and runs where the action is read -----------------
like( $src, qr/\$action \s*=~ \s*s.\\Aextension-/x,
    'the action name is normalised from extension- to the internal spelling' )
    or diag 'without this, extension-* never reaches the gate or the dispatch';

# It has to be BEFORE the capability gate, or a new-spelling call is refused as
# an unknown action before anything looks at it.
my $norm_at = $src =~ /extension-/ ? $-[0] : -1;
my $gate_at = $src =~ /my \$check = \$need\{\$action\}/ ? $-[0] : -1;
cmp_ok( $norm_at, '>', 0, 'found the normaliser' );
cmp_ok( $gate_at, '>', 0, 'found the capability gate' );
cmp_ok( $norm_at, '<', $gate_at,
    'the normaliser runs BEFORE the gate, so the new spelling is not refused as unknown' );

# --- the old spelling is deprecated in words, not just in intent -------------
like( $src, qr/deprecated spelling/,
    'using the old name says so, naming the new one' );

# INFO, not WARN, and the reason is in the source: a warning on every call
# trains an operator to ignore the log before the removal it warns about
# arrives. Asserted because "make it louder" is the obvious later edit.
my ($dep_block) = $src =~ /(log_event\(\s*'[A-Z]+',[^;]*deprecated spelling[^;]*;)/s;
ok( $dep_block, 'found the deprecation log' );
like( $dep_block, qr/log_event\(\s*'INFO'/,
    'it is INFO - the old name still works, and a WARN per call would be noise' );

# --- our own pages use the new name ------------------------------------------
# Shipped pages calling the deprecated spelling would make the log fire on every
# manager page load, which is exactly how a deprecation notice becomes furniture.
my $dir = "$root/starter/manager";
opendir my $dh, $dir or plan skip_all => 'no manager pages';
my @pages = grep {/\.md$/} readdir $dh;
closedir $dh;

my @old;
for my $p (@pages) {
    open my $ph, '<:utf8', "$dir/$p" or next;
    my $page = do { local $/; <$ph> };
    close $ph;
    # MATCHED ON THE VERB, not on `action=`, because a page can compose the
    # action name before it sends it. plugins.md did exactly that -
    #
    #   var action = input.checked ? 'plugin-enable' : 'plugin-disable';
    #   fetch(API + '?action=' + action, ...)
    #
    # - so the literal `action=plugin-` never appeared in the source, this check
    # passed, and the shipped Extension Manager fired the deprecation INFO on
    # every toggle. Which is precisely the way a deprecation notice becomes
    # furniture, and precisely what this assertion exists to prevent.
    #
    # The seven verbs are named rather than matching `plugin-` loosely: the DOM
    # ids on these pages are `plugin-modal`, `plugin-registry`, `plugin-status`
    # and `'plugin-' + id`, and those are identifiers, not actions. They have
    # not moved and they are not what this is about.
    # An ELEMENT ID IS NOT AN ACTION, and on these pages several look alike:
    # `<div id="plugin-list">`, getElementById('plugin-list'), 'plugin-modal',
    # 'plugin-' + id. The ids have not moved and are not what this is about, so
    # they are removed before the match rather than guessed at - the first
    # version of this stronger check reported plugin-config.md on the strength
    # of a div.
    my $scan = $page;
    $scan =~ s/getElementById\(\s*['"][^'"]*['"]\s*\)//g;
    $scan =~ s/\bid\s*=\s*['"][^'"]*['"]//g;
    push @old, "$p"
        if $scan =~ /(?:action=|['"])plugin-(?:list|read|save|action|config|enable|disable)\b/;
}
is_deeply( \@old, [], 'no shipped manager page calls the deprecated action spelling' )
    or diag( "still on the old name: @old" );

done_testing();

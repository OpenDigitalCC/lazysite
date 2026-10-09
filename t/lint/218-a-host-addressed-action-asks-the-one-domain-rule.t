#!/usr/bin/perl
# SM976: every action addressed by a host or a content root asks the one domain
# rule, Lazysite::Manager::Common::caller_may_reach_domain.
#
# A domain-confined caller reaches only its own domains (ruled 2026-10-09). The
# gaps SM976 closed were all the same gap: an action took a `host`, and nothing
# between the request and the write asked whether the caller reached it - the
# domain verbs, MCP domain_set, the site packages for a cookie manager, the
# navigation on three surfaces. Each was found by probing, one at a time. This
# makes the next one a decision rather than a discovery.
#
# WHAT COUNTS AS ASKING. A sub "asks" when its body names the predicate, its
# refusal (domain_reach_refusal), or another sub that asks - found by closure
# over every sub in the files below, so a wrapper such as
# _refuse_unreachable_domain or Manager::Nav's action_nav_save counts only
# because its own body asks.
#
# WHAT IS CHECKED.
#   1. Control API: every action that declares a `host`, `content_root` or
#      `alias_of` parameter, or whose dispatch branch or handler reads one, asks
#      in its branch or in a sub the branch calls - or is on %EXCEPT below with
#      the reason. An exception that no longer takes a host, or that asks
#      anyway, fails: the list stays closed and true.
#   2. The actions in %MUST_ASK ask too, though no host is named: the
#      listings of per-domain objects, which filter, and the verbs addressed
#      by a site package's name or by the primary.
#   3. MCP: every tool whose inputSchema has a `host` or `content_root`
#      property asks in its block or in a sub the block calls; list_domains too.
#   4. WebDAV: each navigation branch of authorise() asks.
#
# Files are named relative to the repository root, so the lint judges the same
# set from any checkout - including one under tmp/.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();

# Closed: action => why it does not ask. An entry must take a host and must
# not ask, or the lint fails.
my %EXCEPT = (
    'data-table-save' => 'the `domain:` it reads is a table\'s, checked by the data '
        . 'surface\'s own rule (Manager::Data _caller_domains, SM593/SM648), which every '
        . 'table action applies; SM976 records where that rule differs from this one',
);

# No host named, and must ask all the same.
my %MUST_ASK = (
    'domains-list' => 'a row carries the content root, access groups and address of a domain',
    'remap-list'  => "a rule names a domain and where its visitors are sent",
    'backup-list' => 'a site package is a whole domain, and its name carries the host',
    'site-backup-download' => 'addressed by a package, whose manifest names its domain',
    'site-backup-delete'   => 'addressed by a package, whose manifest names its domain',
    'site-export-primary'  => 'packages the primary site',
);

my @FILES = ( 'lazysite-manager-api.pl', 'lazysite-mcp.pl', 'lazysite-dav.pl',
    map { s{\A\Q$root\E/}{}r } sort glob "$root/lib/Lazysite/Manager/*.pm" );

sub slurp { open my $fh, '<', "$root/$_[0]" or die "$_[0]: $!"; local $/; return scalar <$fh> }

# Code only: POD and everything after __END__ go, and so do comments, which
# name the predicate in prose.
sub code_of {
    my ($src) = @_;
    $src =~ s/^__(?:END|DATA)__\b.*//ms;
    $src =~ s/^=[a-zA-Z].*?^=cut\b[^\n]*//gms;
    $src =~ s/^\s*#.*$//gm;
    $src =~ s/(?<=[;{}),])\s*#.*$//gm;
    return $src;
}

my %CODE = map { $_ => code_of( slurp($_) ) } @FILES;

# Every top-level sub, by name.
my %BODY;
for my $f (@FILES) {
    # A one-line sub closes on its own line; any other at the next column-0 brace.
    while ( $CODE{$f} =~ /^sub\s+(\w+)\s*\{(?:([^\n]*)\}[ \t]*$|(.*?)^\})/msg ) {
        $BODY{$1} .= $2 // $3;
    }
}
ok( scalar( keys %BODY ) > 200, 'the subs of the manager surfaces were read' );

# The closure: which subs ask.
my %ASKS = map { $_ => 1 } qw(caller_may_reach_domain domain_reach_refusal);
ok( $BODY{caller_may_reach_domain}, 'the predicate is defined where it is looked for' );
for ( my $grew = 1; $grew; ) {
    $grew = 0;
    for my $s ( keys %BODY ) {
        next if $ASKS{$s};
        my $b = $BODY{$s};
        next unless grep { $b =~ /\b\Q$_\E\b/ } keys %ASKS;
        $ASKS{$s} = $grew = 1;
    }
}
sub asks_in {
    my ($text) = @_;
    return 1 if grep { $text =~ /\b\Q$_\E\b/ } keys %ASKS;
    return 0;
}
# The subs a piece of code calls by name, with their bodies.
sub with_callees {
    my ($text) = @_;
    my %seen;
    my @called = grep { $BODY{$_} && !$seen{$_}++ } $text =~ /\b(\w+)\s*\(/g;
    return join "\n", $text, map { $BODY{$_} } @called;
}
my $TAKES_HOST = qr/\{\s*['"]?(?:host|content_root|alias_of)['"]?\s*\}/;

# --- 1, 2: the control API --------------------------------------------------
my $api = $CODE{'lazysite-manager-api.pl'};
my %BRANCH;
while ( $api =~ /^(?:if|elsif)\s*\(\s*\$action\s+eq\s+'([a-z0-9_-]+)'\s*\)\s*\{(.*?)(?=^(?:elsif|else)\b|^\}\s*$)/msg ) {
    $BRANCH{$1} .= $2;
}
ok( scalar( keys %BRANCH ) > 100, 'the dispatch branches were read' );

my %ACTION = %Lazysite::ControlApi::Actions::ACTION;
my ( @asked, @missing );
for my $a ( sort keys %ACTION ) {
    my $declared = grep { ( $_->{name} // '' ) =~ /\A(?:host|content_root|alias_of)\z/ }
        @{ $ACTION{$a}{params} || [] };
    my $branch = $BRANCH{$a};
    next unless defined $branch;
    my $code = with_callees($branch);
    next unless $declared || $code =~ $TAKES_HOST || $MUST_ASK{$a};
    if ( $EXCEPT{$a} ) {
        ok( !asks_in($code), "exception $a does not ask the rule (one that does leaves the list)" );
        next;
    }
    if   ( asks_in($code) ) { push @asked,   $a }
    else                    { push @missing, $a }
}
is_deeply( \@missing, [], 'every host-addressed control-API action asks the domain rule' )
    or diag( 'Each of these names a host or a content root and never asks '
        . 'Lazysite::Manager::Common::caller_may_reach_domain (directly or through a sub that '
        . 'does). Ask it, or add the action to %EXCEPT with the reason it may reach any domain.' );
for my $a ( sort keys %EXCEPT ) {
    ok( $BRANCH{$a} && ( with_callees( $BRANCH{$a} ) =~ $TAKES_HOST ), "exception $a still takes a host" );
}
for my $l ( sort keys %MUST_ASK ) {
    ok( ( grep { $_ eq $l } @asked ), "$l asks the rule: $MUST_ASK{$l}" );
}
cmp_ok( scalar @asked, '>=', 20, 'and the set it found is the size it should be' )
    or diag( 'Found: ' . join ', ', @asked );

# --- 3: MCP -------------------------------------------------------------------
my $mcp = $CODE{'lazysite-mcp.pl'};
my ($tools) = $mcp =~ /^my %TOOLS = \((.*?)^\);/ms;
ok( defined $tools, 'the MCP tool table was found' );
my %TOOL;
my @parts = split /^    ([a-z_]+) => \{\s*$/m, ( $tools // '' );
shift @parts;
while ( my ( $name, $block ) = splice @parts, 0, 2 ) { $TOOL{$name} = $block }
ok( scalar( keys %TOOL ) > 50, 'the MCP tools were read' );
my ( @mcp_asked, @mcp_missing );
for my $t ( sort keys %TOOL ) {
    my $props = $TOOL{$t} =~ /\b(?:host|content_root)\s*=>\s*\{/;
    next unless $props || $t eq 'list_domains';
    my $code = with_callees( $TOOL{$t} =~ s/\\&(\w+)/$1(/gr );
    if   ( asks_in($code) ) { push @mcp_asked,   $t }
    else                    { push @mcp_missing, $t }
}
is_deeply( \@mcp_missing, [], 'every MCP tool taking a host or content root asks the domain rule' );
cmp_ok( scalar @mcp_asked, '>=', 9, 'and the set it found is the size it should be' )
    or diag( 'Found: ' . join ', ', @mcp_asked );

# --- 4: WebDAV ------------------------------------------------------------------
my $auth      = $BODY{authorise} // '';
my $nav_gates = () = $auth =~ /manage_nav_for\(\s*\$user\s*\)/g;
my $nav_asks  = () = $auth =~ /return\s+_nav_reach_deny\(/g;
ok( $nav_gates >= 2, 'WebDAV authorise() gates the navigation files' );
is( $nav_asks, $nav_gates, 'and each navigation branch asks the domain rule' );
ok( $ASKS{_nav_reach_deny}, '...through a sub that asks it' );

done_testing();

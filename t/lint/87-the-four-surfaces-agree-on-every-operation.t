#!/usr/bin/perl
# SM563: the four surfaces agree on every operation.
#
# The same logical operation is authorised from four hand-maintained tables:
# the manager cookie map (%COOKIE_CAP), the token gate (%need), the MCP tool
# registry (cap => per tool), and the WebDAV verb map (lazysite-dav.pl's
# authorise, whose deny strings are enforcement's own statement of the rule -
# lint 68's device). lint 14 compares the first two, lint 86 the token gate
# against the action registry, lint 23 the API against MCP; the DAV map was
# compared to nothing. SM570 was two of these tables disagreeing about WHO
# may do a thing; with four tables and only two compared pairs, the same
# defect had two more places to live.
#
# This is lint 85's discipline generalised one level up: for each LOGICAL
# operation, read the capability set from every surface that offers it and
# fail on any disagreement. A surface where the operation is deliberately
# absent or deliberately different is EXEMPTED with its reason, exactly as
# lint 23's %API_ONLY records one-sided actions - a gap someone chose must
# read differently from a gap nobody noticed. A stale exemption fails.
#
# And the SM570 shape itself is refused on sight: a CHANNEL capability
# (webdav / api / mcp / ui) says which door a grant may use, never what it
# may do through it, so one appearing in ANY column fails by itself.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
my $api_src = slurp("$root/lazysite-manager-api.pl");
my $mcp_src = slurp("$root/lazysite-mcp.pl");
my $dav_src = slurp("$root/lazysite-dav.pl");

# --- column 1: %COOKIE_CAP (lint 14's parser) --------------------------------
my ($cc_block) = $api_src =~ /my %COOKIE_CAP = \((.*?)\n    \);/s;
ok( $cc_block, 'found %COOKIE_CAP' );
my %cookie_caps;
while ( ( $cc_block // '' ) =~ /'([a-z0-9-]+)'\s*=>\s*'([a-z0-9_|]+)'/g ) {
    $cookie_caps{$1} = { map { $_ => 1 } split /\|/, $2 };
}
cmp_ok( scalar keys %cookie_caps, '>=', 30, '%COOKIE_CAP parsed non-trivially' );

# --- column 2: the token gate %need (lint 86's parser) -----------------------
my ($need_block) = $api_src =~ /my %need = \((.*?)\n    \);/s;
ok( $need_block, 'found %need' );
my %need_caps;
while ( ( $need_block // '' ) =~ /'([a-z0-9_-]+)'\s*=>\s*sub\s*\{(.*?)\},?[ ]*(?:#[^\n]*)?\n/g ) {
    my ( $a, $body ) = ( $1, $2 );
    $need_caps{$a} = { map { $_ => 1 } $body =~ /\{(\w+)\}/g };
}
cmp_ok( scalar keys %need_caps, '>=', 60, '%need parsed non-trivially' );

# --- column 3: the MCP tool registry -----------------------------------------
# Segment %TOOLS on its 4-space-indented entry names (lint 23 parses the same
# names) and read each entry's `cap =>` declaration.
my ($tools_block) = $mcp_src =~ /my %TOOLS = \((.*)\n\);/s;
ok( $tools_block, 'found the MCP %TOOLS registry' );
my %mcp_caps;
{
    my @part = split /^    ([a-z_]+)\s*=>\s*\{/m, ( $tools_block // '' );
    shift @part;    # leading text before the first tool
    while ( my ( $name, $chunk ) = splice @part, 0, 2 ) {
        next unless ( $chunk // '' ) =~ /\bcap\s*=>\s*(?:'([a-z_]+)'|undef)/;
        $mcp_caps{$name} = defined $1 ? { $1 => 1 } : {};
    }
}
cmp_ok( scalar keys %mcp_caps, '>=', 40, 'the MCP tool caps parsed non-trivially' );

# --- column 4: the DAV verb map, through its own deny strings ----------------
# authorise() names the required capability in every refusal (lint 68 reads
# the per-path ones the same way). One matcher per governed namespace.
sub dav_caps_from {
    my ($re)    = @_;
    my ($named) = $dav_src =~ $re;
    return undef unless defined $named;
    return { map { $_ => 1 } grep { $_ ne 'or' } split /\s+/, $named };
}
my %DAV_MATCHER = (
    'content-namespace' => qr/publishing site content requires the ([a-z_]+) capability/,
    'theme-object' => qr/installing or editing a theme requires the ([a-z_]+(?:\s+or\s+[a-z_]+)*) capability/,
);

# --- the operation map -------------------------------------------------------
# Per logical operation, where each surface spells it. `dav` names a matcher
# above; undef means the surface has no verb for the operation (which then
# needs no exemption - only a LISTED spelling that goes missing fails).
my %OPERATION = (
    'read content' => { cookie => 'read', token => 'read', mcp => 'read_file', dav => 'content-namespace' },
    'write content' => { cookie => 'save', token => 'save', mcp => 'write_file', dav => 'content-namespace' },
    'set a rule' => { cookie => 'acl-set', token => 'acl-set', mcp => 'set_permissions', dav => undef },
    'write a theme file' => { cookie => 'theme-upload', token => 'theme-upload', mcp => 'create_theme', dav => 'theme-object' },
    'read submissions' => { cookie => 'form-submissions', token => 'form-submissions', mcp => 'read_form_submissions', dav => undef },
);

# --- the exemptions, each with its reason (lint 23's %API_ONLY discipline) ---
my %EXEMPT = (
    'read content/cookie' => 'content reads/writes self-authorise per file through the ACL layer '
        . '(owner or @group-listed); deliberately absent from %COOKIE_CAP, POST/CSRF-gated only',
    'write content/cookie' => 'same ACL self-authorisation as the read side',
    'set a rule/cookie'    => 'acl-set self-authorises by ownership in the action body '
        . '(a file owner grants on their own file without holding manage_content); '
        . 'deliberately absent from %COOKIE_CAP - see its own comment there',
    'read content/token' => 'token clients read content over WebDAV; absent from the default-deny %need is the decision',
    'write content/token' => 'token clients write content over WebDAV; absent from the default-deny %need is the decision',
    'write a theme file/token' => 'token clients install theme files over WebDAV (the SM071 layouts carve-out); '
        . 'theme-upload is the manager UI\'s cookie-only spelling',
    'read submissions/mcp' => 'SM567/lint 23: read_form_submissions deliberately narrows to read_submissions '
        . '(least privilege); the API accepts manage_forms OR read_submissions and lint 23 records the subset',
);

# Staleness: every exemption must name a real operation/column.
for my $k ( sort keys %EXEMPT ) {
    my ( $op, $col ) = $k =~ m{^(.*)/(cookie|token|mcp|dav)\z};
    ok( $op && $OPERATION{$op}, "exemption '$k' names a real operation and column" );
}

# --- the comparison ----------------------------------------------------------
my %CHANNEL = map { $_ => 1 } qw(webdav api mcp ui);
for my $op ( sort keys %OPERATION ) {
    my $spec = $OPERATION{$op};
    my %col;
    $col{cookie} = $cookie_caps{ $spec->{cookie} } if defined $spec->{cookie};
    $col{token}  = $need_caps{ $spec->{token} }    if defined $spec->{token};
    $col{mcp}    = $mcp_caps{ $spec->{mcp} }       if defined $spec->{mcp};
    $col{dav}    = dav_caps_from( $DAV_MATCHER{ $spec->{dav} } ) if defined $spec->{dav};

    my %live;    # column => joined cap set, exemptions removed
    for my $c ( sort keys %col ) {
        if ( $EXEMPT{"$op/$c"} ) {
            ok( length $EXEMPT{"$op/$c"} > 20, "'$op' on the $c surface: exemption carries a real reason" );
            next;
        }
        ok( defined $col{$c} && keys %{ $col{$c} },
            "'$op' is spelled on the $c surface (or exempted with a reason)" )
            or next;
        my @channel_caps = sort grep { $CHANNEL{$_} } keys %{ $col{$c} };
        is( "@channel_caps", '',
            "'$op' on the $c surface names no CHANNEL capability (SM570: a door is not an authority)" );
        $live{$c} = join ',', sort keys %{ $col{$c} };
    }
    my %distinct = map { $_ => 1 } values %live;
    is( scalar keys %distinct, ( keys %live ? 1 : 0 ),
        "'$op': every surface that offers it requires the same capability set" )
        or diag( map { "  $_: [$live{$_}]\n" } sort keys %live );
}

done_testing();

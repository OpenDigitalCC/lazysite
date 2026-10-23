#!/usr/bin/perl
# SM1284 (rulings 4, 32): EVERY /docs LINK AN AGENT IS GIVEN LANDS ON A PAGE
# THE ENGINE SERVES.
#
# The /docs manual is the engine's: it ships under
# starter/lazysite/templates/docs/ and serves at /docs/ whatever the site has
# cleared out. That holds only while each link INTO /docs from the manual, and
# from the surfaces that point agents at it, names a page that is there. A
# briefing that gained a link to a page nobody ships would send an agent to a
# 404 on every site - which is what theunited.community's owner had to prevent
# by hand, keeping 30 of 70 pages because the briefings linked to them.
#
# Checked: every page of the manual, and the four pointers the briefings are
# reached through - the partner brief (tools/lazysite-users.pl), the shipped
# .well-known/ai-partner page, the MCP server's instructions and tool
# descriptions (lazysite-mcp.pl), and describe_capabilities' docs index, which
# lists the manual itself (lib/Lazysite/Capabilities.pm, its note only).
#
# A link is what an agent follows: a Markdown link target, an href, or a /docs/
# path named in prose. Code spans and code blocks are left out - they hold
# example URL tables, which name /docs/ paths without sending anyone there.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $DOCS = "$root/starter/lazysite/templates/docs";
ok( -f "$DOCS/ai-briefing-authoring.md", 'the manual is in the engine tree' );
ok( !-e "$root/starter/docs", 'and not in the starter content, where a cleanup reaches it' );

# The page a /docs URL path names: /docs/x is x.md, or x/index.md for a section.
sub resolves {
    my ($url) = @_;
    $url =~ s/[?#].*\z//s;
    $url =~ s{[.,;:]+\z}{};
    return 1 unless $url =~ m{\A/docs(?:/(.*))?\z}s;
    my $p = defined $1 ? $1 : '';
    $p =~ s{\.(?:md|html)\z}{};
    $p =~ s{/\z}{/index};
    $p = 'index' unless length $p;
    return ( -f "$DOCS/$p.md" || -f "$DOCS/$p/index.md" ) ? 1 : 0;
}

sub links_in_markdown {
    my ($text) = @_;
    $text =~ s/\A---\n.*?^---\n//ms;            # front matter
    $text =~ s/^(```|~~~).*?^\1[^\n]*$//msg;    # fenced blocks
    $text =~ s/^(?: {4}|\t).*$//mg;             # indented code
    $text =~ s/(`+).*?\1//sg;                   # code spans
    return (
        ( $text =~ /\]\(\s*(\/docs[^)\s]*)/g ),
        ( $text =~ /href=["'](\/docs[^"']*)/g ),
        ( $text =~ m{(?:\A|[\s(])(/docs(?:/[A-Za-z0-9_./#-]*)?)}g ),
    );
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "cannot read $f: $!\n";
    local $/;
    return scalar <$fh>;
}

my @dead;
my $pages = 0;
my @queue = ($DOCS);
while ( defined( my $dir = shift @queue ) ) {
    opendir my $dh, $dir or die "$dir: $!";
    for my $e ( sort readdir $dh ) {
        next if $e =~ /\A\./;
        my $p = "$dir/$e";
        if ( -d $p ) { push @queue, $p; next }
        next unless $e =~ /\.md\z/;
        $pages++;
        ( my $rel = $p ) =~ s{\A\Q$root\E/}{};
        push @dead, map {"$rel -> $_"} grep { !resolves($_) } links_in_markdown( slurp($p) );
    }
    closedir $dh;
}
cmp_ok( $pages, '>', 70, "the whole manual was read ($pages pages)" );

# The pointers. The Perl sources name /docs paths inside strings, so every
# /docs path in them counts, less the examples that only show how a path maps;
# the ai-partner page is Markdown.
my %EXAMPLE = (
    'tools/lazysite-users.pl' => { '/docs/help' => 'the brief\'s "docs/help.md serves at /docs/help"' },
);
for my $rel (qw(tools/lazysite-users.pl lazysite-mcp.pl lib/Lazysite/Capabilities.pm)) {
    my $src = slurp("$root/$rel");
    my @named = $src =~ m{(/docs/[A-Za-z0-9_./#-]*[A-Za-z0-9_/-])}g;
    ok( @named || $rel =~ /Capabilities/, "$rel names /docs paths" );
    push @dead, map {"$rel -> $_"} grep { !resolves($_) && !$EXAMPLE{$rel}{$_} } @named;
}
push @dead, map {".well-known/ai-partner.md -> $_"}
    grep { !resolves($_) } links_in_markdown( slurp("$root/starter/.well-known/ai-partner.md") );

is_deeply( \@dead, [], 'every /docs link in the manual and its pointers names a page the engine serves' )
    or diag( "A /docs link that names no page of the manual:\n  " . join( "\n  ", @dead )
        . "\nShip the page under starter/lazysite/templates/docs/, or point the link at one that is there." );

done_testing();

#!/usr/bin/perl
# SM1341: EVERY #ANCHOR IN A /docs LINK NAMES A HEADING THE PAGE RENDERS.
#
# Lint 290 holds each /docs link to a page the engine serves and leaves the
# fragment out. Saying a thing once (ruling 80) means pointing at it, often at
# one section of another page, so the fragment is now half the link. And the
# fragments were already wrong: the manual wrote GitHub-style anchors
# (#the-docs-manual, #multi-domain-instances), while the engine's converter,
# Text::MultiMarkdown, ids a heading by lower-casing it and dropping everything
# but letters, digits, `:`, `_`, `.` and `-` - spaces included - so those
# headings are #thedocsmanual and #multi-domaininstances, and the links landed at
# the top of the page.
#
# Checked: every Markdown link and href in the manual whose target is a /docs page
# with a #fragment, or a bare #fragment on the same page, against the headings of
# the page it names, under the converter's rule (_Header2Label). Code spans and
# blocks are left out, as in lint 290.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $DOCS = "$root/starter/lazysite/templates/docs";

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "cannot read $f: $!\n";
    local $/;
    return scalar <$fh>;
}

sub strip_code {
    my ($text) = @_;
    $text =~ s/\A---\n.*?^---\n//ms;
    $text =~ s/^(```|~~~).*?^\1[^\n]*$//msg;
    $text =~ s/^(?: {4}|\t).*$//mg;
    return $text;
}

# Text::MultiMarkdown::_Header2Label, which ids every heading the engine renders.
sub label {
    my ($h) = @_;
    my $l = lc $h;
    $l =~ s/[^A-Za-z0-9:_.-]//g;
    1 while $l =~ s/^[^A-Za-z]//;
    return $l;
}

my %ids;    # page (docs-relative, no .md) => { id => 1 }

sub ids_of {
    my ($page) = @_;
    return $ids{$page} if $ids{$page};
    my $f = -f "$DOCS/$page.md" ? "$DOCS/$page.md" : "$DOCS/$page/index.md";
    return $ids{$page} = undef unless -f $f;
    my $text = strip_code( slurp($f) );
    my %h;
    $h{ label($1) } = 1 while $text =~ /^#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$/mg;
    return $ids{$page} = \%h;
}

sub page_of {
    my ($url) = @_;
    return undef unless $url =~ m{\A/docs(?:/(.*))?\z}s;
    my $p = defined $1 ? $1 : '';
    $p =~ s{\.(?:md|html)\z}{};
    $p =~ s{/\z}{/index};
    $p = 'index' unless length $p;
    $p = "$p/index" if !-f "$DOCS/$p.md" && -f "$DOCS/$p/index.md";
    return $p;
}

# ai-briefing-practice.md is generated from sources outside this repo and lint 89
# refuses an edit to the served copy, so its anchors are fixed at the source. The
# one it carries is named here, and the test fails if it changes or another appears.
my %GENERATED = ( 'docs/ai-briefing-practice.md -> #handing-out-work-to-several-people-at-once' => 1 );

my ( @dead, $links );
my @queue = ($DOCS);
while ( defined( my $dir = shift @queue ) ) {
    opendir my $dh, $dir or die "$dir: $!";
    for my $e ( sort readdir $dh ) {
        next if $e =~ /\A\./;
        my $p = "$dir/$e";
        if ( -d $p ) { push @queue, $p; next }
        next unless $e =~ /\.md\z/;
        ( my $self = $p ) =~ s{\A\Q$DOCS\E/}{};
        $self =~ s/\.md\z//;
        my $text = strip_code( slurp($p) );
        $text =~ s/(`+).*?\1//sg;
        my @targets = ( ( $text =~ /\]\(\s*((?:\/docs[^)\s#]*)?#[^)\s]+)\)/g ),
            ( $text =~ /href=["']((?:\/docs[^"'#]*)?#[^"']+)["']/g ) );
        for my $t (@targets) {
            my ( $url, $frag ) = split /#/, $t, 2;
            my $page = length $url ? page_of($url) : $self;
            next unless defined $page;
            $links++;
            my $h = ids_of($page);
            push @dead, "docs/$self.md -> $t (no page)" and next unless $h;
            push @dead, "docs/$self.md -> $t" unless $h->{$frag};
        }
    }
    closedir $dh;
}
cmp_ok( $links, '>', 10, "the manual's anchored links were read ($links)" );
my @known = grep { $GENERATED{$_} } @dead;
@dead = grep { !$GENERATED{$_} } @dead;
is( scalar @known, scalar keys %GENERATED, 'the generated practice page still carries the anchor its source must fix' );
is_deeply( \@dead, [], 'every #anchor in a /docs link names a heading of the page it links' )
    or diag( "An anchor no heading carries:\n  " . join( "\n  ", @dead )
        . "\nThe engine ids a heading by lower-casing it and keeping only letters, digits, ':', '_', '.' and '-'"
        . " (no spaces): '## The /docs manual' is #thedocsmanual." );

done_testing();

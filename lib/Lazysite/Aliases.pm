package Lazysite::Aliases;

# SM134: page alias redirects. A page may declare `aliases:` in its front matter -
# old or alternate URLs it should also answer to. Those URLs are collected into a
# small map (lazysite/aliases.json: alias-url -> canonical-url) maintained as pages
# are saved and deleted; the processor consults it only on the no-source-found
# (404) path and issues a 301 to the canonical URL.
#
# Safety: the redirect TARGET is always the declaring page's own canonical URL
# (derived from its file path here), never an author-supplied value - so an alias
# can only redirect to the page that declared it, not to an arbitrary/external URL.
#
# The map is maintained here (write side); the processor does its own tiny inline
# read on the 404 path so its hot path keeps no module dependency (ADR 0001).

use strict;
use warnings;
use JSON::PP       ();
use Fcntl          qw(:flock SEEK_SET);
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(index_page deindex_page lookup canonical_url_for alias_map_path);

sub alias_map_path { return "$_[0]/lazysite/aliases.json" }

# The request URL a .md file answers to: foo/bar.md -> /foo/bar ;
# foo/index.md -> /foo ; index.md -> / .
sub canonical_url_for {
    my ($rel) = @_;
    $rel =~ s{^/+}{};
    $rel =~ s{\.md\z}{};
    $rel =~ s{(?:^|/)index\z}{};    # index -> its directory
    my $url = "/$rel";
    $url =~ s{//+}{/}g;
    $url =~ s{(.)/\z}{$1};          # strip trailing slash except root
    return length $url ? $url : '/';
}

# Extract the alias list from a page's front matter. Accepts a YAML block list
# (`- /path` lines) or an inline list (`aliases: [/a, /b]`). Only site-local
# absolute paths are kept.
sub _parse_aliases {
    my ($content) = @_;
    return () unless defined $content;
    my ($fm) = $content =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    return () unless defined $fm;

    my @raw;
    if ( $fm =~ /^aliases[ \t]*:[ \t]*\n((?:[ \t]*-[^\n]*(?:\n|\z))*)/m ) {
        my $block = $1;
        while ( $block =~ /^[ \t]*-[ \t]*(.+?)[ \t]*$/mg ) { push @raw, $1 }
    }
    elsif ( $fm =~ /^aliases[ \t]*:[ \t]*\[([^\]]*)\][ \t]*$/m ) {
        @raw = split /\s*,\s*/, $1;
    }

    my @clean;
    for my $a (@raw) {
        $a                          =~ s/^\s+|\s+$//g;
        $a                          =~ s/^["']|["']$//g;
        next unless length $a && $a =~ m{^/};              # site-local absolute only
        next if $a =~ m{^//};                              # not protocol-relative
        next if $a =~ /\.\./ || $a =~ /[\0\r\n]/;
        $a =~ s{/+$}{} unless $a eq '/';
        push @clean, $a;
    }
    return @clean;
}

sub lookup {
    my ( $docroot, $url ) = @_;
    return undef     unless defined $url && length $url;
    $url =~ s{/+$}{} unless $url eq '/';
    my $m = _read( alias_map_path($docroot) );
    return $m->{$url};
}

# Update the map for one page: clear its previous aliases (entries targeting this
# canonical URL), then add the current set. Returns the number of aliases indexed.
sub index_page {
    my ( $docroot, $rel, $content ) = @_;
    my $canon   = canonical_url_for($rel);
    my @aliases = _parse_aliases($content);
    _update( $docroot, sub {
            my ($m) = @_;
            for my $k ( keys %{$m} ) { delete $m->{$k} if $m->{$k} eq $canon }
            for my $a (@aliases) {
                next if $a eq $canon;    # a page cannot alias itself
                if ( exists $m->{$a} && $m->{$a} ne $canon ) {
                    log_event( 'WARN', 'aliases', 'alias claimed by two pages',
                        alias => $a, was => $m->{$a}, now => $canon );
                }
                $m->{$a} = $canon;
            }
            return $m;
    } );
    return scalar @aliases;
}

sub deindex_page {
    my ( $docroot, $rel ) = @_;
    my $canon = canonical_url_for($rel);
    _update( $docroot, sub {
            my ($m) = @_;
            for my $k ( keys %{$m} ) { delete $m->{$k} if $m->{$k} eq $canon }
            return $m;
    } );
    return;
}

# --- storage ---------------------------------------------------------------

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $m = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
    return ( ref $m eq 'HASH' ) ? $m : {};
}

sub _update {
    my ( $docroot, $mutate ) = @_;
    return unless -d "$docroot/lazysite";
    my $f = alias_map_path($docroot);
    open my $fh, '+>>', $f or return;
    flock $fh, LOCK_EX or do { close $fh; return };
    seek $fh, 0, SEEK_SET;
    my $raw = do { local $/; <$fh> };
    my $m   = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
    $m = {} unless ref $m eq 'HASH';
    $m = $mutate->($m);
    seek $fh, 0, SEEK_SET;
    truncate $fh, 0;
    print {$fh} JSON::PP::encode_json($m);
    close $fh;
    return;
}

1;

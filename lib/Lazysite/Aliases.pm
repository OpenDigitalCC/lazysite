package Lazysite::Aliases;

# SM134: page alias redirects. A page may declare `aliases:` in its front matter -
# old or alternate URLs it should also answer to. Those URLs are collected into a
# small map (lazysite/aliases.json) maintained as pages are saved, deleted, moved
# and copied; the processor consults it only on the no-source-found (404) path and
# redirects to the canonical URL.
#
# SM134 follow-ups: a second key `aliases_temp:` (same list syntax) declares
# TEMPORARY aliases, redirected 302 instead of the default 301. If the same path
# appears under both keys on one page, the `aliases_temp:` entry wins (302).
#
# Map schema (backward compatible): a 301 entry's value is the plain canonical-URL
# string, exactly as shipped in 0.6.1 - old maps keep working with no migration.
# A 302 entry's value is an object { "target": <canonical-url>, "code": 302 }.
# Readers must accept both shapes; anything else, or an unknown code, is treated
# as 301 to the entry's target.
#
# Safety: the redirect TARGET is always the declaring page's own canonical URL
# (derived from its file path here), never an author-supplied value - so an alias
# can only redirect to the page that declared it, not to an arbitrary/external URL.
#
# The map is maintained here (write side); the processor does its own tiny inline
# read on the 404 path so its hot path keeps no module dependency (ADR 0001) -
# keep that copy in sync with the schema above.

use strict;
use warnings;
use JSON::PP       ();
use Fcntl          qw(:flock SEEK_SET);
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(index_page deindex_page lookup canonical_url_for alias_map_path
    list_aliases reindex_move reindex_copy);

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

# The canonical-URL string of a map entry, whichever shape it has.
sub _target {
    my ($v) = @_;
    return ( ref $v eq 'HASH' ) ? ( $v->{target} // '' ) : ( $v // '' );
}

# Extract one alias list from a page's front matter, by key (`aliases` or
# `aliases_temp`). Accepts a YAML block list (`- /path` lines) or an inline list
# (`key: [/a, /b]`). Only site-local absolute paths are kept.
sub _parse_aliases {
    my ( $content, $key ) = @_;
    $key //= 'aliases';
    return () unless defined $content;
    my ($fm) = $content =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    return () unless defined $fm;

    my @raw;
    if ( $fm =~ /^\Q$key\E[ \t]*:[ \t]*\n((?:[ \t]*-[^\n]*(?:\n|\z))*)/m ) {
        my $block = $1;
        while ( $block =~ /^[ \t]*-[ \t]*(.+?)[ \t]*$/mg ) { push @raw, $1 }
    }
    elsif ( $fm =~ /^\Q$key\E[ \t]*:[ \t]*\[([^\]]*)\][ \t]*$/m ) {
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
    my $v = $m->{$url};
    return defined $v ? _target($v) : undef;
}

# The whole map as display rows: [ { alias, target, code }, ... ] sorted by
# alias. Codes are normalised (anything but 302 reads as 301).
sub list_aliases {
    my ($docroot) = @_;
    my $m = _read( alias_map_path($docroot) );
    my @rows;
    for my $a ( sort keys %{$m} ) {
        my $v    = $m->{$a};
        my $code = ( ref $v eq 'HASH' && ( $v->{code} // '' ) =~ /\A302\z/ ) ? 302 : 301;
        push @rows, { alias => $a, target => _target($v), code => $code };
    }
    return \@rows;
}

# Update the map for one page: clear its previous aliases (entries targeting this
# canonical URL), then add the current set. Returns the number of aliases indexed.
sub index_page {
    my ( $docroot, $rel, $content ) = @_;
    my $canon   = canonical_url_for($rel);
    my @entries = (
        ( map { [ $_, 301 ] } _parse_aliases( $content, 'aliases' ) ),
        ( map { [ $_, 302 ] } _parse_aliases( $content, 'aliases_temp' ) ),
    );
    _update( $docroot, sub {
            my ($m) = @_;
            for my $k ( keys %{$m} ) { delete $m->{$k} if _target( $m->{$k} ) eq $canon }
            for my $e (@entries) {
                my ( $a, $code ) = @{$e};
                next if $a eq $canon;    # a page cannot alias itself
                if ( exists $m->{$a} && _target( $m->{$a} ) ne $canon ) {
                    log_event( 'WARN', 'aliases', 'alias claimed by two pages',
                        alias => $a, was => _target( $m->{$a} ), now => $canon );
                }
                $m->{$a} = $code == 302 ? { target => $canon, code => 302 } : $canon;
            }
            return $m;
    } );
    return scalar @entries;
}

sub deindex_page {
    my ( $docroot, $rel ) = @_;
    my $canon = canonical_url_for($rel);
    _update( $docroot, sub {
            my ($m) = @_;
            for my $k ( keys %{$m} ) { delete $m->{$k} if _target( $m->{$k} ) eq $canon }
            return $m;
    } );
    return;
}

# --- SM134 follow-ups: reindex on move / copy --------------------------------
# A rename, manager move/copy or DAV MOVE/COPY changes a page's canonical URL
# without a save, so the map would otherwise go stale until the next edit. These
# reindex just the affected page - or, for a directory, the pages under it.

# The .md files a path covers, docroot-relative: the path itself if it is a .md
# file, every .md beneath it if a directory, nothing otherwise.
sub _md_rels {
    my ( $docroot, $rel ) = @_;
    $rel =~ s{^/+}{};
    my $abs = "$docroot/$rel";
    if ( -f $abs ) { return $rel =~ /\.md\z/ ? ($rel) : () }
    return () unless -d $abs;
    my @found;
    my @stack = ($rel);
    while (@stack) {
        my $r = pop @stack;
        opendir my $dh, "$docroot/$r" or next;
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            my $c = "$r/$e";
            if    ( -d "$docroot/$c" ) { push @stack, $c }
            elsif ( $e =~ /\.md\z/ )   { push @found, $c }
        }
        closedir $dh;
    }
    return @found;
}

sub _index_from_disk {
    my ( $docroot, $rel ) = @_;
    open my $fh, '<', "$docroot/$rel" or return;
    my $content = do { local $/; <$fh> };
    close $fh;
    index_page( $docroot, $rel, $content );
    return;
}

# After a move/rename (the destination already holds the content): drop the map
# entries keyed to the old location(s), re-add under the new canonical URL(s).
sub reindex_move {
    my ( $docroot, $src_rel, $dst_rel ) = @_;
    s{^/+}{} for ( $src_rel, $dst_rel );
    # A .md renamed away from .md simply loses its aliases.
    deindex_page( $docroot, $src_rel ) if $src_rel =~ /\.md\z/;
    for my $new ( _md_rels( $docroot, $dst_rel ) ) {
        ( my $old = $new ) =~ s{^\Q$dst_rel\E}{$src_rel};
        deindex_page( $docroot, $old ) if $old =~ /\.md\z/;
        _index_from_disk( $docroot, $new );
    }
    return;
}

# After a copy: index the duplicate(s). Same collision rule as a save - if source
# and copy declare the same alias, the last writer (the copy) takes it, WARNed.
sub reindex_copy {
    my ( $docroot, $dst_rel ) = @_;
    $dst_rel =~ s{^/+}{};
    _index_from_disk( $docroot, $_ ) for _md_rels( $docroot, $dst_rel );
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

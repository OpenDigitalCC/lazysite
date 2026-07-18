package Lazysite::Lang;

# SM179: language sets. A `lang_group` names a set of hosts (the base host plus
# alias.<host>.* overrides in lazysite.conf) that are the SAME site in different
# languages, each rooted at its own content_root. This module is the single
# source of set membership and translation-coverage status, shared by the
# processor's agent-facing surfaces (whoami / MCP) and the manager control-API's
# lang_status action - so the CLI, the API and the UI all agree on what a set is
# and what still needs translating.
#
# HARD SCOPE LINE: this module only READS the conf and stats content files. It
# never writes conf, never moves content, and never decides confinement - domain
# access is SM165's job (Lazysite::Auth::DomainAccess).

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Exporter 'import';
our @EXPORT_OK = qw(set_members lang_status sole_group);

# sole_group($conf_text) -> the single distinct lang_group declared anywhere in
# the conf (base `lang_group:` OR any `alias.<host>.lang_group:`), or '' if there
# is none or more than one. Callers use it to find "the" language set without
# assuming the group is declared on the base host - a set can be declared purely
# across alias hosts (the base host need not be a set member).
sub sole_group {
    my ($text) = @_;
    my %g;
    while ( ( $text // '' ) =~ /^(?:alias\.\S+\.)?lang_group\h*:\h*(\S+)/mg ) {
        $g{$1} = 1;
    }
    my @k = keys %g;
    return @k == 1 ? $k[0] : '';
}

# Content pages whose translations lang_status tracks. Generated registries
# (sitemap.xml, llms.txt, feed.*) and assets are deliberately excluded.
my %CONTENT_EXT = ( md => 1, url => 1, html => 1 );

# Parse conf text into (\%base, \%alias) exactly as the processor does: bare
# `key: value` lines are the base host; `alias.<host>.<key>: value` lines are
# per-host overrides (host lower-cased).
sub _parse_conf {
    my ($text) = @_;
    my ( %base, %alias );
    while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) { $base{$1} = $2 }
    while ( $text =~ /^alias\.(\S+)\.(\w+)\h*:\h*(.+)$/mg ) { $alias{ lc $1 }{$2} = $3 }
    return ( \%base, \%alias );
}

# set_members($conf_text, $group) -> list of members of the set $group names,
# each { host, lang, content_root, site_url, source }. `source` is 1 for the
# base host (the source of truth) if it is in the set, else the first member.
# Returns () unless the set has at least two members (a lone host is not a set).
sub set_members {
    my ( $text, $group ) = @_;
    return () unless defined $group && length $group;
    my ( $base, $alias ) = _parse_conf($text);

    my @m;
    push @m,
        {
        host         => '',
        lang         => ( $base->{lang}         // '' ),
        content_root => ( $base->{content_root} // '' ),
        site_url     => ( $base->{site_url}     // '' ),
        }
        if ( $base->{lang_group} // '' ) eq $group;
    for my $h ( sort keys %$alias ) {
        push @m,
            {
            host         => $h,
            lang         => ( $alias->{$h}{lang}         // '' ),
            content_root => ( $alias->{$h}{content_root} // '' ),
            site_url     => ( $alias->{$h}{site_url}     // '' ),
            }
            if ( $alias->{$h}{lang_group} // '' ) eq $group;
    }
    return () unless @m >= 2;

    my $src_ix = 0;
    for my $i ( 0 .. $#m ) {
        if ( $m[$i]{host} eq '' ) { $src_ix = $i; last }
    }
    $m[$_]{source} = ( $_ == $src_ix ) ? 1 : 0 for 0 .. $#m;
    return @m;
}

# A member's absolute content root under the docroot (docroot itself when the
# member declares no content_root). No confinement is applied here - callers
# pass a content_root that SM151/SM165 already vet; this only joins the path.
sub _root_path {
    my ( $docroot, $croot ) = @_;
    return ( defined $croot && length $croot ) ? "$docroot/$croot" : $docroot;
}

# List content pages under $root as root-relative paths (e.g. 'compare.md',
# 'docs/intro.md'). The lazysite/ control tree and dotfiles are skipped.
sub _content_files {
    my ($root) = @_;
    my @out;
    my @stack = ($root);
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( sort readdir $dh ) {
            next if $e eq '.' || $e eq '..';
            next if $e =~ /^\./;
            next if $e eq 'lazysite';
            my $abs = "$dir/$e";
            if ( -d $abs ) { push @stack, $abs; next }
            next unless $e =~ /\.(\w+)$/ && $CONTENT_EXT{ lc $1 };
            ( my $rel = $abs ) =~ s{^\Q$root\E/}{};
            push @out, $rel;
        }
        closedir $dh;
    }
    @out = sort @out;
    return @out;
}

# The `translated_from:` front-matter marker of a file, if any (a content hash a
# translation tool may record to pin exact staleness). Returns '' when absent.
sub _translated_from {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    my $head = do { local $/; <$fh> };
    close $fh;
    return $1 if $head =~ /^translated_from\h*:\h*(\S+)\h*$/m;
    return '';
}

# lang_status(docroot => .., conf_text => .., group => ..) -> a coverage report
# for the set: each non-source root compared to the source root, file by file.
#   { members => N, group => G,
#     source => { host, lang, root, files => N },
#     roots  => [ { host, lang, root, current, stale, missing, total,
#                   files => [ { path, status } ] } ] }
# A file is `missing` (no counterpart), `stale` (source newer than the
# translation, or a translated_from hash that no longer matches the source), or
# `current`. mtime-based by default; translated_from gives exact staleness when
# a tool writes it. members => 0/1 when there is no set to report on.
sub lang_status {
    my (%o)     = @_;
    my $docroot = $o{docroot};
    my @m       = set_members( $o{conf_text} // '', $o{group} // '' );
    return { members => scalar(@m), group => ( $o{group} // '' ), roots => [] }
        unless @m >= 2;

    my ($src)     = grep { $_->{source} } @m;
    my $src_root  = _root_path( $docroot, $src->{content_root} );
    my @src_files = _content_files($src_root);

    # Source content hashes, computed once, for translated_from comparison.
    my %src_hash;
    for my $rel (@src_files) {
        $src_hash{$rel} = _file_hash("$src_root/$rel");
    }

    my @roots;
    for my $mem (@m) {
        next if $mem->{source};
        my $root = _root_path( $docroot, $mem->{content_root} );
        my ( $current, $stale, $missing, @files ) = ( 0, 0, 0 );
        for my $rel (@src_files) {
            my $sib    = "$root/$rel";
            my $status = _file_status( "$src_root/$rel", $sib, $src_hash{$rel} );
            $current++ if $status eq 'current';
            $stale++   if $status eq 'stale';
            $missing++ if $status eq 'missing';
            push @files, { path => $rel, status => $status };
        }
        push @roots,
            {
            host    => $mem->{host},
            lang    => $mem->{lang},
            root    => $mem->{content_root},
            current => $current,
            stale   => $stale,
            missing => $missing,
            total   => scalar(@src_files),
            files   => \@files,
            };
    }

    return {
        members => scalar(@m),
        group   => ( $o{group} // '' ),
        source  => {
            host  => $src->{host},
            lang  => $src->{lang},
            root  => $src->{content_root},
            files => scalar(@src_files),
        },
        roots => \@roots,
    };
}

sub _file_hash {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    my $bytes = do { local $/; <$fh> };
    close $fh;
    return sha256_hex($bytes);
}

# Compare one source file to its sibling. translated_from (when the sibling
# carries it) is authoritative: matching the source hash => current, mismatch =>
# stale. Otherwise fall back to mtime (source newer => stale).
sub _file_status {
    my ( $src, $sib, $src_hash ) = @_;
    return 'missing' unless -f $sib;

    my $tf = _translated_from($sib);
    if ( length $tf ) {
        return ( $tf eq $src_hash ) ? 'current' : 'stale';
    }

    my $src_mtime = ( stat $src )[9] // 0;
    my $sib_mtime = ( stat $sib )[9] // 0;
    return ( $src_mtime > $sib_mtime ) ? 'stale' : 'current';
}

1;

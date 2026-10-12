package main;

# lazysite-processor/ct-cache.pm - the processor's page cache writers.
#
# HOLDS   ct_cache_path($base), write_ct($base, $ct), read_ct($base): a page
#         whose content type is not text/html keeps it beside the cache in
#         $CT_CACHE_DIR/<base with / as :>.ct; write_html($path, $page): the
#         cached page, written atomically (tempfile + rename), refused when
#         empty or outside the docroot.
# OWNS    what a cache hit reads back: the cached bytes and their content type.
# CALLS   _path_under, _cache_umask, _draft_requested, log_event
#         (lazysite-processor.pl and request.pm);
#         make_path, dirname, realpath (imported by the script's `use`).
# READS   $CT_CACHE_DIR, $DOCROOT (the script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S6). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $CT_CACHE_DIR, $DOCROOT );

# --- Content type cache ---

sub ct_cache_path {
    my ($base) = @_;
    my $key = $base;
    $key =~ s{/}{:}g;
    return "$CT_CACHE_DIR/$key.ct";
}

sub write_ct {
    my ( $base, $content_type ) = @_;
    return if _draft_requested();    # SM1030: a draft render writes nothing

    # Default or undef content type - clean stale .ct if present
    if ( !defined $content_type || $content_type eq 'text/html; charset=utf-8' ) {
        my $ct_path = ct_cache_path($base);
        unlink $ct_path if -f $ct_path;
        return;
    }

    make_path($CT_CACHE_DIR) unless -d $CT_CACHE_DIR;

    my $ct_path = ct_cache_path($base);
    open( my $fh, '>:utf8', $ct_path ) or do {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "cannot write content type cache", path => $ct_path, error => $! );
        return;
    };
    print $fh $content_type;
    close $fh;
}

sub read_ct {
    my ($base) = @_;
    my $ct_path = ct_cache_path($base);
    return unless -f $ct_path;
    open( my $fh, '<:utf8', $ct_path ) or return;
    my $ct = <$fh>;
    close $fh;
    $ct =~ s/^\s+|\s+$//g if defined $ct;
    return $ct || undef;
}

sub write_html {
    my ( $html_path, $page ) = @_;
    return if _draft_requested();    # SM1030: a draft render writes nothing

    # Skip cache write if LAZYSITE_NOCACHE is set
    return if $ENV{LAZYSITE_NOCACHE};

    # Refuse to write zero-byte content - protects against empty cache
    # files that would permanently block regeneration via DirectoryIndex
    unless ( length($page) ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "refusing zero-byte cache write", path => $html_path );
        return;
    }

    # Verify html_path resolves within docroot - guard against symlink attacks (S1)
    # Use the parent directory for the check since the file may not exist yet.
    # Note: narrow TOCTOU gap exists between this check and the subsequent open() -
    # a symlink created after the check would not be caught. O_NOFOLLOW via sysopen
    # would close this gap but adds complexity not warranted in this deployment context.
    my $check_path = -e $html_path ? $html_path : dirname($html_path);
    # SM110: an alias host's first write targets a slot directory that does
    # not exist yet (lazysite/cache/hosts/<host>/...) - walk up to the
    # nearest EXISTING ancestor for the containment check. The missing
    # segments are created below by make_path as real directories, so the
    # symlink guard's strength is unchanged.
    $check_path = dirname($check_path)
        while !-e $check_path && length($check_path) > 1;
    my $real = realpath($check_path);
    if ( !_path_under( $real, $DOCROOT ) ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "cache path outside docroot", path => $html_path );
        return;
    }

    my $dir = dirname($html_path);
    unless ( -d $dir ) {
        make_path($dir);
        # Set group to match docroot and apply setgid bit so new files
        # and subdirectories inherit the group automatically.
        my $gid = ( stat($DOCROOT) )[5];
        chown -1, $gid, $dir;
        chmod 0o775 | 0o2000, $dir;    # L-8: explicit octal; 0o2000 = setgid
    }

    # P-5: atomic write via tempfile + rename so readers never see a torn
    # file. $html_path.tmp.$$ is pid-scoped to avoid concurrent writers
    # collapsing on the same temp name.
    #
    # Mixed identities: refreshes go through rename (a DIRECTORY write, so a
    # 0644 file from the other identity never blocks them - no stale-cache
    # risk), but keep the files group-writable anyway (_cache_umask) so both
    # the site user's tooling and the www-data CGI can manage each other's
    # cache entries in place on a group-shared docroot.
    my $old_umask = _cache_umask();
    my $tmp       = "$html_path.tmp.$$";
    open( my $fh, '>:utf8', $tmp ) or do {
        umask $old_umask;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot write cache tempfile', path => $tmp, error => $! );
        return;
    };
    # SM020 checked-write pattern (review D5): a failed print surfaces as a
    # failed close (buffer flush). Without this check, a disk-full mid-write
    # renamed a TRUNCATED tempfile into place and the torn page was then
    # served from cache. Fail closed: drop the tempfile, keep the old cache.
    my $wrote = print {$fh} $page;
    umask $old_umask;    # tempfile minted; restore before the exit paths
    unless ( close($fh) && $wrote ) {
        my $err = $!;
        unlink $tmp;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cache write failed, tempfile dropped', path => $tmp, error => $err );
        return;
    }
    unless ( rename $tmp, $html_path ) {
        my $err = $!;
        unlink $tmp;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot rename cache tempfile', path => $html_path, error => $err );
        return;
    }
}

1;

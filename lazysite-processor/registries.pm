package main;

# lazysite-processor/registries.pm - the page scan and the generated registries.
#
# HOLDS   resolve_scan(): the `scan:` source a page names, with
#         _scan_parse_modifiers, _scan_collect_files, _page_date, _page_url,
#         _scan_limit (the site's cap, P9), _front_matter_reserved (the
#         engine's front-matter keys, shared with the page's own stash) and
#         _scan_page_unreadable (the log line
#         for a page a walk leaves out, SM976 Q15h); scan_pages(), the walk
#         the registries are built from; update_registries() and its P-3 memo of whether any
#         registry template exists; _feed_dates; the registry serving path -
#         _serve_registry, _registry_cache_path, _registry_ct, _registry_stale
#         and _regenerate_registries_once (the one regenerator, SM389, under a
#         lock).
# OWNS    what a scan lists and in what order; where a registry is cached and
#         when it is regenerated; the content type it is served as.
# CALLS   parse_yaml_front_matter, _scan_hidden, _registry_hidden, _scan_scalar,
#         peek_search_default, peek_conf_key, _language_set, resolve_site_vars,
#         confine_content_root, _content_rel, _private_twin, _path_under_content,
#         _declared_content_roots, _conf_value, _security_headers (its own
#         status line), _tt_dep, _cache_umask, read_file, log_event (the script
#         and its parts); Template->new; dirname, realpath, make_path and the
#         Fcntl LOCK_* constants (imported by the script's `use`, before its
#         parts load; the constants written as calls, so the part compiles alone).
# READS   $DOCROOT, $LAZYSITE_DIR, $REGISTRY_DIR, $REGISTRY_CACHE_DIR,
#         $REGISTRY_TTL, $REQUEST_CROOT, $TT_COMPILE_DIR, %ACCESS_REC (the
#         script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S15). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $REGISTRY_DIR, $REGISTRY_CACHE_DIR, $REGISTRY_TTL, $REQUEST_CROOT, $TT_COMPILE_DIR, %ACCESS_REC );

# --- Scan and registries ---
#
# The reserved front-matter keys, the scan: source, the registry regenerator and
# its serving path, scan_pages, and the TT helpers they share.

# SM459: the front-matter keys the ENGINE owns.
#
# Shared by the page scan and the page's own stash, deliberately. They used to
# disagree: a custom key was visible to a SCAN of the page and invisible to the
# page's own template, so an author wanting one fact in both places wrote it
# twice - once top-level for the index, once inside tt_page_var for their own
# layout - and the two copies drifted with nothing comparing them. That is the
# duplication the metadata exists to remove.
#
# One list, one place. Two copies of a reserved list is the same defect one
# level up, and this programme has met it twice already (SM435, SM457).
#
# SM522: a SUB, not a file-scoped hash. `our %FRONT_MATTER_RESERVED = ...`
# sat here, below the dispatch, and was still EMPTY when a CGI or FastCGI
# request was served - the SM293 shape with `our` in place of `my` - so a
# page's `auth:` and `layout:` reached the stash as page_auth / page_layout
# and the scan carried them as custom keys. A sub is initialised at call
# time and cannot be too early (t/lint/39).
sub _front_matter_reserved {
    return { map { $_ => 1 } qw(
            url title subtitle date tags excerpt searchable path
            layout theme auth register search meta_title meta_desc ) };
}

# The scan modifiers, parsed off the front of the pattern (PR-6). Lifted out
# of resolve_scan verbatim; it still STRIPS what it parses, which is why it
# takes the pattern by reference - the remaining text is the glob.
sub _scan_parse_modifiers {
    my ($pattern_ref) = @_;

    # Parse filter modifiers: "filter=FIELD:VALUE" (may repeat)
    my @filters;
    while ( $$pattern_ref =~ s/\s+filter=(\w+):([^\s]+)// ) {
        push @filters, { field => $1, value => $2 };
    }

    # Parse sort modifier: "sort=FIELD DIRECTION"
    my $sort_field = 'filename';
    my $sort_dir   = 'asc';
    if ( $$pattern_ref =~ s/\s+sort=(\w+)(?:\s+(asc|desc))?//i ) {
        $sort_field = lc($1);
        $sort_dir   = lc($2) if defined $2;
        # date/title/filename are the built-ins; any other identifier sorts on the
        # matching (passed-through) custom front-matter key, e.g. sort=order.
        $sort_field = 'filename' unless $sort_field =~ /^\w+$/;
    }

    return ( \@filters, $sort_field, $sort_dir );
}

# The files a scan pattern reaches, capped and deduplicated (PR-6). Lifted out
# of resolve_scan verbatim: same roots, same walk, same private-wins dedupe,
# the cap the caller passes (P9: the site's scan_limit, 200 by default) in the
# same order, and the same _tt_dep calls on the way.
sub _scan_collect_files {
    my ( $pattern, $scan_root, $excl, $limit ) = @_;

    # SM460: SEARCH THE PRIVATE STORE TOO.
    #
    # Gating MOVES content out of the docroot (SM286), so a scan rooted at the
    # docroot found nothing inside a protected section - and rendered a page
    # that listed nothing, successfully. Not an error, not a warning: an author
    # sees an empty list and reasonably concludes their content is missing or
    # their pattern is wrong. It removed scan-driven indexes - how blog
    # listings, feature indexes and library pages are built - from protected
    # areas entirely.
    #
    # SAFE BECAUSE THE FILTER ALREADY EXPECTED THIS. _scan_should_skip keys
    # each entry through _content_rel precisely "so a page resolved from the
    # private store is keyed and checked rather than skipping the branch and
    # being listed" - the ACL gate was written for private entries and never
    # received any. Finding them was the missing half, not the gating.
    #
    # PRIVATE WINS on a collision, the same rule Private::resolve documents: if
    # a stray public copy survives a move, listing the governed copy keeps the
    # ACL applying while stray_public() can still report the leak.
    my @roots     = ($scan_root);
    my $priv_root = _private_twin($scan_root);
    push @roots, $priv_root
        if defined $priv_root && $priv_root ne $scan_root && -d $priv_root;

    my @files;
    for my $root (@roots) {
        my $fs_pattern = $root . $pattern;
        if ( $fs_pattern =~ m{\*\*} ) {
            # Recursive glob: expand ** by walking directories
            # Split pattern into base dir and file glob parts
            my ( $base, $rest ) = $fs_pattern =~ m{^(.*?)/\*\*/(.*)$};
            if ( defined $base && defined $rest && -d $base ) {
                my $file_re = $rest;
                $file_re =~ s/\./\\./g;
                $file_re =~ s/\*/.*/g;
                $file_re = qr/\A${file_re}\z/;
                my @queue = ($base);
                while ( my $dir = shift @queue ) {
                    opendir( my $dh, $dir ) or next;
                    # SM311: the directory itself. A file ADDED or DELETED leaves no
                    # file to stat, but moves its directory's mtime - so the walked
                    # directories are what makes add and delete visible, and the
                    # matched files below are what makes an EDIT visible. Both are
                    # needed; neither is sufficient.
                    _tt_dep($dir);
                    for my $entry ( readdir($dh) ) {
                        next if $entry =~ /^\./;
                        my $path = "$dir/$entry";
                        if ( -d $path ) {
                            # SM151: don't follow symlinked dirs - a symlink could
                            # cycle (hanging the walk) or escape the content root
                            # (leaking a sibling domain's pages into search).
                            next if -l $path;
                            # §7: never descend into ANOTHER domain's content root,
                            # so a bare-docroot search excludes client subtrees.
                            next if $excl->{$path} && $path ne $base;
                            push @queue, $path;
                        }
                        elsif ( $entry =~ $file_re ) {
                            push @files, $path;
                        }
                    }
                    closedir($dh);
                }
            }
        }
        else {
            push @files, glob($fs_pattern);
            # SM311: same reasoning, one level - the directory the glob names.
            _tt_dep( dirname($fs_pattern) );
        }
    }

    # SM460: private wins when a path exists in both trees. Keyed on the
    # docroot-relative name so the two spellings of one page collapse to one
    # entry rather than listing it twice.
    {
        my %by_key;
        for my $f (@files) {
            my $key = _content_rel($f);
            $key = $f unless defined $key;
            # A later root (the private one) replaces an earlier public twin.
            $by_key{$key} = $f;
        }
        # SORTED, because the 200-file cap below takes a prefix and hash
        # order is randomised per process - an uncapped list would come out
        # right and a capped one would hold a different 200 pages each render.
        @files = sort values %by_key;
    }

    # P9: the cap is the caller's - resolve_scan applies the site's scan_limit
    # and counts what lies past it. Without one (no caller passes none today)
    # the list is whole.
    @files = @files[ 0 .. $limit - 1 ] if defined $limit && @files > $limit;

    return @files;
}

# P9 (WORK-PLAN-0154): HOW MANY PAGES A SCAN READS, the site's to set.
#
# A scan reads every page it lists, so it is capped; the cap was a literal 200
# that nothing documented, and a 1,745-post site rendered 200 with no sign of
# the rest. `scan_limit:` in lazysite.conf sets it; anything but a positive
# whole number is the default, said in the log.
sub _scan_limit {
    my $v = peek_conf_key('scan_limit');
    return 200 unless defined $v && length $v;
    return 0 + $v if $v =~ /\A[1-9]\d{0,6}\z/;
    log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
        'scan_limit is not a positive whole number - using 200', value => $v );
    return 200;
}

# A page's date: the front matter's, else the file's mtime as YYYY-MM-DD
# (PR-5). resolve_scan and scan_pages carried identical copies of this.
sub _page_date {
    my ( $meta, $path ) = @_;
    my $date = $meta->{date} || '';
    unless ($date) {
        my @st = stat($path);
        if (@st) {
            my @t = localtime( $st[9] );
            $date = sprintf( "%04d-%02d-%02d", $t[5] + 1900, $t[4] + 1, $t[3] );
        }
    }
    return $date;
}

# A page's URL: the path with the scanned root, the .md suffix and a trailing
# /index stripped, in that order (PR-5). The other half of the same pair -
# resolve_scan feeds it a path already mapped back to its PUBLIC spelling
# (SM460/SM463), scan_pages feeds it the path it walked; the strip is the same.
sub _page_url {
    my ( $path, $root ) = @_;
    ( my $url = $path ) =~ s{^\Q$root\E}{};
    $url                =~ s/\.md$//;
    $url                =~ s{/index$}{/};
    return $url;
}

# SM976 Q15h ("Refuse + walker skips"): the log line for a page a walk leaves
# out because its front matter - or, Q15i, the body resolve_scan's excerpt
# reads - cannot be read. Docroot-relative, as a page is named everywhere else
# in the log.
sub _scan_page_unreadable {
    my ( $path, $why, $part ) = @_;
    $part //= 'front matter';
    ( my $rel = $path ) =~ s{^\Q$DOCROOT\E/*}{};
    $why =~ s/\s+at \S+ line \d+.*//s;
    log_event( 'WARN', 'scan', "a page whose $part cannot be read is left out", page => $rel, error => $why );
    return;
}

sub resolve_scan {
    my ($pattern) = @_;

    my ( $filters, $sort_field, $sort_dir ) = _scan_parse_modifiers( \$pattern );
    my @filters = @$filters;

    # Pattern must be root-relative starting with /
    return [] unless $pattern =~ m{^/};

    # SM151: box the scan to the requesting domain's content root (the domain's
    # '/'), so search on one domain never returns another's pages. Falls back to
    # the docroot for the primary host / when no content_root is in effect.
    my $scan_root = $REQUEST_CROOT // $DOCROOT;
    my $excl      = _declared_content_roots();    # §7: other domains' roots

    # Build filesystem glob pattern
    my $fs_pattern = $scan_root . $pattern;

    # Limit to .md files only
    return [] unless $fs_pattern =~ /\.md$/;

    # P9: every file the pattern matches, then the site's cap - a prefix in
    # file order, as before, so the same pages are listed on every render.
    my @all   = _scan_collect_files( $pattern, $scan_root, $excl );
    my $limit = _scan_limit();
    my @files = @all > $limit ? @all[ 0 .. $limit - 1 ] : @all;
    my $total = 0;    # P9: pages matched that this reader may see

    # Read site search default once if any filter references searchable
    my $search_default;

    # PO-1: two loop invariants, hoisted.
    #
    # EQUIVALENCE. Both were recomputed once per scanned file and neither can
    # change while the loop runs: _private_twin is a pure function of
    # $scan_root, the private root and $DOCROOT, and the loop body writes none
    # of them; _front_matter_reserved returns a fresh hash built from a literal
    # qw list, and the loop only ever READS $reserved{$k}. So each call returned
    # what the one before it returned, 200 times at the cap.
    my $priv_scan = _private_twin($scan_root);
    my %reserved  = %{ _front_matter_reserved() };

    my @pages;
    # @files is already sorted (the private-wins dedupe above sorts it) and the
    # only thing between here and there is the 200-file cap, which takes a
    # prefix - so a second sort would return the same list in the same order.
    for my $path (@files) {
        # Realpath check - confined to the scan root (the domain's content root,
        # or the docroot), so a symlinked file cannot escape the domain (SM151).
        my $real = realpath($path);
        # SM460: _path_under_content, not _path_under - it accepts the scan
        # root OR its private twin, each boundary-safe, which is the same
        # two-strict-checks shape SM458 used rather than one loosened test.
        next unless _path_under_content( $real, $scan_root );
        next unless -f $real;

        # SM311: recorded BEFORE the visibility filter, deliberately. A page that
        # becomes visible - a draft published, an ACL lifted - is an edit to a
        # file that already existed, so no directory mtime moves and the page
        # would never appear in a cached listing. Recording only what was SHOWN
        # would make the listing stale in exactly the case the author is watching
        # for. The path is already public knowledge to the render; this records
        # what was READ, not what was displayed.
        _tt_dep($real);

        # SM268 H13: never list what this requester may not read.
        next if _scan_hidden($real);
        $total++;

        # Read front matter. SM976 Q15h ("Refuse + walker skips"): a page whose
        # reading dies (bytes that are not UTF-8, put there by git or SSH) is
        # left out and logged - it renders nothing itself - so one such page
        # cannot fail every page whose scan reaches it.
        my $raw = read_file($path);
        my ($meta) = eval { parse_yaml_front_matter($raw) };
        if ( my $why = $@ ) {
            _scan_page_unreadable( $path, $why );
            next;
        }

        # Derive URL relative to the scan root, so a boxed domain's results
        # carry that domain's own '/'-relative paths (SM151).
        #
        # SM460/SM463: map a private-store path back to its PUBLIC spelling
        # first. This strip is a bare prefix, and the private root begins with
        # the scan root - so a page found in the private tree came out as
        # "-lazysite-private/intranet/a", which is both a broken link and a
        # disclosure of the store's naming. Widening the search without fixing
        # the derivation would have introduced that fault rather than found it;
        # SM286's own header warns that resolution and key derivation must
        # change together, and this is the derivation half.
        #
        # Boundary-safe (eq or "$root/"), so a sibling directory whose name
        # merely starts with the private root's is untouched.
        my $url_src = $path;
        if ( defined $priv_scan
            && length $priv_scan
            && ( $url_src eq $priv_scan
                || index( $url_src, "$priv_scan/" ) == 0 ) )
        {
            $url_src = $scan_root . substr( $url_src, length($priv_scan) );
        }
        my $url = _page_url( $url_src, $scan_root );

        # Date from front matter or mtime
        my $date = _page_date( $meta, $path );

        # Parse tags from front matter (YAML list, comma-separated, or single value)
        my $tags_raw = $meta->{tags} // '';
        my @tags;
        if ( ref $tags_raw eq 'ARRAY' ) {
            @tags = @$tags_raw;
        }
        elsif ($tags_raw) {
            @tags = map { s/^\s+|\s+$//gr } split /,/, $tags_raw;
        }

        # Extract raw body for search excerpt. SM976 Q15i (ruled 2026-10-09,
        # "Same rule"): the excerpt reads the BODY, which the front-matter guard
        # above never parsed - a page whose front matter is UTF-8 and whose body
        # is not died here, and every page whose scan reached it answered 500.
        # Left out and logged, as for its front matter.
        my $excerpt = '';
        eval {
            if ( $raw =~ /^---\n.*?\n---\n(.+)/s ) {
                $excerpt = $1;
                # Drop <style>/<script> blocks and HTML comments so their CSS/JS/markup
                # never leaks into the public search excerpt (a page often opens with an
                # inline <style> block).
                $excerpt =~ s{<style\b[^>]*>.*?</style>}{ }gis;
                $excerpt =~ s{<script\b[^>]*>.*?</script>}{ }gis;
                $excerpt =~ s{<!--.*?-->}{ }gs;
                $excerpt =~ s/^\s+|\s+$//g;
                $excerpt = substr( $excerpt, 0, 500 ) if length($excerpt) > 500;
            }
            1;
        } or do {
            _scan_page_unreadable( $path, $@, 'body' );
            next;
        };

        # Determine searchable status
        my $search_val = $meta->{search} // '';
        my $searchable;
        if ( $search_val =~ /^true$/i ) {
            $searchable = 1;
        }
        elsif ( $search_val =~ /^false$/i ) {
            $searchable = 0;
        }
        else {
            $search_default //= peek_search_default();
            $searchable = $search_default;
        }

        # Pass through custom (non-computed, non-control) front-matter keys so a
        # scanned/registry card is self-describing - [% p.accent %], [% p.kind %],
        # [% p.demo %], [% p.order %] - instead of smuggling data through tags.
        # Computed fields below take precedence; control/internal keys are excluded;
        # surrounding quotes and TT markers are stripped from scalar values.
        my %custom;
        for my $k ( keys %$meta ) {
            next if $reserved{$k} || $k =~ /^(?:tt_|_)/;
            my $v = $meta->{$k};
            if    ( ref $v eq 'ARRAY' ) { $custom{$k} = [ map { _scan_scalar($_) } @$v ] }
            elsif ( !ref $v )           { $custom{$k} = _scan_scalar($v) }
        }

        push @pages, {
            %custom,
            url      => $url,
            title    => $meta->{title}    || '',
            subtitle => $meta->{subtitle} || '',

            # SM300: the description a registry should publish - the explicit
            # meta_desc when the author set one, the subtitle otherwise. Resolved
            # here so every registry template gets the same answer rather than
            # each re-deriving it.
            meta_desc  => ( $meta->{meta_desc}  // $meta->{subtitle} // '' ),
            meta_title => ( $meta->{meta_title} // $meta->{title}    // '' ),
            date       => $date,
            tags       => \@tags,
            excerpt    => $excerpt,
            searchable => $searchable,
            # Docroot-relative, never the absolute server path: this object is
            # published in the public /search-index JSON and exposed to templates
            # as [% p.path %]. Leaking /home/<user>/web/... was an info disclosure.
            path => ( $path =~ s{^\Q$DOCROOT\E}{}r ),
        };
    }

    # Apply filters
    for my $filter (@filters) {
        my $field = $filter->{field};
        my $val   = $filter->{value};

        @pages = grep {
            my $page = $_;
            my $pval = $page->{$field};

            if ( !defined $pval ) {
                0;    # field not present - exclude
            }
            elsif ( $val =~ /^>(.+)$/ ) {
                # Greater than
                ( $pval cmp $1 ) > 0;
            }
            elsif ( $val =~ /^<(.+)$/ ) {
                # Less than
                ( $pval cmp $1 ) < 0;
            }
            elsif ( ref $pval eq 'ARRAY' ) {
                # Array contains (for tags)
                grep { lc($_) eq lc($val) } @$pval;
            }
            elsif ( $val =~ /^(true|1)$/i ) {
                # Boolean true
                $pval ? 1 : 0;
            }
            elsif ( $val =~ /^(false|0)$/i ) {
                # Boolean false
                $pval ? 0 : 1;
            }
            else {
                # Exact match (case-insensitive)
                lc($pval) eq lc($val);
            }
        } @pages;
    }

    # Sort pages. date/title/filename are built-ins; any other field sorts on the
    # custom key (numeric-aware, so sort=order gives 2 before 10).
    my @sorted = sort {
        my ( $va, $vb );
        if ( $sort_field eq 'date' ) { ( $va, $vb ) = ( $a->{date}, $b->{date} ) }
        elsif ( $sort_field eq 'title' ) { ( $va, $vb ) = ( lc( $a->{title} ), lc( $b->{title} ) ) }
        elsif ( $sort_field eq 'filename' ) { ( $va, $vb ) = ( $a->{path}, $b->{path} ) }
        else {
            $va = ( defined $a->{$sort_field} && !ref $a->{$sort_field} ) ? $a->{$sort_field} : '';
            $vb = ( defined $b->{$sort_field} && !ref $b->{$sort_field} ) ? $b->{$sort_field} : '';
        }
        my $cmp = ( $va =~ /^-?\d+(?:\.\d+)?$/ && $vb =~ /^-?\d+(?:\.\d+)?$/ )
            ? ( $va <=> $vb ) : ( lc($va) cmp lc($vb) );
        $sort_dir eq 'desc' ? -$cmp : $cmp;
    } @pages;

    # P9: A CAPPED SCAN SAYS SO, and counts what it did not read. Past the cap
    # each file is held to the same two questions as a listed one - inside this
    # domain's content, and readable by this requester - so the total counts no
    # page the reader may not see and says nothing about one. `filter=` cannot
    # be asked of a page that was not read, so the total is taken before it.
    if ( @all > $limit ) {
        for my $path ( @all[ $limit .. $#all ] ) {
            my $real = realpath($path);
            next unless defined $real && _path_under_content( $real, $scan_root ) && -f $real;
            next if _scan_hidden($real);
            $total++;
        }
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            "scan: is capped - reading the first $limit of $total pages in file order; "
                . 'raise scan_limit in lazysite.conf, or render <var>_total so the page can say so',
            pattern => $pattern );
    }

    return wantarray ? ( \@sorted, $total ) : \@sorted;
}

# A registry output is stale when it is missing, or older than $REGISTRY_TTL
# (PR-12). update_registries wrote the same test out twice - once as "does
# anything here need regenerating", once as the per-template skip, spelled as
# its negation. Same stat, same comparison, same order.
#
# The two further copies on the serve path (_serve_registry and the re-check
# under the lock in _regenerate_registries_once) are LEFT INLINE deliberately:
# t/unit/plugins/16 and t/unit/processor/46 lift those two subs out of this file
# by regex and run them standalone against stubs, so a call to a helper defined
# elsewhere in the file would be an undefined subroutine in their harnesses.
sub _registry_stale {
    my ($path) = @_;
    return 1 if !-f $path;
    return ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL ? 1 : 0;
}

{
    # P-3: cache "do we have any registry templates?" at process level.
    # Most sites don't use registries; this avoids an opendir on every
    # cache-miss render.
    my $_has_registries;    # undef = not yet probed

    sub update_registries {
        # SM110/SM151: registries (sitemap, feeds, llms.txt) are generated per
        # content root. A host with its OWN content_root gets first-class
        # registries - scanned from and written INTO its subtree, with its own
        # per-host site_url - so each domain has a correct sitemap/feeds of just
        # its own pages. A host that is an alias WITHOUT a content root shares
        # the docroot (SM110 chrome-only alias); it is still skipped, or its
        # overlaid vars (site_name etc.) would bake into the docroot-shared
        # registries the primary serves. The primary host - with or without a
        # base content_root - generates as before.
        my %sv       = resolve_site_vars();
        my $root     = $DOCROOT;
        my $has_root = 0;
        if ( defined $sv{content_root} && length $sv{content_root} ) {
            my $c = confine_content_root( $DOCROOT, $sv{content_root} );
            if ( defined $c ) { $root = $c; $has_root = 1; }
        }
        return if $sv{alias_host} && !$has_root;

        if ( !defined $_has_registries ) {
            if ( -d $REGISTRY_DIR ) {
                opendir( my $dh, $REGISTRY_DIR );
                my @t = $dh ? grep { /\.tt$/ } readdir($dh) : ();
                closedir($dh) if $dh;
                $_has_registries = @t ? 1 : 0;
            }
            else {
                $_has_registries = 0;
            }
        }
        return unless $_has_registries;

        opendir( my $dh, $REGISTRY_DIR ) or return;
        my @templates = grep { /\.tt$/ } readdir($dh);
        closedir($dh);

        return unless @templates;

        # Check if any registry needs updating
        my $needs_update = 0;
        for my $tmpl (@templates) {
            ( my $output_name = $tmpl ) =~ s/\.tt$//;
            my $output_path = _registry_cache_path( $root, $output_name );
            if ( _registry_stale($output_path) ) {
                $needs_update = 1;
                last;
            }
        }
        return unless $needs_update;

        # Scan the source pages of THIS content root only (SM151), so a domain's
        # registries list just its own subtree with content-root-relative URLs.
        my @pages     = scan_pages($root);
        my %site_vars = resolve_site_vars();

        # Compile-cache dirs + .ttc files are minted during new()/process():
        # group-writable creation whichever identity renders first (_cache_umask).
        my $old_umask = _cache_umask();
        make_path($TT_COMPILE_DIR) unless -d $TT_COMPILE_DIR;
        my $tt = Template->new(
            ABSOLUTE    => 1,
            ENCODING    => 'utf8',
            EVAL_PERL   => 0,                                     # L-2
            FILTERS     => { url_safe => \&_url_safe_filter },    # SM970
            COMPILE_DIR => $TT_COMPILE_DIR,                       # P-4
            COMPILE_EXT => '.ttc',                                # P-4
        ) or do { umask $old_umask; return };

        for my $tmpl (@templates) {
            ( my $output_name = $tmpl ) =~ s/\.tt$//;
            my $output_path = _registry_cache_path( $root, $output_name );
            my $tmpl_path   = "$REGISTRY_DIR/$tmpl";

            # Check this specific registry needs updating
            next unless _registry_stale($output_path);

            # Filter pages registered for this registry
            my $registry_name = $output_name;
            my @registered    = grep {
                my $page = $_;
                grep { $_ eq $registry_name } @{ $page->{register} || [] }
            } @pages;

            # SM179 P3: for a language set, attach each page's hreflang alternates
            # so the sitemap can advertise its siblings (xhtml:link). Copy each
            # page hash before augmenting - @pages is shared across registries and
            # only the sitemap consumes `alternates`. A member whose counterpart is
            # absent carries exists=0 and the template omits it.
            if ( $registry_name eq 'sitemap.xml'
                && length( $site_vars{lang_group} // '' ) )
            {
                @registered = map {
                    +{
                        %$_,
                        alternates => [
                            _language_set(
                                ( $site_vars{alias_host} // '' ),
                                $site_vars{lang_group}, $_->{url}
                            )
                        ],
                    }
                } @registered;
            }

            # SM888 A1: A FEED DATE IS FORMATTED FOR THE FEED IT GOES INTO.
            #
            # `date: 2026-08-14` went into RSS's <pubDate> and Atom's <updated>
            # unchanged, and neither accepts it: pubDate wants RFC 822, updated
            # wants RFC 3339. A reader given a date it cannot parse shows the
            # item undated, or dates it "now" and re-sorts the feed on every
            # fetch. Not a crash, which is why every feed this project has
            # published has been wrong and looked fine.
            #
            # DONE HERE RATHER THAN IN THE TEMPLATE, and that is the whole
            # reach of the fix: the registry templates install under bucket
            # `seed`, so an upgrade never replaces them. A site installed a year
            # ago keeps the template it was given. Fixing starter/ alone would
            # fix new sites and leave every feed that has a subscriber wrong.
            #
            # The raw value stays available as `date_raw` for a site that has
            # written its own template around it.
            my $feed_updated = '';
            if ( $registry_name eq 'feed.rss' || $registry_name eq 'feed.atom' ) {
                my $rss = $registry_name eq 'feed.rss';

                # SM942 FO1: NEWEST FIRST, and the sort happens HERE for the same
                # reason the date formatting does - the registry templates install
                # under bucket `seed`, so an upgrade never replaces them and a
                # template-side sort would fix new sites while leaving every feed
                # that HAS a subscriber in filename order.
                #
                # SORTED BEFORE THE MAP, which is the whole trick. The map replaces
                # `date` with the RFC 822 / RFC 3339 string, and sorting THAT orders
                # by weekday name - wrong in a way that still looks sorted, which
                # would be worse than the fault being fixed because it would look
                # deliberate. An ISO date sorts chronologically as text, so the raw
                # value is the right key.
                #
                # AND ONLY AN ISO-LOOKING VALUE IS A SORT KEY. A `date:` the engine
                # cannot parse is passed through to the feed verbatim rather than
                # invented (t/integration/102), so prose like "last Tuesday" reaches
                # here - and as a bare string it sorts ABOVE every real date, which
                # would put the one page nobody dated properly at the top of every
                # reader. Caught by 102 when this sort was first written without the
                # guard. Unparseable sorts last, with no date of its own to argue
                # about.
                my $key = sub {
                    my $d = $_[0]->{date};
                    return '' unless defined $d;
                    return $d =~ /\A\d{4}-\d{2}-\d{2}/ ? $d : '';
                };
                @registered =
                    sort { $key->($b) cmp $key->($a) } @registered;

                @registered = map {
                    my ( $r822, $r3339 ) = _feed_dates( $_->{date} );
                    my $fmt = $rss ? $r822 : $r3339;
                    +{ %$_,
                        date_raw => $_->{date},
                        ( defined $fmt ? ( date => $fmt ) : () ),
                    };
                } @registered;

                # SM942 FO3 (ruled 2026-10-02): cap the item count. A site with a
                # few hundred dated pages otherwise emits all of them on every
                # poll. 50 is the conventional ceiling and costs no current site
                # anything: the pages the cap drops stay in the sitemap, the search
                # index and every link to them - only the FEED is bounded.
                # `feed_items: 0` asks for all of them.
                my $cap = _conf_value('feed_items');
                $cap = 50 unless defined $cap && $cap =~ /\A\d+\z/;
                splice @registered, $cap if $cap && @registered > $cap;

                # The channel's own timestamp, for a template that carries
                # <lastBuildDate> or <updated>. The feed is sorted, so the newest
                # item IS the first one. Kept in a local rather than written into
                # %site_vars, which is shared with sitemap.xml and llms.txt and has
                # no business gaining a feed-only key.
                $feed_updated = @registered ? ( $registered[0]{date} // '' ) : '';
            }

            my $vars = {
                %site_vars,
                pages        => \@registered,
                feed_updated => $feed_updated,    # SM942: '' for every non-feed registry
            };

            my $output = '';
            $tt->process( $tmpl_path, $vars, \$output ) or do {
                log_event( "ERROR", "-", "registry template error", tmpl => $tmpl, error => $tt->error() );
                next;
            };

            make_path( dirname($output_path) ) unless -d dirname($output_path);
            open( my $fh, '>:utf8', $output_path ) or do {
                log_event( "WARN", "-", "cannot write registry", path => $output_path, error => $! );
                next;
            };
            print $fh $output;
            close $fh;
        }
        umask $old_umask;
    }
}    # close P-3 _has_registries memo block

# SM888 A1: one front-matter date, the two spellings the feed specifications
# require. Returns ( RFC 822, RFC 3339 ), or the empty list when the value is
# not a date this can read.
#
# THE MONTH AND DAY NAMES ARE OURS, not strftime's. %a and %b are LOCALE
# DEPENDENT, and a host with a non-English locale would publish "jeu., 14 août"
# into a feed whose specification names the English abbreviations - a fault
# that appears on some hosts and not others, which is the worst kind to chase.
#
# AN UNPARSEABLE DATE IS PASSED THROUGH, not replaced. Substituting "now" would
# make the feed re-sort itself on every fetch and tell the sysop nothing; the
# page's front matter is where it is wrong and where it should be fixed.
# THE TABLES LIVE INSIDE THE SUB, and that is not a style choice. Written as
# file-scope `my @DOW = (...)` in an enclosing block, they are EMPTY here: this
# is a CGI whose execution reaches the request handler thousands of lines
# above, so a runtime assignment down here never runs before the sub is called.
# The first cut published "<pubDate>, 14  2026 00:00:00 +0000</pubDate>" - a
# date with no day and no month, which is worse than the raw value it replaced.
# Twelve strings on a path that runs when a feed regenerates cost nothing.
{

    sub _feed_dates {
        my ($raw) = @_;
        my @DOW   = qw(Sun Mon Tue Wed Thu Fri Sat);
        my @MON   = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        return () unless defined $raw && length $raw;
        my ( $y, $m, $d, $H, $M, $S ) = $raw =~ m{
            \A \s* (\d{4}) - (\d{2}) - (\d{2})
            (?: [T ] (\d{2}) : (\d{2}) (?: : (\d{2}) )? )?
        }x or return ();
        $H //= 0;
        $M //= 0;
        $S //= 0;
        return () if $m < 1 || $m > 12 || $d < 1 || $d > 31;

        require Time::Local;
        my $epoch = eval {
            Time::Local->can('timegm_modern')
                ? Time::Local::timegm_modern( $S, $M, $H, $d, $m - 1, $y )
                : Time::Local::timegm( $S, $M, $H, $d, $m - 1, $y - 1900 );
        };
        return () unless defined $epoch;

        my @g = gmtime($epoch);
        return (
            sprintf(
                '%s, %02d %s %04d %02d:%02d:%02d +0000',
                $DOW[ $g[6] ], $g[3], $MON[ $g[4] ], $g[5] + 1900,
                $g[2],         $g[1], $g[0]
            ),
            sprintf(
                '%04d-%02d-%02dT%02d:%02d:%02dZ',
                $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]
            ),
        );
    }
}

# SM293 step 3: where a generated registry is cached, per content root.
#
# Keyed on the content root's path RELATIVE to the docroot, so a multi-domain
# instance keeps each domain's sitemap separate. That separation is the whole of
# SM248: one shared file at the docroot root meant a secondary domain was served
# the primary's sitemap, because the front end resolved the file before the
# engine was asked which domain had been requested.
sub _registry_cache_path {
    my ( $root, $name ) = @_;
    my $key = $root;
    $key = '' unless defined $key;
    $key =~ s{\A\Q$DOCROOT\E/?}{};
    $key =~ s{[^A-Za-z0-9._-]+}{_}g;
    $key = '_root' unless length $key;
    return "$REGISTRY_CACHE_DIR/$key/$name";
}

# The content types the generated registries are served as. Named explicitly:
# guessing from the extension would serve feed.atom as application/octet-stream,
# and get llms.txt right only by accident.
#
# A SUB, not a file-scoped `my` hash. This file runs its main body near the TOP,
# so a `my %REGISTRY_CT = (...)` declared down here is still EMPTY when the
# request is served - every registry name looked unknown and every fetch 404'd.
# SM285 shipped exactly this bug with `my @PROBE_EXT`, where it made a security
# probe pass by testing nothing; the comment there says so, and I wrote this one
# the same way anyway. The sub is initialised at call time and cannot be early.
sub _registry_ct {
    my ($name) = @_;
    my %ct = (
        'sitemap.xml' => 'application/xml; charset=utf-8',
        'llms.txt'    => 'text/plain; charset=utf-8',
        'feed.rss'    => 'application/rss+xml; charset=utf-8',
        'feed.atom'   => 'application/atom+xml; charset=utf-8',
    );
    return $ct{$name} if $ct{$name};

    # A registry is any template an operator drops in - `search-index` is the
    # documented example - so the four shipped names cannot be the whole list.
    # The first version of this served only those four, which quietly removed
    # the ability to define your own: the custom template still rendered, and
    # the result was no longer written anywhere nor reachable.
    return 'application/xml; charset=utf-8'      if $name =~ /\.xml\z/;
    return 'application/json; charset=utf-8'     if $name =~ /\.json\z/;
    return 'application/rss+xml; charset=utf-8'  if $name =~ /\.rss\z/;
    return 'application/atom+xml; charset=utf-8' if $name =~ /\.atom\z/;
    return 'text/plain; charset=utf-8';
}

# Serve a generated registry, if this URI names one. Returns 1 when handled.
#
# Generated on request and cached for $REGISTRY_TTL, which the operator chose
# knowing a registry may be a little stale: a sitemap that lags a few hours is
# not a defect, and it buys a high-demand file that never sits in the document
# root at all.
sub _serve_registry {
    my ($uri) = @_;
    return 0 unless defined $uri;
    ( my $name = $uri ) =~ s{\A.*/}{};
    my $ct = _registry_ct($name);
    return 0 unless length $name && $ct;

    # Only if this site actually ships that registry's template - otherwise a
    # request for /sitemap.xml on a site with no registries should 404 as it
    # always did, not answer with an empty document.
    return 0 unless -f "$REGISTRY_DIR/$name.tt";

    my %sv   = resolve_site_vars();
    my $root = $DOCROOT;
    if ( defined $sv{content_root} && length $sv{content_root} ) {
        my $c = confine_content_root( $DOCROOT, $sv{content_root} );
        $root = $c if defined $c;
    }

    # A sysop who wrote their OWN sitemap.xml as content keeps it. In
    # production the front end serves that file and the engine never sees the
    # request, but the guarantee must not depend on which route the request
    # took - the dev server and any ACL-store site come through here.
    return 0 if -f "$root/$name";

    my $path = _registry_cache_path( $root, $name );
    _regenerate_registries_once( $path, $uri )
        if !-f $path || ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL;

    open my $fh, '<:utf8', $path or return 0;
    my $body = do { local $/; <$fh> };
    close $fh;

    # SM389: and it is a served request, so it goes in the access log. Registry
    # hits were the one served path that recorded nothing at all - a crawler
    # fetching sitemap.xml every few hours was invisible, which is exactly the
    # traffic a sysop would want to see. Its own channel rather than 'page':
    # a sitemap fetch is not a page view and must not inflate one.
    $ACCESS_REC{s}  = 200;
    $ACCESS_REC{ch} = 'registry';

    # An explicit Status line, like every other served path here. CGI defaults
    # to 200 without one, so omitting it works and then reads as a missing
    # status to anything asserting on the response.
    print "Status: 200 OK\r\n";
    print "Content-Type: $ct\r\n";
    print "$_\r\n" for _security_headers();    # SM381
    print "Cache-Control: public, max-age=$REGISTRY_TTL\r\n\r\n";
    print $body;
    return 1;
}

# SM389: one regenerator, not N.
#
# TTL expiry is a stampede. The cached file goes stale at an INSTANT, and every
# request arriving after that instant saw the same old mtime and ran
# update_registries() - a full site scan each - concurrently. The cost scales
# with traffic precisely when traffic is what made it stale, and a site big
# enough for the scan to be slow is a site with enough requests to pile up.
#
# A non-blocking lock picks ONE. The losers do not wait and do not regenerate:
# they serve the stale file, which is the entire premise of a TTL cache and is
# what the sysop accepted by setting a TTL at all. A few more seconds of
# staleness on a sitemap is not a defect; N concurrent site scans is.
#
# The one case a loser cannot serve through is no file at all - a cold start, or
# the first request after a cache clear. There it waits for the winner, because
# there is nothing to be stale WITH.
sub _regenerate_registries_once {
    my ( $path, $uri ) = @_;

    my $regen = sub {
        eval { update_registries() };
        log_event( 'WARN', $uri, 'registry generation failed', error => $@ ) if $@;
    };

    # No lock file, no lock - fall back to the old behaviour rather than
    # declining to serve. A herd is a cost; not answering is a fault.
    open my $lh, '>>', "$path.lock" or return $regen->();

    if ( flock $lh, LOCK_EX() | LOCK_NB() ) {

        # Re-check UNDER the lock. A winner may have finished between the stat
        # that sent us here and the lock we just took, and regenerating again on
        # its fresh output is the same herd in slow motion.
        $regen->()
            if !-f $path || ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL;
        flock $lh, LOCK_UN();
        close $lh;
        return;
    }

    # Somebody else is regenerating.
    if ( -f $path ) { close $lh; return }    # serve it stale

    # Nothing to serve. Wait for the winner rather than joining it - a blocking
    # lock here is one process waiting, where the alternative is N scans.
    flock $lh, LOCK_EX();
    flock $lh, LOCK_UN();
    close $lh;
    return;
}

sub scan_pages {
    # SM151: scan a specific content root (default: the docroot). URLs are
    # derived relative to $root so a per-domain registry carries the domain's
    # own '/'-relative links.
    my ($root) = @_;
    $root //= $DOCROOT;
    my $excl = _declared_content_roots();    # §7: other domains' roots

    my @pages;

    # Find all .md and .url files recursively under the root
    my @queue = ($root);
    while ( my $dir = shift @queue ) {
        opendir( my $dh, $dir ) or next;
        for my $entry ( sort readdir($dh) ) {
            next if $entry =~ /^\./;
            next if $entry =~ /\.brief$/;    # SM073: briefs never index
            my $path = "$dir/$entry";
            # Never index the lazysite/ management tree (auth, templates,
            # cache); relevant when $root is the bare docroot.
            next if $path eq $LAZYSITE_DIR;
            if ( -d $path ) {
                # SM151: do not follow symlinked directories - a symlink can
                # form a cycle (which would hang the walk) or escape the
                # content root (which would leak a sibling domain's pages into
                # this domain's registries). Page serving is realpath-confined
                # (P1); the scanner simply refuses to traverse symlinked dirs.
                next if -l $path;
                # §7: never descend into ANOTHER domain's content root - a
                # bare-docroot host's sitemap must not enumerate client subtrees.
                next if $excl->{$path} && $path ne $root;
                push @queue, $path;
            }
            elsif ( $entry =~ /\.(md|url)$/ ) {
                my $raw;
                if ( $entry =~ /\.md$/ ) {
                    $raw = read_file($path);
                }
                else {
                    # For .url files read the cached .html front matter isn't
                    # available - read from remote is too expensive, skip register
                    # unless a local .md sidecar exists
                    next;
                }

                # SM976 Q15h: a page whose reading dies registers nothing, logged.
                my ($meta) = eval { parse_yaml_front_matter($raw) };
                if ( my $why = $@ ) {
                    _scan_page_unreadable( $path, $why );
                    next;
                }
                next unless $meta->{register};

                # SM181 + SM268 H13: a registry (sitemap.xml, llms.txt, the
                # feeds) is a STATIC artefact written to disk and served to
                # anyone, so the question is not "may this requester read it"
                # but "is it public at all". Draft and gated are two answers to
                # that one question and both live in _registry_hidden.
                next if _registry_hidden($path);

                # Get date from front matter or file mtime
                my $date = _page_date( $meta, $path );

                # Derive URL from path, relative to the scanned root (SM151)
                my $url = _page_url( $path, $root );

                push @pages, {
                    url      => $url,
                    title    => $meta->{title}    || '',
                    subtitle => $meta->{subtitle} || '',
                    date     => $date,
                    register => $meta->{register} || [],

                    # SM300: the description a registry publishes - the explicit
                    # meta_desc when the author set one, the subtitle otherwise.
                    # Resolved once here so every registry template gets the same
                    # answer instead of each re-deriving the fallback.
                    meta_desc =>
                        ( $meta->{meta_desc} // $meta->{subtitle} // '' ),
                    meta_title =>
                        ( $meta->{meta_title} // $meta->{title} // '' ),
                };
            }
        }
        closedir($dh);
    }

    return @pages;
}

1;

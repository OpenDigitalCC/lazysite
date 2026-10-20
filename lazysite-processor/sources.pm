package main;

# lazysite-processor/sources.pm - what a page's variables are made of.
#
# HOLDS   resolve_tt_vars(): the conf's and a page's tt_page_var definitions
#         resolved - literals, ${VAR} env interpolation through the allowlist
#         (interpolate_env, _env_value: the SM926 copy t/lint/203 pins), and the
#         url:, json:, db:, odoo: and scan: sources (resolve_json, resolve_db with
#         _db_empty and _escape_db_rows, resolve_odoo with _odoo_inert,
#         _resolve_content_path, _language_set);
#         _canonical_of, the domain an alias host renders from (P14, the marked
#         copy t/lint/224 drives);
#         the dependency record a cached page is checked against (_tt_dep,
#         deps_cache_path, write_deps, deps_fresh); the nav file and its parse
#         (_nav_file_for, _site_path: the module-free copy t/lint/37 drives,
#         parse_nav); the conf peeks (peek_conf_key, peek_search_default); and
#         the scan's identity and visibility tests (_scan_identity,
#         _scan_hidden, _registry_hidden, _scan_scalar).
# OWNS    which sources a page may name and what each resolves to; which files
#         a cached page depends on; who a scan is asked for.
# CALLS   fetch_url, read_file, log_event, resolve_scan, _request_host,
#         _draft_requested,
#         _path_under, _acl_allows_read, _acl_is_draft, _acl_governed,
#         _content_rel, peek_auth, _lazy_lib, _url_safe_filter (P23) and the
#         rest of the script and its parts; realpath, decode_json, make_path
#         (imported by the script's `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $CONF_FILE, $CT_CACHE_DIR, $REQUEST_CROOT,
#         $TT_DEP_LIVE, @TT_DEPS, %ENV_ALLOWLIST, %RENDER_QUERY (the script's,
#         declared `our` there).
#
# NOT HERE: resolve_site_vars and reset_request_state, which sit between the two
# blocks this part holds, stay in the script with the memo they close over.
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S14). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $CONF_FILE, $CT_CACHE_DIR, $REQUEST_CROOT, $TT_DEP_LIVE, @TT_DEPS, %ENV_ALLOWLIST, %RENDER_QUERY );

# --- Sources and site vars ---
#
# Environment interpolation, content-path resolution, the language set, the
# json/db/tt-var sources a page can name, nav, the lazysite.conf peeks and the
# scan identity. The site-vars memo stays in the script (see the note there) and
# the request host is in request.pm (SM944 S13, S14).

# SM926, RULED 2026-10-01: SERVER_NAME resolves to the host PRESENTED.
#
# This is the processor's copy of Lazysite::Util::_env_value - ADR 0001 keeps the
# render path module-free, so it cannot call the module's, and t/lint/203 pins the
# two identical. The decision in it is one line: `${SERVER_NAME}` must mean the
# host this request arrived on, which is what `_request_host` below has always
# returned for alias-host selection, rather than whatever $ENV{SERVER_NAME} holds -
# because that follows the Host header under Apache's `UseCanonicalName` default of
# Off and the configured ServerName under On. The engine's answer should not depend
# on a vhost setting none of the four shipped examples sets.
#
# The fallback to $ENV{SERVER_NAME} is for a request with no usable Host header: a
# CLI run, or a client that sent something that is not a hostname.
sub _env_value {
    my ($name) = @_;
    return $name eq 'SERVER_NAME'
        ? ( _request_host() || $ENV{SERVER_NAME} )
        : $ENV{$name};
}

sub interpolate_env {
    my ($val) = @_;
    # Only interpolate allowlisted environment variables (S5)
    $val =~ s{\$\{(\w+)\}}{
        $ENV_ALLOWLIST{$1} ? ( _env_value($1) // '' ) : "\${$1}"
    }ge;
    return $val;
}

# tt_page_var `json:` source - load a LOCAL JSON file (docroot-relative or a full
# docroot path) and expose the DECODED data structure (hash/array) to the page so
# the body can [% FOREACH row IN data.rows %]. Docroot-contained only; returns ''
# (a falsey scalar, so FOREACH/IF degrade quietly) on missing / invalid / out-of-
# tree, with a WARN. No remote fetch - use a local data file.
# SM179 P4: resolve a content path against the request's content root FIRST, then
# the docroot (shared files) - so a page's json:/include source is byte-identical
# across per-language roots instead of needing a docroot-absolute path into its own
# root. Every candidate stays under the docroot and outside the lazysite/
# management tree (no wider than the docroot-only resolution it replaces). Returns
# the realpath of the first existing candidate, or undef.
sub _resolve_content_path {
    my ($src) = @_;
    my $croot = $REQUEST_CROOT // $DOCROOT;
    my @cands;
    if ( index( $src, $DOCROOT ) == 0 ) {
        @cands = ($src);    # already a full docroot filesystem path
    }
    else {
        ( my $rel = $src ) =~ s{^/+}{};
        @cands = $croot ne $DOCROOT ? ( "$croot/$rel", "$DOCROOT/$rel" ) : ("$DOCROOT/$rel");
    }
    for my $c (@cands) {
        my $real = realpath($c);
        next
            unless $real
            && _path_under( $real,  $DOCROOT )
            && !_path_under( $real, "$LAZYSITE_DIR" )
            && -f $real;
        return $real;
    }
    return undef;
}

# SM179 P2: the language-set members for the current request - the ordered
# [% languages %] list. For every host that shares the current host's lang_group:
# { lang, url, current, exists } where url is the sibling's site_url + the same
# request path, current marks the active host, and exists stats the counterpart
# page in the sibling's content root. Empty unless the current host is in a
# language set (a lang_group with >= 2 members). A layout renders a switcher and
# hreflang from this; the engine supplies it so nobody hand-rolls either.
sub _language_set {
    my ( $cur_host, $cur_group, $req_path ) = @_;
    return () unless defined $cur_group && length $cur_group;
    my $text = eval { read_file($CONF_FILE) } // '';

    my ( %base, %alias );
    while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) { $base{$1} = $2 }
    while ( $text =~ /^alias\.(\S+)\.(\w+)\h*:\h*(.+)$/mg ) { $alias{ lc $1 }{$2} = $3 }

    my @members;
    push @members, { host => '', %base }
        if ( $base{lang_group} // '' ) eq $cur_group;
    for my $h ( sort keys %alias ) {
        push @members, { host => $h, %{ $alias{$h} } }
            if ( $alias{$h}{lang_group} // '' ) eq $cur_group;
    }
    return () unless @members >= 2;

    ( my $rel = ( $req_path // '/' ) ) =~ s/\?.*$//;    # drop any query string
    $rel                               =~ s{^/+}{};
    $rel                               =~ s{/+$}{};     # 'compare', or '' for home
    my @langs;
    for my $m (@members) {
        ( my $url = $m->{site_url} // '' ) =~ s{/+$}{};
        $url .= length $rel ? "/$rel" : '/';
        my $cr = length( $m->{content_root} // '' ) ? "$DOCROOT/$m->{content_root}" : $DOCROOT;
        my $stem   = length $rel                    ? "$cr/$rel" : "$cr/index";
        my $exists = ( -f "$stem.md" || -f "$stem.url" || -f "$stem.html" ) ? 1 : 0;
        push @langs,
            {
            lang    => ( $m->{lang} // '' ),
            url     => $url,
            current => ( $m->{host} eq $cur_host ? 1 : 0 ),
            exists  => $exists,
            };
    }
    return @langs;
}

# P14 (WORK-PLAN-0154, ruled 2026-10-12 "Render from the canonical"): THE DOMAIN
# A HOST IS AN ALIAS OF. A host registered as an alias (domain-alias-add, SM217)
# shares another domain's content root and named ITSELF as canonical: its pages'
# <link rel="canonical">, its sitemap and llms.txt carried the alias's own
# address, so one site answered as two, each canonical to itself.
#
# alias_of is DERIVED, never stored (Lazysite::Manager::Domains::domains_list):
# the canonical domain of a content root is the FIRST row carrying it, the
# primary first and then alias_hosts in order. This is a MARKED COPY of that
# derivation for the render path, which loads no modules (ADR 0001); t/lint/224
# runs both over the same confs. Change one, change both.
#
# $text is lazysite.conf; $cur is the request's alias host ('' on the primary).
# Returns ( canonical host - '' for the primary, the canonical domain's raw
# site_url ), the current host's own when it is the first with its root.
sub _canonical_of {
    my ( $text, $cur ) = @_;
    $cur = lc( $cur // '' );
    my ( %base, %ov );
    for my $line ( split /\n/, ( $text // '' ) ) {
        if ( $line =~ /^alias\.(\S+?)\.(\w+)\s*:\s*(.*?)\s*$/ ) { $ov{ lc $1 }{$2} = $3 }
        elsif ( $line =~ /^(\w+)\s*:\s*(.*?)\s*$/ )             { $base{$1} = $2 }
    }
    my @hosts = grep { length } map { s/^\s+|\s+$//gr } split /,/, ( $base{alias_hosts} // '' );
    my $val = sub {
        my ( $h, $k ) = @_;
        return $base{$k} // '' if $h eq '';
        return defined $ov{ lc $h }{$k} ? $ov{ lc $h }{$k} : ( $base{$k} // '' );
    };
    my $root = $val->( $cur, 'content_root' );
    for my $h ( '', @hosts ) {
        next unless $val->( $h, 'content_root' ) eq $root;
        return ( lc $h, $val->( $h, 'site_url' ) );
    }
    return ( $cur, $val->( $cur, 'site_url' ) );
}

sub resolve_json {
    my ($src) = @_;
    my $real = _resolve_content_path($src);
    if ( !defined $real ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-",
            "tt json source not found or outside docroot", src => $src );
        return '';
    }
    # Read RAW bytes, not via read_file() (which opens :utf8 and returns a decoded
    # wide-char string). decode_json expects UTF-8-encoded BYTES; handing it an
    # already-decoded string makes it choke on any non-ASCII (em dashes, curly
    # quotes, arrows) and return undef - i.e. the whole file silently resolves to
    # empty. Raw bytes -> decode_json decodes the UTF-8 itself, correctly.
    my $raw = eval {
        open my $fh, '<:raw', $real or die "open failed: $!";
        local $/;
        my $bytes = <$fh>;
        close $fh;
        # SM311: the resolved REAL path, so a symlinked data file is watched
        # where it actually lives rather than where it was named.
        _tt_dep($real);
        $bytes;
    };
    return '' unless defined $raw;
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-",
            "tt json source parse failed", src => $src, error => "$@" );
        return '';
    }
    return $data;
}

# SM311: what a page READ, so the cache can tell when it has gone stale.
#
# THE DEFECT. A page pulls structured data in with `tt_page_var: x: json:/d.json`
# and renders it. The rendered HTML is cached, and the cache was fresh whenever
# it post-dated the .md and lazysite.conf. A change to a file the page merely
# READS is neither, so editing the data updated the page exactly once - at the
# next page save - and served the previous render indefinitely.
#
# That defeats the feature's only reason to exist. Writing the list into the page
# would work; the data file exists so a non-technical owner, a scheduled export,
# or anyone without page-editing rights can change what the page shows. That is
# precisely the caller for whom the failure is invisible AND unfixable: the
# recovery is to save the page, which needs `manage_content`, which a
# data-directory editor does not hold.
#
# It is SM251 one layer down. A registry rebuilds during page processing, so
# requesting the registry does not refresh it; a page re-renders when the page is
# saved, so changing what it renders FROM does not refresh it. Both assume an
# artefact's inputs change only when the artefact does.
#
# WHY A RECORD RATHER THAN A RE-CHECK. `scan:` globs up to 200 .md files and
# reads each one's front matter, so proving a scan-backed page fresh means
# knowing about EDITS inside those files, not just additions and removals. A
# directory mtime cannot see an edit; redoing the walk would put a 200-file
# traversal with front-matter parsing on the cache-hit path, which is the hottest
# path in the engine. So the render - which has already done the walk - writes
# down what it consumed, and the cache path stats that list. Adds and deletes are
# caught by the directories in the list, edits by the files.
#
# The record is written by the code that RESOLVED the sources, because that is
# the only place that knows what a glob actually matched. Deriving it a second
# time from the front matter would be a second implementation of the same
# question, and the second one is the one that drifts.
# The two variables are DECLARED near the top of the file, with the rest of the
# request-lifetime state: process_md resets them at the start of a render
# (SM888 A2) and a `my`/`our` down here is not in scope up there.

sub _tt_dep {
    my (@paths) = @_;
    push @TT_DEPS, grep { defined && length } @paths;
    return;
}

sub deps_cache_path {
    my ($base) = @_;
    my $key = $base;
    $key =~ s{/}{:}g;
    return "$CT_CACHE_DIR/$key.deps";
}

# One path per line; a leading '!' marks the live-source flag. Plain text
# because it is read on the hot path and JSON would cost a parse to answer a
# question that is a list of strings.
sub write_deps {
    my ($base) = @_;
    return if _draft_requested();    # SM1030: a draft render writes nothing
    my $path = deps_cache_path($base);

    unless ( @TT_DEPS || $TT_DEP_LIVE ) {
        unlink $path if -f $path;    # the page stopped declaring sources
        return;
    }

    make_path($CT_CACHE_DIR) unless -d $CT_CACHE_DIR;
    my %seen;
    my @uniq = grep { !$seen{$_}++ } @TT_DEPS;

    open my $fh, '>:utf8', "$path.tmp.$$" or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'cannot write dependency record', path => $path, error => $! );
        return;
    };
    print {$fh} "!\n" if $TT_DEP_LIVE;
    print {$fh} "$_\n" for @uniq;
    close $fh;
    rename "$path.tmp.$$", $path;
    return;
}

# Is the cached render still newer than everything it read?
#
# Returns 1 only when that can be ESTABLISHED. A missing record, an unreadable
# one, a vanished dependency or a live source all return 0 - re-rendering a page
# that did not need it costs a render, while serving one that did costs the
# author a silent wrong answer, and this project has spent several releases on
# the second kind.
sub deps_fresh {
    my ( $base, $html_mtime ) = @_;
    my $path = deps_cache_path($base);
    open my $fh, '<:utf8', $path or return 0;

    while ( my $line = <$fh> ) {
        chomp $line;
        next unless length $line;
        if ( $line eq '!' ) { close $fh; return 0 }    # url:, unprovable
        my $dep_mtime = ( stat $line )[9];
        if ( !defined $dep_mtime || $dep_mtime > $html_mtime ) {
            close $fh;
            return 0;
        }
    }
    close $fh;
    return 1;
}

# SM833: A FAILED SCALAR BINDING MUST FAIL SCALAR-SHAPED.
#
# Every failure path in resolve_db returned [] - including for `.count` and
# `.field`, which answer a VALUE. A template then rendered `ARRAY(0x563de04b67d8)`
# onto the page: a Perl reference, and a heap address, reaching a visitor.
#
# The field found it the way it will always be found - on a non-public table read
# anonymously. That refusal is deliberate and is meant to be indistinguishable
# from an absent table (see Access.pm and the log note below); the SHAPE of the
# refusal was not part of the design, and it is what leaked.
#
# THE EMPTY SCALAR IS '' RATHER THAN 0. A refused read is not "zero rows" - the
# table may hold thousands this visitor may not count - and 0 would state a
# number the engine never established, which is the class of lie
# t/lint/09 and the four-state rule exist to stop. Empty renders as nothing,
# which is exactly what a list binding's empty list already renders, so both
# shapes fail alike and neither announces itself to a reader.
#
# A PINNED COPY of one rule from Lazysite::Data::Query: the scalar accessors are
# exactly `count` and `field`, read from the head before `(`. The copy exists
# because the earliest failure here is the data modules failing to LOAD, so there
# is no parser to ask. t/unit/processor/73 pins it by running this and the real
# parser over the same specs.
sub _db_empty {
    my ($spec) = @_;
    my ($head) = split /\(/, ( $spec // '' ), 2;
    my ( undef, $scalar ) = split /\./, ( $head // '' ), 2;
    $scalar = defined $scalar ? $scalar : '';
    $scalar =~ s/^\s+|\s+$//g;
    return $scalar =~ /\A(?:count|field)\z/ ? '' : [];
}

# SM447 / DP-2: a page reads a data table.
#
#   tt_page_var:
#     items: db:products sort=name asc limit=20
#
# THE RENDER PATH IS MODULE-FREE (ADR 0001) AND THIS BREAKS THAT FOR THE PAGES
# THAT USE IT, deliberately, by requiring the data modules LAZILY - so a site
# that never writes `db:` loads nothing new and the property holds for it.
#
# The alternative was a module-free reader hand-rolled here, and it is worse
# than it sounds: it would duplicate the descriptor loader, the type coercion
# and the SQL generation, which are precisely the things that must have ONE
# implementation. Two readers of one store disagreeing about what a decimal is
# would be a defect nobody could see from either side. ADR 0001's reasoning is
# about a GATE on every request; this is a per-page opt-in.
#
# NOT CACHEABLE, and that is the honest answer rather than the convenient one.
# A page bound to a table has no file whose mtime proves it current: the store
# is written through WAL, so a row can change without the database file's
# timestamp moving. Marking it LIVE means such a page is rendered per request -
# which costs something real, and costs less than a page that serves last
# week's price list while reporting itself fresh.
sub resolve_db {
    my ( $spec, $key ) = @_;

    # SM222 L0: the data unit is a CONTRACT plugin, so SM409 / ADR 0009 already
    # rule that it executes only when its script is listed, and that it defaults
    # to disabled. The manager honours that - Manager/Data.pm consults
    # plugin_enabled - and this path did not, so a page bound to a table went on
    # serving rows out of a unit the operator had switched off. This RESTORES the
    # ruling on the render path rather than changing anybody's behaviour: a site
    # using db: has the unit enabled already, because the Data manager refuses to
    # create a table without it.
    #
    # LOGGED, NEVER SILENT, and the paragraph below is why. A page that renders
    # zero rows looks exactly like a page whose table is empty, which is how the
    # lazy-require bug survived until the field proved the source resolved at
    # all. A refusal that names the switched-off unit is the whole difference
    # between a defect and a message.
    if ( !_unit_enabled('plugins/data.pl') ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable needs the data extension, which is switched off',
            key => $key );
        return _db_empty($spec);
    }

    # Modules, lazily - AND THE MODULE TREE HAS TO BE FOUND FIRST.
    #
    # _lazy_lib is not decoration. This code once required the module without
    # locating it: the processor is module-free by design, so it carries NO
    # global @INC bootstrap, and every lazy-loading site here (_chrome,
    # fetch_url, this one) has to find the tree for itself before requiring.
    #
    # That bug passed every test, because `prove -l` puts lib/ on @INC. On a
    # real install nothing does, so the require failed, the eval caught it, and
    # the page rendered ZERO ROWS - silently, to a visitor. The field found it
    # by proving the source resolved at all: scan: gave 26, an unrecognised
    # prefix fell through to the literal, and db: gave nothing.
    my $ok = eval {
        _lazy_lib('Lazysite::Data::Tables');
        1;
    };
    unless ($ok) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable needs the data modules', key => $key );
        return _db_empty($spec);
    }

    my ($table) = split /[\s(.]/, $spec;
    $table = '' unless defined $table;

    # THE VISITOR, and never a sysop (SM476). A page renders the same rows
    # for whoever is looking at it: a sysop seeing rows a visitor cannot is
    # a preview that means nothing, which is the fault SM466 fixed for layouts
    # and themes. So the identity here is the request's, whatever it is.
    #
    # SM857: and it is the identity (mine) filters on. X-Remote-User survives
    # to this point only when apply_trust_gate let it - the auth wrapper's
    # LAZYSITE_AUTH_TRUSTED after it verified the session cookie, or an
    # operator's auth_proxy_trusted - and is deleted otherwise, so a header a
    # visitor sends reads as anonymous, which (mine) answers with no rows.
    my $r = Lazysite::Data::Tables::resolve_binding(
        $DOCROOT, $spec,
        # SM1131: the one identity reader.
        do { my $i = _request_identity(); +{ user => $i->{user}, groups => $i->{groups} } },
        # P17 (ruled 2026-10-12, "Allow own rows"): a (mine) binding reads the
        # viewer's own rows of a table its read rule excludes - only into a
        # render nobody else is served (SM857's per-viewer mark, below).
        ( $RENDER_QUERY{_protected} ? ( mine_reads_own => 1 ) : () ),
    );

    # SNAPSHOT IS THE DEFAULT, AND THAT IS A CORRECTION.
    #
    # Every db: binding used to mark the page LIVE - rendered per request,
    # never cached. That was the safe thing to do before there was a way for an
    # author to say what they wanted, and it is the wrong default to keep: it
    # makes a price list on a home page cost a database read per visitor, which
    # is a performance cliff nobody opted into and nobody can see.
    #
    # The brief's default is snapshot: resolved at render, cached with the
    # page, refreshed by the page's own ttl: like any other content. An author
    # who needs per-request freshness writes `mode=live` and pays for it
    # knowingly.
    #
    # Recorded AFTER the read, because the mode comes from the parsed binding -
    # and a binding that failed to parse gets the safe answer rather than the
    # default one.
    # SM604: EVERY db: BINDING, snapshot included.
    #
    # A snapshot recorded nothing at all - no path, no marker - on the reasoning
    # that there is nothing whose mtime proves a row unchanged. That reasoning
    # is right and the conclusion did not follow: recording nothing is safe only
    # while NOTHING ELSE IS RECORDED, and a binding does not control what else
    # its page binds. Add one json: source and SM311's rule answers for the
    # whole page - every recorded file is older than the render, so the page is
    # fresh - and the table, which is not in the record and cannot be, is never
    # read again. Measured in the field on 0.10.33: rows three writes behind,
    # with no signal, on a page split by how often its data changes, which is
    # exactly what a careful author does.
    #
    # This does NOT re-render a snapshot page per request. The marker only
    # withdraws the mtime proof; the ttl branch below still serves such a page
    # for its declared ttl, which is what "snapshot's freshness is the page's
    # ttl" always meant.
    $TT_DEP_LIVE = 1;

    # A SLOW READ SAYS SO, with the page, the binding and what to do about it.
    # This is what replaced refusing an unindexed filter or order: the refusal
    # was based on a guess about cost, and this is based on the cost.
    if ( $r->{slow} ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable was slow', key => $key, why => $r->{slow} );
    }

    # A TABLE WITH NO STORED SCHEMA IS LOGGED TOO, not just an error.
    #
    # read_rows answers ok with no rows and `pending_schema` when the table is
    # declared and never migrated - an ordinary state, and indistinguishable on
    # the page from a table that is simply empty. Both render nothing, which is
    # the hardest failure to notice on a live site, so the reason goes in the
    # log where somebody can find it.
    if ( $r->{ok} && $r->{pending_schema} ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable has no stored table yet - run the migration',
            key => $key, table => $table );
    }

    # SM857: (mine) ONLY INTO A RENDER NOBODY ELSE WILL BE SERVED.
    #
    # main() marks a page whose front matter binds (mine) as per-viewer, and
    # that arrives here as RENDER_QUERY's `_protected` - the gated page's own
    # token, which stops process_md writing the cache. A (mine) binding found
    # anywhere that mark did not reach - a site-wide variable (memoised per
    # host), an error page, a .url page, a binding the front-matter peek could
    # not see - is REFUSED rather than rendered, because the rows it read
    # would be cached for everyone.
    if ( $r->{mine} && !$RENDER_QUERY{_protected} ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: (mine) binding refused - it is not in a page\'s own '
                . 'tt_page_var, so the render could be cached and served to '
                . 'another viewer',
            key => $key, table => $table );
        return _db_empty($spec);
    }

    # An anonymous viewer owns no rows. Ordinary, not a fault - a page showing
    # "your applications" to somebody who has not signed in - so INFO.
    if ( $r->{mine_anonymous} ) {
        log_event( 'INFO', $ENV{REDIRECT_URL} // '-',
            'db: (mine) binding has no signed-in viewer - rendering no rows',
            key => $key, table => $table );
    }

    unless ( $r->{ok} ) {
        # SM857: (mine) on a table with no created_by is an AUTHOR error, said
        # with the table and the reason. The page renders the binding empty -
        # the same shape every broken binding renders - and the line below
        # names why, so it is never silently empty and never every row.
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: (mine) binding refused - the table has no created_by, set '
                . 'timestamps: true on it',
            key => $key, table => $table, why => ( $r->{error} // '' ) )
            if ( $r->{kind} // '' ) eq 'mine_needs_timestamps';

        # A TABLE THAT IS NOT PUBLISHED LOOKS EXACTLY LIKE ONE THAT IS ABSENT,
        # on purpose - see Access.pm - so the log is the only place the
        # difference can be said, and an author who has just added `db:` and
        # seen nothing needs it said.
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable read nothing - if the table exists, it may not '
                . 'be published (set public: true) or this visitor may not be '
                . 'allowed to read it',
            key => $key, table => $table )
            if ( $r->{kind} // '' ) eq 'no_such_table';

        # SAID, NOT SWALLOWED. An empty list with no explanation is what SM460
        # was: a page that rendered fine and listed nothing, so the author
        # blamed their pattern.
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable could not be read',
            key => $key, table => $table, why => ( $r->{error} // '' ) );
        return _db_empty($spec);
    }
    # A SCALAR BINDING IS A SCALAR. `.count` and `.field` answer a value, and
    # handing back a one-row list would make a page write [% total.0.n %] to
    # show a number - the query engine's internal shape leaking into a
    # template.
    return $r->{value} if exists $r->{value};

    # SM511: a binding's parse warnings reach the log, naming the page and
    # the binding - a clamped limit used to be a refusal that rendered ZERO
    # rows and said nothing anywhere.
    for my $w ( @{ $r->{warnings} || [] } ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable warning', key => $key, table => $table,
            why => $w );
    }

    # SM511: A CAPPED RENDER SAYS SO. The default limit is 200, so a table
    # that outgrows it renders short while looking complete - the exact
    # moment a site has become worth something. The page can say it too:
    # `<var>_total` carries the true count (see resolve_tt_vars).
    my $rows = $r->{rows} || [];
    if ( defined $r->{total} && $r->{total} > @{$rows} ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'db: page variable is capped - rendering '
                . scalar( @{$rows} )
                . " of $r->{total} rows; add limit/offset paging, or render "
                . '<var>_total so the page can say so',
            key => $key, table => $table );
    }
    return ( _escape_db_rows( $rows, $key, $table ), $r->{total} );
}

# SM786: ESCAPE AT THE SINK, so a page author cannot forget.
#
# db-bound values reached the page stash raw while front-matter scalars in the
# SAME stash were escaped - an asymmetry, not a policy - so whoever could write a
# row controlled markup, and therefore script, on every page displaying that
# table. The shipped examples taught the loop without a filter.
#
# Escaped here rather than by AUTO_FILTER on the render engines: this is the one
# place every db value passes through, and a filter on the engine would also
# escape values the engine itself puts in the stash, which are already escaped.
#
# NO OVERRIDE. `db_render_raw` shipped with SM786 announced as deprecated, to
# hold the door for a site whose templates expected raw HTML; the sites agent's
# survey of 14 sites and ~1,100 files found none that authors HTML into a db
# column, so 0.13.13 removed it (N13-30). The upgrade deletes the key and says so
# where a site had it on; lazysite-check reports one left behind.
sub _escape_db_rows {
    my ( $rows, $key, $table ) = @_;
    return $rows unless ref $rows eq 'ARRAY';

    for my $row (@$rows) {
        next unless ref $row eq 'HASH';
        for my $col ( keys %$row ) {
            my $v = $row->{$col};
            next unless defined $v && !ref $v;

            # THE FAIL-SAFE, and the reason it is a WARN and not a refusal.
            #
            # A template that already carries `| html` now escapes an escaped
            # value, and the page shows `&#39;` where an apostrophe belongs.
            # That is a visible, puzzling, harmless-looking defect whose cause is
            # two correct things happening in sequence - so the log says which
            # table and column, and what to do, rather than leaving somebody to
            # find it by staring at the page.
            #
            # Detected on the INPUT, before escaping: a value that already looks
            # entity-encoded. It can be a false positive - a row legitimately
            # containing the text "&amp;" is indistinguishable from one that was
            # escaped upstream - which is exactly why this reports and does not
            # change what it does.
            if ( $v =~ /&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/ ) {
                log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                    'db: value already looks HTML-escaped and is being escaped '
                        . 'again - if this column renders as &amp;#39; or '
                        . '&amp;lt;, remove the | html filter from the template: '
                        . 'escaping is done here now (SM786)',
                    key => $key, table => $table, column => $col );
            }

            # SM966: and the data set - a row cannot spell a link or break JSON.
            $row->{$col} = _data_inert( _esc_html($v) );
        }
    }
    return $rows;
}

# SM747 CU: a page reads an Odoo binding's report.
#
#   tt_page_var:
#     products: odoo:shop-list
#
# The binding is a handler of type odoo that permits PUBLIC (a render is for
# whoever asks, and is cached for the next), run as the site's connection user
# with no request input - what it reads is the operator's binding and nothing a
# visitor sends. Lazily loaded, as db: is, so a site that never writes `odoo:`
# loads nothing new.
#
# A RENDER NEVER WRITES. A binding whose operation writes - or whose operation
# cannot be asked - is refused here, before anything runs: a page view that
# planned or applied a change would turn every crawler into a customer.
#
# A VISITOR'S BINDING IS NOT A PAGE'S. One that works on a visitor's key would
# cache one visitor's basket for the next; it belongs to the Odoo endpoint,
# which answers each browser for itself.
#
# Every scalar in the report is escaped as a db: row is (SM786), because Odoo's
# records are written by people this site has never met.
sub resolve_odoo {
    my ( $id, $key ) = @_;
    my $page = $ENV{REDIRECT_URL} // '-';
    if ( !_unit_enabled('plugins/odoo.pl') ) {
        log_event( 'WARN', $page, 'odoo: page variable needs the Odoo extension, which is switched off',
            key => $key );
        return '';
    }
    my $ok = eval { _lazy_lib('Lazysite::Odoo'); 1 };
    unless ($ok) {
        log_event( 'WARN', $page, 'odoo: page variable needs the Odoo modules', key => $key );
        return '';
    }
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $DOCROOT;
    my ( $b, $why ) = Lazysite::Odoo::find_binding($id);
    unless ($b) {
        log_event( 'WARN', $page, 'odoo: page variable names no usable binding', key => $key, why => $why );
        return '';
    }
    if ( length $b->{visitor_param} ) {
        log_event( 'WARN', $page,
            'odoo: page variable refused - the binding works on a visitor\'s key, and a page '
                . 'render is shared; read it through the Odoo endpoint instead',
            key => $key, binding => $id );
        return '';
    }
    if ( ( $b->{answer} // '' ) eq 'download' ) {    # SM1225
        log_event( 'WARN', $page,
            "odoo: page variable refused - the binding '$id' answers a download (answer: download); "
                . 'the document would be put in the page as base64. Link to the Odoo endpoint instead',
            key => $key, binding => $id );
        return '';
    }
    if ( ( $b->{credential} // '' ) eq 'session' ) {
        log_event( 'WARN', $page,
            'odoo: page variable refused - the binding runs as a person signed in to Odoo, and a '
                . 'page render is shared and cached; what one person may see is never put in it',
            key => $key, binding => $id );
        return '';
    }
    my $w = Lazysite::Odoo::writes_of($b);
    unless ( defined $w && !$w ) {
        log_event( 'WARN', $page,
            'odoo: page variable refused - a render never runs an operation that writes'
                . ( defined $w ? '' : ' (and this one could not be asked whether it does)' ),
            key => $key, binding => $id );
        return '';
    }
    $TT_DEP_LIVE = 1;
    my $r = Lazysite::Odoo::call( $b, {}, mode => 'public', ip => ( _request_address( _trusted_proxy_spec() ) // '' ),
        host => _request_host() ); # E-Q1: a domain's binding renders only on its own host
    unless ( $r->{ok} ) {
        log_event( 'WARN', $page, 'odoo: page variable read nothing', key => $key, binding => $id,
            kind => ( $r->{kind} // '' ), why => ( $r->{error} // '' ) );
        return '';
    }
    require Lazysite::Odoo::Fields;
    return _odoo_inert( Lazysite::Odoo::Fields::page_report( $r->{report} ) );
}

# SM747 C (OI1, OI4, OI5): who the viewer is in Odoo, for the page to PRESENT.
#
#   tt_page_var:
#     me: odoo-identity:
#
# gives `me.name`, `me.lang`, `me.tz`, `me.company_id`, `me.company_ids` and
# `me.groups`, from the signed identity cookie - or an empty mapping, which is
# what a page renders for a viewer who has not signed in, whose cookie has ended,
# or whose cookie does not verify (a tampered one is no identity).
#
# PRESENTATION ONLY, never authorisation: showing or hiding a part of a page by
# `me.groups` is a convenience, and Odoo is what refuses a call a person may not
# make. Every value is HTML-escaped, as a `db:` value is.
#
# THE CACHE, FAIL-CLOSED (OI5), by SM857's own mechanism: main() marks a page
# whose front matter holds an `odoo-identity:` binding as per-viewer, which is
# the gated page's treatment - never read from or written to the page cache,
# no-store on output - and arrives here as RENDER_QUERY's `_protected`. A binding
# found anywhere that mark did not reach (a site-wide variable, an error page, a
# binding the front-matter peek could not see) is REFUSED rather than rendered,
# because what it read would be cached for everyone.
sub resolve_odoo_identity {
    my ($key) = @_;
    unless ( $RENDER_QUERY{_protected} ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'odoo-identity: binding refused - it is not in a page\'s own tt_page_var, so the render '
                . 'could be cached and served to another viewer',
            key => $key );
        return {};
    }
    $TT_DEP_LIVE = 1;
    eval { require Lazysite::Odoo; require Lazysite::Odoo::Identity; require Lazysite::Odoo::Visitor; 1 } or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'odoo-identity: needs the Odoo modules', key => $key );
        return {};
    };
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT          = $DOCROOT;
    local $Lazysite::Odoo::Visitor::DOCROOT = $DOCROOT;
    my $id = Lazysite::Odoo::Identity::identity_from_cookie( $ENV{HTTP_COOKIE} // '', ttl => Lazysite::Odoo::identity_ttl() );
    return {} unless $id;
    return _odoo_inert($id);
}

sub _odoo_inert {
    my ($v) = @_;
    return [ map { _odoo_inert($_) } @$v ]                        if ref $v eq 'ARRAY';
    return { map { ( $_ => _odoo_inert( $v->{$_} ) ) } keys %$v } if ref $v eq 'HASH';
    return $v if ref $v || !defined $v;
    return _data_inert( _esc_html($v) );
}

sub resolve_tt_vars {
    my ($defs) = @_;
    my %vars;

    # SM311 started the render's dependency record here, when this was the only
    # thing that recorded one. SM888 A2 moved it to process_md, the render's
    # actual boundary: resolve_tt_vars is called from resolve_site_vars and from
    # render_content, BOTH of which run after `::: include` has already
    # resolved - so a reset here wiped what the include had recorded, and the
    # record was written empty. See process_md.

    for my $key ( keys %$defs ) {
        my $val = strip_tt_directives( $defs->{$key} );

        if ( $val =~ s/^scan:// ) {
            $val =~ s/^\s+|\s+$//g;
            # P9: and how many it matched, as db: does (SM511), so a page
            # can say "showing 200 of 1,745" when the scan was capped.
            my ( $list, $total ) = resolve_scan($val);
            $vars{$key} = $list;
            $vars{ $key . '_total' } = 0 + ( $total // 0 );
        }
        elsif ( $val =~ s/^db://i ) {
            $val =~ s/^\s+|\s+$//g;
            my ( $v, $total ) = resolve_db( $val, $key );
            $vars{$key} = $v;

            # SM511: the true count, beside the (possibly capped) list, so a
            # page can say "showing 200 of 250". Scalar bindings (.count,
            # .field) answer a value and carry no companion.
            $vars{ $key . '_total' } = 0 + $total if defined $total;
        }
        elsif ( $val =~ s/^odoo-identity:\s*//i ) {
            $vars{$key} = resolve_odoo_identity($key);
        }
        elsif ( $val =~ s/^odoo://i ) {
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_odoo( $val, $key );
        }
        elsif ( $val =~ s/^json://i ) {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_json($val);
        }
        elsif ( $val =~ s/^url:// ) {
            # A remote source has no local mtime, so no amount of stat-ing can
            # prove a cached page still matches it. Recorded as a live source so
            # the cache path stops claiming freshness it cannot establish.
            $TT_DEP_LIVE = 1;
            $val         = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            my $fetched = fetch_url($val);
            if ( defined $fetched ) {
                $fetched =~ s/^\s+|\s+$//g;
                $vars{$key} = $fetched;
            }
            else {
                log_event( "WARN", $ENV{REDIRECT_URL} // "-", "tt var fetch failed", key => $key, val => $val );
                $vars{$key} = '';
            }
        }
        else {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = $val;
        }
    }

    return %vars;
}

# The nav file a request renders with: the alias host's nav_file override,
# the site's, or lazysite/nav.conf. One definition, because try_serve_cache
# (SM536) has to stat the SAME file resolve_site_vars parses - two spellings
# of "which nav file" is how a cache check comes to guard the wrong one.
#
# SM850: a configured nav_file is site-relative, and a leading `lazysite/` means
# the engine tree wherever it is - _site_path, the module-free copy of
# Lazysite::Paths::site_path that t/lint/37 drives against it. Joined to the
# docroot, `lazysite/nav-2.conf` was read from a directory a migrated site no
# longer has, and the domain rendered with no nav.
sub _nav_file_for {
    my ($vars) = @_;
    return $vars->{nav_file}
        ? _site_path( $LAZYSITE_DIR, $DOCROOT, $vars->{nav_file} )
        : "$LAZYSITE_DIR/nav.conf";
}

sub _site_path {
    my ( $lz, $d, $rel ) = @_;
    ( my $r = $rel ) =~ s{\A/+}{};
    if ( $r =~ m{\Alazysite(?:/(.*))?\z}s ) {
        my $tail = $1;
        return defined $tail && length $tail ? "$lz/$tail" : $lz;
    }
    return "$d/$r";
}

sub parse_nav {
    my ($nav_path) = @_;
    return [] unless -f $nav_path;

    open( my $fh, '<:utf8', $nav_path ) or return [];

    my @nav;
    my $current_parent = undef;

    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /^\s*#/;    # comment
        next if $line =~ /^\s*$/;    # blank line

        my $is_child = $line =~ /^\s+/;
        $line =~ s/^\s+|\s+$//g;     # trim

        my ( $label, $url ) = split /\s*\|\s*/, $line, 2;
        $label = defined $label ? $label : '';
        $label =~ s/^\s+|\s+$//g;
        $url = defined $url ? $url : '';
        $url =~ s/^\s+|\s+$//g;

        next unless length $label;

        # P23 (WORK-PLAN-0154, ruled 2026-10-12): an address whose scheme can
        # run script renders as `#`, logged - the `| url_safe` rule (SM970),
        # applied here because every layout puts a nav url in an href. A save
        # refuses one now; this is the nav file written before that, or by
        # hand.
        if ( length $url && _url_safe_filter($url) ne $url ) {
            ( my $rel = $nav_path ) =~ s{^\Q$DOCROOT\E/*}{};
            my ($scheme) = $url =~ /\A\W*([a-zA-Z][a-zA-Z0-9+.\-]{0,19})/;
            log_event( 'WARN', 'nav', 'a nav entry whose address has an unsafe scheme is rendered as #',
                nav => $rel, label => $label, scheme => ( $scheme // '?' ) );
            $url = '#';
        }

        if ($is_child) {
            # Add to current parent's children
            if ( defined $current_parent ) {
                push @{ $nav[$current_parent]{children} },
                    { label => $label, url => $url };
            }
            # Orphan child (no parent yet) - treat as top-level
            else {
                push @nav, { label => $label, url => $url, children => [] };
            }
        }
        else {
            # Top-level item
            push @nav, { label => $label, url => $url, children => [] };
            $current_parent = $#nav;
        }
    }

    close $fh;
    return \@nav;
}

# search_default as a boolean. peek_conf_key below reads the same file with the
# same first-match rule and the same `^key\s*:\s*(\S+)` regex, so this is that
# reader plus the false test: a missing file, an unreadable file and a missing
# key all peek as '', and '' is not /^false$/i, so every one of them still
# answers 1 exactly as the hand-rolled loop did.
sub peek_search_default {
    return peek_conf_key('search_default') =~ /^false$/i ? 0 : 1;
}

# SM268 H13: a scan must not publish what the requester may not read.
#
# resolve_scan and scan_pages read .md sources directly and applied no filter at
# all, so the title, subtitle, path, custom front-matter keys and a 500-character
# BODY EXCERPT of every page inside a gated section were published to anonymous
# visitors by any page that scans the tree - including the starter's own
# /search-index, which is api: true with ttl: 3600 and is therefore served
# Cache-Control: public, max-age=3600. Gating a folder stopped the page being
# served and published its opening paragraph to a shared cache for an hour.
#
# The identity comes from the one reader (SM1131), which reads the conf FILE
# rather than going through resolve_site_vars, because resolve_scan is itself
# called FROM resolve_site_vars for conf directives and asking for site vars here
# can re-enter it before its cache is warm.
{
    my ( $_scan_id_done, $_scan_user, @_scan_groups );

    sub _scan_identity {
        unless ($_scan_id_done) {
            $_scan_id_done = 1;
            # SM1131: the one identity reader. It reads the conf file itself, so
            # a site that renamed its proxy headers scans as the proxy's user.
            my $i = _request_identity();
            $_scan_user   = $i->{user};
            @_scan_groups = @{ $i->{groups} };
        }
        return ( $_scan_user, \@_scan_groups );
    }

    # SM1169: the identity above is the REQUEST's. It was computed once and kept,
    # so under the pool every later `scan:` was filtered as the first visitor.
    # Called from reset_request_state.
    sub _reset_scan_identity {
        $_scan_id_done = 0;
        $_scan_user    = undef;
        @_scan_groups  = ();
        return;
    }
}

# One conf key, read from the file without going through resolve_site_vars - the
# same reason peek_search_default exists. Per-domain alias overrides are not
# applied; auth_default is a site-wide switch and a scanning page on a fully
# gated site has already been through check_auth.
sub peek_conf_key {
    my ($key) = @_;
    return '' unless -f $CONF_FILE;
    open my $fh, '<:utf8', $CONF_FILE or return '';
    my $val = '';
    while ( my $line = <$fh> ) {
        next unless $line =~ /^\Q$key\E\s*:\s*(\S+)/;
        $val = $1;
        last;
    }
    close $fh;
    return $val;
}

# 1 if this page must be left out of a scan result for the requesting identity.
sub _scan_hidden {
    my ($abs) = @_;

    # SM181, and the reason this merge needed a decision rather than a pick.
    #
    # The draft filter went into scan_pages under the belief that it was "the
    # single place page listings are built - the registries AND the `scan:`
    # page-list variables". SM268 H13 made that untrue: resolve_scan filters
    # separately, here. Taking either side of the conflict alone would have left
    # a draft page appearing in a `scan:` list, which is the one thing SM181
    # says unconditionally does not happen.
    #
    # Before the identity checks, because draft is not a question about the
    # requester: SM181 makes the exclusion from listings unconditional, so an
    # editor who may PREVIEW the page still does not see it listed.
    return 1 if _acl_is_draft($abs);

    # SM1139: a page limited by address is out of every scan, for everyone. A scan
    # is rendered into a page that may be cached, and what it lists would then
    # depend on the first visitor's address; leaving the page out is the one
    # answer that is the same for all of them.
    return 1 if @{ _address_layers_for($abs) };

    my ( $user, $groups ) = _scan_identity();

    # The per-path ACL, keyed docroot-relative exactly as the read path keys it.
    # SM286: via _content_rel, so a page resolved from the private store is
    # keyed and checked rather than skipping the branch and being listed.
    my $rel = _content_rel($abs);
    if ( defined $rel ) {
        return 1 unless _acl_allows_read( $rel, $user, @{$groups} );
    }

    # The publication gate: auth: front matter, or the site's auth_default.
    my $meta  = peek_auth($abs);
    return 1 if $meta->{unreadable};    # SM980: an access key it cannot read hides it
    my $level = $meta->{auth} || peek_conf_key('auth_default') || 'none';
    # SM993: auth_groups means signed in (on a paid page it is the payment
    # bypass), and `auth: manager` is in no listing - a manager page is not
    # content, and on a content page it is refused to everyone.
    $level = 'required'
        if @{ $meta->{groups} // [] } && ( $meta->{payment} // '' ) ne 'required' && $level ne 'manager';
    return 1 if $level eq 'manager';
    return 0 if $level eq 'none';
    return 1 unless length $user;

    my @required = @{ $meta->{groups} // [] };
    return 0 unless @required;
    my %have = map { lc($_) => 1 } @{$groups};
    return ( grep { $have{ lc($_) } } @required ) ? 0 : 1;
}

# 1 if this page must be left out of the generated registries. Identity plays no
# part: the artefact outlives the request that built it.
sub _registry_hidden {
    my ($abs) = @_;
    # SM181: a draft section leaves every listing, unconditionally.
    return 1 if _acl_is_draft($abs);
    return 1 if _acl_governed($abs);
    my $meta  = peek_auth($abs);
    return 1 if $meta->{unreadable};    # SM980: refused to everyone, listed nowhere
    my $level = $meta->{auth} || peek_conf_key('auth_default') || 'none';
    # SM993: auth_groups means signed in (on a paid page it is the payment
    # bypass), and `auth: manager` is in no listing - a manager page is not
    # content, and on a content page it is refused to everyone.
    $level = 'required'
        if @{ $meta->{groups} // [] } && ( $meta->{payment} // '' ) ne 'required' && $level ne 'manager';
    return 1 if $level eq 'manager';
    return $level eq 'none' ? 0 : 1;
}

# Normalise a passed-through front-matter scalar for scan results: trim, strip a
# single layer of matching surrounding quotes (so accent: "#7C5CFF" yields #7C5CFF
# rather than the literal quotes), and strip TT markers as defence in depth.
sub _scan_scalar {
    my ($v) = @_;
    return $v if ref $v;
    $v //= '';
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/^(['"])(.*)\1$/$2/;
    $v =~ s/\[%|%\]//g;
    return $v;
}

1;

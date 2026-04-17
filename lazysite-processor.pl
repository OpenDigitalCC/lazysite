#!/usr/bin/perl
use strict;
use warnings;
use Text::MultiMarkdown;
use Template;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use LWP::UserAgent;
use Cwd qw(realpath);
use JSON::PP qw(decode_json);

# --- Configuration ---

my $DOCROOT     = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

my $LAZYSITE_DIR  = "$DOCROOT/lazysite";
my $LAZYSITE_URI  = "/lazysite";

# F0003: lazysite.conf path override
# Priority: --conf arg > LAZYSITE_CONF env var > default
my $CONF_OVERRIDE;
for my $i ( 0 .. $#ARGV ) {
    if ( $ARGV[$i] eq '--conf' && defined $ARGV[$i+1] ) {
        $CONF_OVERRIDE = $ARGV[$i+1];
        last;
    }
}
$CONF_OVERRIDE //= $ENV{LAZYSITE_CONF};

my $CONF_FILE = $CONF_OVERRIDE
    ? $CONF_OVERRIDE
    : "$LAZYSITE_DIR/lazysite.conf";
my $LAYOUT_DIR    = "$LAZYSITE_DIR/templates";
my $LAYOUT        = "$LAZYSITE_DIR/templates/view.tt";
my $REGISTRY_DIR  = "$LAZYSITE_DIR/templates/registries";
my $THEMES_DIR    = "$LAZYSITE_DIR/themes";
my $REMOTE_TTL       = 3600;  # seconds before remote content is refetched (default 1 hour)
my $REGISTRY_TTL     = 14400; # seconds before registries are regenerated (default 4 hours)
my $LAYOUT_CACHE_DIR = "$LAZYSITE_DIR/cache/layouts";
my $CT_CACHE_DIR     = "$LAZYSITE_DIR/cache/ct";

# Built-in fallback template - used when no view.tt is found
my $FALLBACK_LAYOUT = <<'END_FALLBACK';
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[% page_title %][% IF site_name %]  -  [% site_name %][% END %]</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px;
               margin: 2rem auto; padding: 0 1rem; color: #333; }
        h1 { border-bottom: 1px solid #eee; padding-bottom: 0.5rem; }
        pre { background: #f5f5f5; padding: 1rem; overflow-x: auto; }
        code { background: #f5f5f5; padding: 0.2em 0.4em; }
        footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #eee;
                 font-size: 0.85rem; color: #888; }
        a { color: #0066cc; }
    </style>
</head>
<body>
<main>
    <p><a href="/">Home</a></p>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
    [% content %]
</main>
<footer>
    <p>Rendered by <a href="https://lazysite.io">lazysite</a>
    [% IF site_name %]- [% site_name %][% END %]
    - no view.tt found, using built-in fallback</p>
</footer>
</body>
</html>
END_FALLBACK

# Extension to language identifier map for include code block wrapping
my %LANG_MAP = (
    md   => 'markdown',
    yml  => 'yaml',   yaml => 'yaml',
    sh   => 'bash',   bash => 'bash',
    pl   => 'perl',
    py   => 'python',
    js   => 'javascript',
    json => 'json',
    html => 'html',   htm  => 'html',
    css  => 'css',
    conf => 'text',   cfg  => 'text',
    txt  => 'text',
    toml => 'toml',
    xml  => 'xml',
);

# Allowlist of CGI environment variables that may be interpolated in lazysite.conf
# Note: HTTP_HOST is intentionally excluded - it is request-supplied and untrusted.
# Use SERVER_NAME for host-based URL construction.
my %ENV_ALLOWLIST = map { $_ => 1 } qw(
    SERVER_NAME SERVER_PORT REQUEST_SCHEME HTTPS
    REQUEST_URI REDIRECT_URL
    DOCUMENT_ROOT SERVER_ADMIN
);

# --- Main ---

main();

sub main {
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Capture query string before stripping
    my %query_params;
    if ( $uri =~ s/\?(.*)$// ) {
        my $qs = $1;
        for my $pair ( split /&/, $qs ) {
            my ( $key, $val ) = split /=/, $pair, 2;
            next unless defined $key && length $key;
            # URL-decode key and value
            $key =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $val = '' unless defined $val;
            $val =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $val =~ s/\+/ /g;
            # HTML-escape value before storing
            $val =~ s/&/&amp;/g;
            $val =~ s/</&lt;/g;
            $val =~ s/>/&gt;/g;
            $val =~ s/"/&quot;/g;
            $val =~ s/'/&#39;/g;
            $query_params{$key} = $val;
        }
    }

    # Block access to lazysite system directory
    if ( $uri eq $LAZYSITE_URI || index( $uri, $LAZYSITE_URI . '/' ) == 0 ) {
        forbidden();
        return;
    }

    # Sanitise URI against path traversal
    my $base = sanitise_uri($uri);
    unless ( defined $base ) {
        not_found($uri);
        return;
    }

    my $md_path   = "$DOCROOT/$base.md";
    my $url_path  = "$DOCROOT/$base.url";
    my $html_path = "$DOCROOT/$base.html";

    # Stat both source and cache files once - pass results to avoid redundant syscalls
    my @html_stat = stat($html_path);
    my @md_stat   = stat($md_path);

    # Check if this page declares query_params and request has matching ones
    my $has_query_request = 0;
    my $declared_params   = undef;

    if ( %query_params && @md_stat ) {
        $declared_params = peek_query_params($md_path);
        if ( $declared_params ) {
            # Check if any declared param appears in the request
            for my $p ( @$declared_params ) {
                if ( exists $query_params{$p} ) {
                    $has_query_request = 1;
                    last;
                }
            }
        }
    }

    # Fast path: .md exists and cache is fresh by mtime
    # Skip cache if LAZYSITE_NOCACHE is set or query request is active
    unless ( $ENV{LAZYSITE_NOCACHE} || $has_query_request ) {
        if ( @md_stat && @html_stat ) {
            if ( $html_stat[9] >= $md_stat[9] ) {
                # mtime fresh - serve cache immediately, no peek_ttl needed
                my $ct = read_ct($base);
                output_page( read_file($html_path), $ct );
                return;
            }
            # mtime stale - check for page-level TTL override before regenerating
            my $ttl = peek_ttl($md_path);
            if ( defined $ttl && is_fresh_ttl_val_stat( \@html_stat, $ttl ) ) {
                my $ct = read_ct($base);
                output_page( read_file($html_path), $ct );
                return;
            }
        }
    }

    # .md exists but no cache yet - process it
    # realpath check runs here on the write path only, not on cache hits
    if ( @md_stat ) {
        my $real = realpath($md_path);
        if ( !defined $real || index( $real, $DOCROOT ) != 0 ) {
            not_found($uri);
            return;
        }

        # Filter query params to declared allowlist only
        my %filtered_query;
        if ( $declared_params && $has_query_request ) {
            for my $p ( @$declared_params ) {
                $filtered_query{$p} = $query_params{$p}
                    if exists $query_params{$p};
            }
        }

        my $page = process_md( $md_path, $html_path, $md_stat[9], \%filtered_query );
        my $ct   = peek_content_type($md_path);
        write_ct( $base, $ct );
        output_page( $page, $ct );
        return;
    }

    # Found .url - fetch remote content
    if ( -f $url_path ) {
        my $real = realpath($url_path);
        if ( !defined $real || index( $real, $DOCROOT ) != 0 ) {
            not_found($uri);
            return;
        }
        my $page = process_url( $url_path, $html_path, (stat($url_path))[9] );
        my $ct   = peek_content_type($url_path);
        write_ct( $base, $ct );
        output_page( $page, $ct );
        return;
    }

    # No source found - serve 404 page
    not_found($uri);
}

# --- Processing ---

sub sanitise_uri {
    my ($uri) = @_;

    # Strip leading slash
    $uri =~ s{^/}{};

    # Trailing slash means directory index
    if ( $uri =~ s{/$}{} ) {
        $uri .= '/index';
    }
    else {
        # Strip file extension
        $uri =~ s/\.(html|md|url)$//;
    }

    # Reject null bytes
    return undef if $uri =~ /\0/;

    # Reject path traversal sequences
    return undef if $uri =~ m{(?:^|/)\.\.(?:/|$)};

    # Reject absolute paths or suspicious characters
    return undef if $uri =~ m{^/};
    return undef if $uri =~ m{[<>"'\\]};

    # Empty uri means docroot index
    $uri = 'index' unless length $uri;

    return $uri;
}

sub process_md {
    my ( $md_path, $html_path, $md_mtime, $query ) = @_;
    $query //= {};

    my $raw_text        = read_file($md_path);
    my ( $meta, $body ) = parse_yaml_front_matter($raw_text);

    # Format mtime for TT variables
    if ( defined $md_mtime ) {
        my @t = localtime($md_mtime);
        my @months = qw(January February March April May June
                        July August September October November December);
        $meta->{page_modified} = sprintf("%d %s %d",
            $t[3], $months[$t[4]], $t[5] + 1900);
        $meta->{page_modified_iso} = sprintf("%04d-%02d-%02d",
            $t[5] + 1900, $t[4] + 1, $t[3]);
    }
    my $page;

    # api: true - body is pure TT, no Markdown pipeline, no layout
    if ( $meta->{api} && $meta->{api} =~ /^true$/i ) {
        my ( $processed_body ) = render_content( $meta, $body, $query );
        $processed_body =~ s/^\s+|\s+$//g;  # trim for clean JSON
        $page = $processed_body;
    }
    # raw: true - Markdown pipeline runs, no layout
    elsif ( $meta->{raw} && $meta->{raw} =~ /^true$/i ) {
        my $converted       = convert_fenced_divs($body);
        my $converted_inc   = convert_fenced_include($converted, $md_path, $meta);
        my $converted2      = convert_fenced_code($converted_inc);
        my $converted3      = convert_oembed($converted2);
        my $html_body       = convert_md($converted3);
        my ( $processed_body ) = render_content( $meta, $html_body, $query );
        $page = $processed_body;
    }
    # Normal mode - full pipeline with layout
    else {
        my $converted       = convert_fenced_divs($body);
        my $converted_inc   = convert_fenced_include($converted, $md_path, $meta);
        my $converted2      = convert_fenced_code($converted_inc);
        my $converted3      = convert_oembed($converted2);
        my $html_body       = convert_md($converted3);
        $meta->{_md_path}   = $md_path;
        $page               = render_template( $meta, $html_body, $query );
        $page               = convert_dt_links($page);
        $page               = convert_p_links($page);
    }

    # Only cache if no query params - query responses are dynamic
    if ( !%$query ) {
        write_html( $html_path, $page );
        eval { update_registries() };
        log_warn("Registry update failed: $@") if $@;
    }

    return $page;
}

sub process_url {
    my ( $url_path, $html_path, $url_mtime ) = @_;

    # Read URL from file
    my $url = read_file($url_path);
    $url =~ s/^\s+|\s+$//g;  # trim whitespace

    # Serve stale cache if still within TTL
    if ( is_fresh_ttl($html_path) ) {
        return read_file($html_path);
    }

    # Fetch remote content
    my $raw = fetch_url($url);

    unless ( defined $raw ) {
        # Fetch failed - serve stale cache if available
        if ( -f $html_path ) {
            return read_file($html_path);
        }
        # No cache - render error block
        return render_template(
            { title => 'Content Unavailable' },
            qq(<div class="errorbox">\n<p>Could not fetch remote content from <code>$url</code>.</p>\n</div>\n)
        );
    }

    my ( $meta, $body ) = parse_yaml_front_matter($raw);

    # Format mtime for TT variables
    if ( defined $url_mtime ) {
        my @t = localtime($url_mtime);
        my @months = qw(January February March April May June
                        July August September October November December);
        $meta->{page_modified} = sprintf("%d %s %d",
            $t[3], $months[$t[4]], $t[5] + 1900);
        $meta->{page_modified_iso} = sprintf("%04d-%02d-%02d",
            $t[5] + 1900, $t[4] + 1, $t[3]);
    }

    my $converted  = convert_fenced_divs($body);
    my $converted_inc = convert_fenced_include($converted, $url_path, $meta);
    my $converted2 = convert_fenced_code($converted_inc);
    my $converted3 = convert_oembed($converted2);
    my $html_body  = convert_md($converted3);

    my $page;
    if ( $meta->{raw} && $meta->{raw} =~ /^true$/i ) {
        my ( $processed_body ) = render_content( $meta, $html_body );
        $page = $processed_body;
    }
    else {
        $page = render_template( $meta, $html_body );
        $page = convert_dt_links($page);
        $page = convert_p_links($page);
    }

    write_html( $html_path, $page );
    eval { update_registries() };
    log_warn("Registry update failed: $@") if $@;

    return $page;
}

sub fetch_url {
    my ($url) = @_;

    # Only allow http/https
    return undef unless $url =~ m{\Ahttps?://};

    my $ua = LWP::UserAgent->new(
        timeout    => 10,
        agent      => 'lazysite/1.0',
    );

    my $response = $ua->get($url);

    return undef unless $response->is_success;
    return $response->decoded_content;
}

sub peek_ttl {
    my ($md_path) = @_;
    open( my $fh, '<:utf8', $md_path ) or return undef;
    my $ttl;
    while ( <$fh> ) {
        last if $. > 1 && /^---/;  # end of front matter
        if ( /^ttl\s*:\s*(\d+)/ ) {
            $ttl = $1;
            last;
        }
    }
    close $fh;
    return $ttl;
}

sub peek_content_type {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or return undef;
    my ( $raw, $api, $content_type );
    while ( <$fh> ) {
        last if $. > 1 && /^---/;
        $raw          = 1  if /^raw\s*:\s*true/i;
        $api          = 1  if /^api\s*:\s*true/i;
        $content_type = $1 if /^content_type\s*:\s*(.+)/;
    }
    close $fh;

    return undef unless $raw || $api;

    if ( $content_type ) {
        $content_type =~ s/^\s+|\s+$//g;
        return $content_type;
    }

    return 'application/json; charset=utf-8' if $api;
    return 'text/plain; charset=utf-8'       if $raw;
    return 'text/html; charset=utf-8';
}

sub peek_query_params {
    my ($md_path) = @_;
    return undef unless -f $md_path;

    open( my $fh, '<:utf8', $md_path ) or return undef;
    my ( @params, $in_block );
    while ( <$fh> ) {
        last if $. > 1 && /^---/;  # end of front matter
        if ( /^query_params\s*:\s*$/ ) {
            $in_block = 1;
            next;
        }
        if ( $in_block ) {
            if ( /^[ \t]+-[ \t]*(\S+)/ ) {
                push @params, $1;
            }
            else {
                last;  # end of block
            }
        }
    }
    close $fh;
    return @params ? \@params : undef;
}

sub is_fresh_ttl_val_stat {
    my ( $html_stat, $ttl ) = @_;
    return 0 unless @$html_stat;
    return ( time() - $html_stat->[9] ) < $ttl;
}

sub is_fresh_ttl_val {
    my ( $html_path, $ttl ) = @_;
    return 0 unless -f $html_path;
    return ( time() - ( stat($html_path) )[9] ) < $ttl;
}

sub is_fresh_ttl {
    my ($html_path) = @_;
    return 0 unless -f $html_path;
    return ( time() - ( stat($html_path) )[9] ) < $REMOTE_TTL;
}

sub is_fresh {
    my ( $html_path, $md_path ) = @_;
    return 0 unless -f $html_path;
    return 0 unless -f $md_path;
    return ( stat($html_path) )[9] >= ( stat($md_path) )[9];
}

sub parse_yaml_front_matter {
    my ($text) = @_;
    my %meta;

    if ( $text =~ s/\A---\s*\n(.*?)\n---\s*\n//s ) {
        my $yaml = $1;

        # Parse register list (- item lines)
        if ( $yaml =~ /^register\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @registries;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @registries, strip_tt_directives($1);
            }
            $meta{register} = \@registries;
        }

        # Parse tt_page_var block (indented key: value pairs)
        # The alternation (?:\n|$) handles the last line which may have no
        # trailing newline if it is the final line of the front matter block
        if ( $yaml =~ /^tt_page_var\s*:\s*\n((?:[ \t]+\S[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my %tt_vars;
            while ( $block =~ /^[ \t]+(\w+)\s*:\s*(.+)$/mg ) {
                $tt_vars{$1} = $2;
            }
            $meta{tt_page_var} = \%tt_vars;
        }

        # Parse tags list (- item lines)
        if ( $yaml =~ /^tags\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @tags;
            while ( $block =~ /^[ \t]*-[ \t]*(.+?)[ \t]*$/mg ) {
                push @tags, strip_tt_directives($1);
            }
            $meta{tags} = \@tags;
        }

        # Parse query_params list (- item lines)
        if ( $yaml =~ /^query_params\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @params;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @params, $1;
            }
            $meta{query_params} = \@params;
        }

        # Parse scalar key: value pairs (skip tt_page_var, register, query_params blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            next if $1 eq 'query_params';
            next if $1 eq 'tags' && ref $meta{tags} eq 'ARRAY';
            # Strip TT directives from all scalar values including title and subtitle
            $meta{$1} = strip_tt_directives($2);
        }
    }

    return ( \%meta, $text );
}

sub convert_fenced_divs {
    my ($text) = @_;

    $text =~ s{
        ^(:::[ \t]+(\S+)[^\n]*)\n  # opening ::: classname [rest of line]
        (.*?)                       # content
        ^:::[ \t]*\n                # closing :::
    }{
        my $opening = $1;
        my $class   = $2;
        my $body    = $3;
        # Skip 'include' and 'oembed' - handled by dedicated converters
        if ( $class eq 'include' || $class eq 'oembed' ) {
            "$opening\n${body}:::\n";
        }
        # Reject class names containing unsafe characters (S4)
        # Valid: word chars and hyphens only, must start with a word char
        elsif ( $class =~ /\A[\w][\w-]*\z/ ) {
            qq(<div class="$class">\n${body}</div>\n);
        }
        else {
            log_warn("Fenced div: rejected unsafe class name '$class'");
            $body;
        }
    }gsmxe;

    return $text;
}

# --- Include ---

sub convert_fenced_include {
    my ( $text, $md_path, $meta ) = @_;
    $meta //= {};

    $text =~ s{
        ^:::[ \t]+include(?:[ \t]+([^\n]*?))?\n  # opening ::: include [modifiers]
        [ \t]*([^\n]+?)[ \t]*\n                   # source URL or path (trimmed)
        ^:::[ \t]*\n                              # closing :::
    }{
        my $modifiers = $1 // '';
        my $source    = $2;

        # Skip if source contains unresolved TT variables - leave for second pass
        if ( $source =~ /\[%.*%\]/ ) {
            "::: include" . ( length $modifiers ? " $modifiers" : '' ) . "\n$source\n:::\n";
        }
        else {

        # Parse ttl modifier
        if ( $modifiers =~ /\bttl=(\d+)\b/ ) {
            my $ttl = $1;
            unless ( defined $meta->{ttl} ) {
                $meta->{ttl} = $ttl;
            }
        }

        _resolve_include( $source, $md_path, $modifiers );
        }
    }gesmx;

    return $text;
}

sub _resolve_include {
    my ( $source, $md_path, $modifiers ) = @_;

    # HTML-escape source for error spans
    ( my $source_escaped = $source ) =~ s/&/&amp;/g;
    $source_escaped =~ s/</&lt;/g;
    $source_escaped =~ s/>/&gt;/g;
    $source_escaped =~ s/"/&quot;/g;

    my $content;
    my $is_remote = $source =~ m{\Ahttps?://};

    if ( $is_remote ) {
        # Remote URL
        $content = fetch_url($source);
        unless ( defined $content ) {
            log_warn("include failed: $source - fetch failed");
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }
    }
    else {
        # Local file
        my $resolved;
        if ( index( $source, $DOCROOT ) == 0 ) {
            # Already a full filesystem path (e.g. from scan results)
            $resolved = $source;
        }
        elsif ( $source =~ m{\A/} ) {
            # Absolute from docroot
            $resolved = $DOCROOT . $source;
        }
        else {
            # Relative to parent .md file
            $resolved = dirname($md_path) . '/' . $source;
        }

        # Realpath check - reject if outside $DOCROOT
        my $real = realpath($resolved);
        if ( !defined $real || index( $real, $DOCROOT ) != 0 ) {
            log_warn("include failed: $source - path outside docroot or not found");
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        if ( ! -f $real ) {
            log_warn("include failed: $source - file not found");
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        $content = eval { read_file($real) };
        if ( $@ || !defined $content ) {
            log_warn("include failed: $source - $@");
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }
    }

    # Determine extension from source
    my $ext = '';
    if ( $source =~ /\.(\w+)(?:\?.*)?$/ ) {
        $ext = lc($1);
    }

    my $lang = $LANG_MAP{$ext} || '';

    if ( $lang eq 'markdown' ) {
        # Strip YAML front matter, run sub-pipeline (no recursion)
        my ( undef, $body ) = parse_yaml_front_matter($content);
        my $sub = convert_fenced_divs($body);
        $sub    = convert_fenced_code($sub);
        $sub    = convert_oembed($sub);
        $sub    = convert_md($sub);
        return $sub;
    }
    elsif ( $ext eq 'html' || $ext eq 'htm' ) {
        # Insert bare HTML
        return $content;
    }
    elsif ( $lang ) {
        # Code file - wrap in fenced code block for convert_fenced_code
        return "```$lang\n$content```\n";
    }
    else {
        # Unknown extension - wrap in <pre>
        $content =~ s/&/&amp;/g;
        $content =~ s/</&lt;/g;
        $content =~ s/>/&gt;/g;
        return "<pre>$content</pre>\n";
    }
}

sub convert_fenced_code {
    my ($text) = @_;

    $text =~ s{
        ^```[ \t]*(\S*)[ \t]*\n  # opening ``` with optional language
        (.*?)                     # content
        ^```[ \t]*\n              # closing ```
    }{
        my $lang = $1;
        my $code = $2;
        $code =~ s/&/&amp;/g;
        $code =~ s/</&lt;/g;
        $code =~ s/>/&gt;/g;
        my $class = $lang ? qq( class="language-$lang") : '';
        "<pre><code$class>$code</code></pre>\n"
    }gsmxe;

    return $text;
}

sub convert_md {
    my ($body) = @_;
    my $md = Text::MultiMarkdown->new(
        use_fenced_code_blocks => 1,
    );
    return $md->markdown($body);
}

sub convert_dt_links {
    my ($html) = @_;
    # Convert unprocessed Markdown links inside <dt> tags.
    # These are left unconverted when <dt> content is authored as Markdown
    # inside an HTML <dl> block, which the Markdown parser does not process.
    $html =~ s{<dt>\[([^\]]+)\]\(([^)]+)\)</dt>}{<dt><a href="$2">$1</a></dt>}g;
    return $html;
}

sub convert_p_links {
    my ($html) = @_;
    # Convert unprocessed Markdown links inside <p> tags after TT rendering.
    # Markdown links containing TT variables in the URL are parsed by
    # MultiMarkdown before TT runs, which strips the TT content from the URL.
    # After TT has resolved all variables, this pass converts any remaining
    # Markdown link syntax in paragraph content to HTML anchor tags.
    $html =~ s{\[([^\]]+)\]\(([^)]+)\)}{<a href="$2">$1</a>}g;
    return $html;
}

# --- oEmbed ---

# Known provider endpoints - matched by URL pattern
# Falls back to autodiscovery for unlisted providers
my %OEMBED_PROVIDERS = (
    qr{youtube\.com/watch|youtu\.be/}   => 'https://www.youtube.com/oembed',
    qr{vimeo\.com/}                     => 'https://vimeo.com/api/oembed.json',
    qr{/videos/watch/|/videos/embed/}   => undef,  # PeerTube - autodiscover
    qr{twitter\.com/|x\.com/}           => 'https://publish.twitter.com/oembed',
    qr{soundcloud\.com/}                => 'https://soundcloud.com/oembed',
);

sub convert_oembed {
    my ($text) = @_;

    $text =~ s{
        ^:::[ \t]+oembed[ \t]*\n          # opening ::: oembed
        [ \t]*(https?://[^\n]+?)[ \t]*\n  # URL
        ^:::[ \t]*\n                      # closing :::
    }{
        my $url  = $1;
        my $html = fetch_oembed($url);
        $html
            ? qq(<div class="oembed">\n$html\n</div>\n)
            : qq(<div class="oembed oembed--failed">\n)
              . qq(<p><a href="$url">$url</a></p>\n)
              . qq(</div>\n);
    }gsmxe;

    return $text;
}

sub fetch_oembed {
    my ($url) = @_;

    my $endpoint = find_oembed_endpoint($url);
    unless ($endpoint) {
        log_warn("oEmbed: no endpoint found for $url");
        return undef;
    }

    my $oembed_url = $endpoint . '?url=' . uri_encode($url) . '&format=json';
    my $raw = fetch_url($oembed_url);
    unless ($raw) {
        log_warn("oEmbed: fetch failed for $oembed_url");
        return undef;
    }

    # Parse JSON safely using JSON::PP (S3)
    # Note: JSON::PP gives correct string values but the html field content
    # itself is still trusted as-is. A compromised or malicious provider
    # could return arbitrary HTML. Restrict OEMBED_PROVIDERS to trusted
    # hosts if this is a concern in your deployment.
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data || !defined $data->{html} ) {
        log_warn("oEmbed: JSON parse failed for $oembed_url: $@");
        return undef;
    }

    return $data->{html};
}

sub find_oembed_endpoint {
    my ($url) = @_;

    # Check known providers first
    for my $pattern ( keys %OEMBED_PROVIDERS ) {
        if ( $url =~ $pattern ) {
            my $ep = $OEMBED_PROVIDERS{$pattern};
            return $ep if $ep;
            last;  # Pattern matched but no endpoint - fall through to autodiscovery
        }
    }

    # Autodiscovery - fetch the page and look for oEmbed link tag
    my $page = fetch_url($url);
    return undef unless $page;

    if ( $page =~ m{<link[^>]+type=["']application/json\+oembed["'][^>]+href=["']([^"']+)["']}i
      || $page =~ m{<link[^>]+href=["']([^"']+)["'][^>]+type=["']application/json\+oembed["']}i )
    {
        return $1;
    }

    return undef;
}

sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

sub strip_tt_directives {
    my ($val) = @_;
    # Strip [% and %] as separate sequences rather than matched pairs.
    # This handles nested attempts like [% [% ... %] %] more robustly
    # than a non-recursive paired match.
    $val =~ s/\[%//g;
    $val =~ s/%\]//g;
    return $val;
}

sub interpolate_env {
    my ($val) = @_;
    # Only interpolate allowlisted environment variables (S5)
    $val =~ s{\$\{(\w+)\}}{
        $ENV_ALLOWLIST{$1} ? ( defined $ENV{$1} ? $ENV{$1} : '' ) : "\${$1}"
    }ge;
    return $val;
}

sub resolve_tt_vars {
    my ($defs) = @_;
    my %vars;

    for my $key ( keys %$defs ) {
        my $val = strip_tt_directives( $defs->{$key} );

        if ( $val =~ s/^scan:// ) {
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_scan($val);
        }
        elsif ( $val =~ s/^url:// ) {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            my $fetched = fetch_url($val);
            if ( defined $fetched ) {
                $fetched =~ s/^\s+|\s+$//g;
                $vars{$key} = $fetched;
            }
            else {
                log_warn("tt var fetch failed for $key: $val");
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

sub resolve_site_vars {
    return () unless -f $CONF_FILE;

    my $text = read_file($CONF_FILE);
    my %defs;

    while ( $text =~ /^(\w+)\s*:\s*(.+)$/mg ) {
        $defs{$1} = $2;
    }

    my %vars = resolve_tt_vars(\%defs);

    # Load navigation
    my $nav_file = $vars{nav_file}
        ? "$DOCROOT/" . $vars{nav_file}
        : "$LAZYSITE_DIR/nav.conf";

    $vars{nav} = parse_nav($nav_file);

    return %vars;
}

sub parse_nav {
    my ($nav_path) = @_;
    return [] unless -f $nav_path;

    open( my $fh, '<:utf8', $nav_path ) or return [];

    my @nav;
    my $current_parent = undef;

    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /^\s*#/;   # comment
        next if $line =~ /^\s*$/;   # blank line

        my $is_child = $line =~ /^\s+/;
        $line =~ s/^\s+|\s+$//g;    # trim

        my ( $label, $url ) = split /\s*\|\s*/, $line, 2;
        $label = defined $label ? $label : '';
        $label =~ s/^\s+|\s+$//g;
        $url   = defined $url   ? $url   : '';
        $url   =~ s/^\s+|\s+$//g;

        next unless length $label;

        if ( $is_child ) {
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

sub resolve_scan {
    my ($pattern) = @_;

    # Parse sort modifier: "sort=FIELD DIRECTION"
    my $sort_field = 'filename';
    my $sort_dir   = 'asc';
    if ( $pattern =~ s/\s+sort=(\w+)(?:\s+(asc|desc))?//i ) {
        $sort_field = lc($1);
        $sort_dir   = lc($2) if defined $2;
        $sort_field = 'filename'
            unless $sort_field =~ /^(date|title|filename)$/;
    }

    # Pattern must be docroot-relative starting with /
    return [] unless $pattern =~ m{^/};

    # Build filesystem glob pattern
    my $fs_pattern = $DOCROOT . $pattern;

    # Limit to .md files only
    return [] unless $fs_pattern =~ /\.md$/;

    my @files = glob($fs_pattern);

    # Limit to 200 files
    @files = @files[0..199] if @files > 200;

    my @pages;
    for my $path ( sort @files ) {
        # Realpath check
        my $real = realpath($path);
        next unless defined $real && index($real, $DOCROOT) == 0;
        next unless -f $real;

        # Read front matter
        my $raw = read_file($path);
        my ( $meta, undef ) = parse_yaml_front_matter($raw);

        # Derive URL
        ( my $url = $path ) =~ s{^\Q$DOCROOT\E}{};
        $url =~ s/\.md$//;
        $url =~ s{/index$}{/};

        # Date from front matter or mtime
        my $date = $meta->{date} || '';
        unless ( $date ) {
            my @st = stat($path);
            if ( @st ) {
                my @t = localtime( $st[9] );
                $date = sprintf("%04d-%02d-%02d",
                    $t[5] + 1900, $t[4] + 1, $t[3]);
            }
        }

        # Parse tags from front matter (YAML list, comma-separated, or single value)
        my $tags_raw = $meta->{tags} // '';
        my @tags;
        if ( ref $tags_raw eq 'ARRAY' ) {
            @tags = @$tags_raw;
        }
        elsif ( $tags_raw ) {
            @tags = map { s/^\s+|\s+$//gr } split /,/, $tags_raw;
        }

        push @pages, {
            url      => $url,
            title    => $meta->{title}    || '',
            subtitle => $meta->{subtitle} || '',
            date     => $date,
            tags     => \@tags,
            path     => $path,
        };
    }

    # Sort pages
    my @sorted = sort {
        my $va = $sort_field eq 'date'     ? $a->{date}
               : $sort_field eq 'title'    ? lc($a->{title})
               :                             $a->{path};
        my $vb = $sort_field eq 'date'     ? $b->{date}
               : $sort_field eq 'title'    ? lc($b->{title})
               :                             $b->{path};
        $sort_dir eq 'desc' ? $vb cmp $va : $va cmp $vb;
    } @pages;

    return \@sorted;
}

sub update_registries {
    return unless -d $REGISTRY_DIR;

    opendir( my $dh, $REGISTRY_DIR ) or return;
    my @templates = grep { /\.tt$/ } readdir($dh);
    closedir($dh);

    return unless @templates;

    # Check if any registry needs updating
    my $needs_update = 0;
    for my $tmpl (@templates) {
        ( my $output_name = $tmpl ) =~ s/\.tt$//;
        my $output_path = "$DOCROOT/$output_name";
        if ( !-f $output_path
            || ( time() - ( stat($output_path) )[9] ) >= $REGISTRY_TTL )
        {
            $needs_update = 1;
            last;
        }
    }
    return unless $needs_update;

    # Scan all source pages
    my @pages = scan_pages();
    my %site_vars = resolve_site_vars();

    my $tt = Template->new(
        ABSOLUTE => 1,
        ENCODING => 'utf8',
    ) or return;

    for my $tmpl (@templates) {
        ( my $output_name = $tmpl ) =~ s/\.tt$//;
        my $output_path  = "$DOCROOT/$output_name";
        my $tmpl_path    = "$REGISTRY_DIR/$tmpl";

        # Check this specific registry needs updating
        next if -f $output_path
            && ( time() - ( stat($output_path) )[9] ) < $REGISTRY_TTL;

        # Filter pages registered for this registry
        my $registry_name = $output_name;
        my @registered = grep {
            my $page = $_;
            grep { $_ eq $registry_name } @{ $page->{register} || [] }
        } @pages;

        my $vars = {
            %site_vars,
            pages => \@registered,
        };

        my $output = '';
        $tt->process( $tmpl_path, $vars, \$output ) or do {
            log_warn("Registry template error for $tmpl: " . $tt->error());
            next;
        };

        open( my $fh, '>:utf8', $output_path ) or do {
            log_warn("Cannot write registry $output_path: $!");
            next;
        };
        print $fh $output;
        close $fh;
    }
}

sub scan_pages {
    my @pages;

    # Find all .md and .url files recursively under docroot
    my @queue = ($DOCROOT);
    while ( my $dir = shift @queue ) {
        opendir( my $dh, $dir ) or next;
        for my $entry ( sort readdir($dh) ) {
            next if $entry =~ /^\./;
            my $path = "$dir/$entry";
            if ( -d $path ) {
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

                my ( $meta, undef ) = parse_yaml_front_matter($raw);
                next unless $meta->{register};

                # Get date from front matter or file mtime
                my $date = $meta->{date} || '';
                unless ( $date ) {
                    my @st = stat($path);
                    if ( @st ) {
                        my @t = localtime( $st[9] );
                        $date = sprintf("%04d-%02d-%02d",
                            $t[5] + 1900, $t[4] + 1, $t[3]);
                    }
                }

                # Derive URL from path
                ( my $url = $path ) =~ s{^\Q$DOCROOT\E}{};
                $url =~ s/\.md$//;
                $url =~ s{/index$}{/};

                push @pages, {
                    url      => $url,
                    title    => $meta->{title}    || '',
                    subtitle => $meta->{subtitle} || '',
                    date     => $date,
                    register => $meta->{register} || [],
                };
            }
        }
        closedir($dh);
    }

    return @pages;
}

sub render_content {
    my ( $meta, $html_body, $query ) = @_;
    $query //= {};

    # Content pass uses ABSOLUTE => 0 - the content body is a string reference
    # and should never need file access. ABSOLUTE => 1 would allow TT to follow
    # absolute paths found in the content, which causes parse errors on CSS etc.
    my $tt = Template->new(
        ABSOLUTE => 0,
        ENCODING => 'utf8',
    ) or die "Template error: " . Template->error() . "\n";

    my %site_vars = resolve_site_vars();
    my %page_vars = resolve_tt_vars( $meta->{tt_page_var} || {} );

    my $vars = {
        %site_vars,
        %page_vars,
        page_title        => $meta->{title}            || '',
        page_subtitle     => $meta->{subtitle}         || '',
        page_modified     => $meta->{page_modified}    || '',
        page_modified_iso => $meta->{page_modified_iso} || '',
        query             => $query,
    };

    # Protect <pre><code> blocks and inline <code> elements from TT processing
    my $protected_body = $html_body;
    my @code_blocks;
    $protected_body =~ s{(<pre><code[^>]*>)(.*?)(</code></pre>)}{
        my $placeholder = "CODEBLOCK_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;
    $protected_body =~ s{(<code>)(.*?)(</code>)}{
        my $placeholder = "CODEBLOCK_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;

    my $processed_body = '';
    $tt->process( \$protected_body, $vars, \$processed_body )
        or do {
            log_warn("TT content processing error: " . $tt->error() . " - using raw content");
            $processed_body = $protected_body;
        };

    # Restore protected code blocks
    for my $i ( 0 .. $#code_blocks ) {
        $processed_body =~ s/CODEBLOCK_${i}_END/$code_blocks[$i]/;
    }

    return ( $processed_body, $vars );
}

sub read_theme_cookie {
    my $cookie_str = $ENV{HTTP_COOKIE} // '';
    return '' unless $cookie_str;

    for my $pair ( split /;\s*/, $cookie_str ) {
        my ( $name, $val ) = split /=/, $pair, 2;
        $name =~ s/^\s+|\s+$//g;
        if ( $name eq 'lazysite_theme' ) {
            $val //= '';
            $val =~ s/^\s+|\s+$//g;
            # Sanitise - same as theme name from conf
            $val =~ s/[^a-zA-Z0-9_-]//g;
            return $val;
        }
    }
    return '';
}

sub get_layout_path {
    my ( $meta, $vars ) = @_;

    my $name = $meta->{layout} || '';

    unless ( $name ) {
        my $cookie_theme = read_theme_cookie();
        $name = $cookie_theme if $cookie_theme;
    }

    unless ( $name ) {
        $name = $vars->{theme} || '';
    }

    if ( $name ) {
        # Check if theme is a remote URL
        if ( $name =~ m{^https?://} ) {
            my ( $cached, $theme_key ) = fetch_remote_layout($name);
            return ( $cached, $theme_key ) if $cached;
            log_warn("Remote layout fetch failed for $name - using fallback");
            return ( undef, undef );  # signals render_template to use fallback
        }

        # Local theme/layout name - sanitise
        $name =~ s/[^a-zA-Z0-9_-]//g;
        $name ||= '';  # if sanitise stripped everything, fall back

        if ( $name ) {
            # Check themes directory first, then templates directory
            my $theme_path = "$THEMES_DIR/$name/view.tt";
            my $tmpl_path  = "$LAYOUT_DIR/$name.tt";

            return ( $theme_path, undef ) if -f $theme_path;
            return ( $tmpl_path, undef )  if -f $tmpl_path;

            log_warn("get_layout_path: layout '$name' not found,"
                . " falling back to default");
        }
    }

    return ( ( -f $LAYOUT ? $LAYOUT : undef ), undef );
}

sub fetch_remote_layout {
    my ($url) = @_;

    # Derive a safe cache filename from the URL
    my $cache_key = $url;
    $cache_key =~ s{https?://}{};
    $cache_key =~ s{[^a-zA-Z0-9_-]}{_}g;
    $cache_key = substr($cache_key, 0, 200);  # limit length

    my $cache_path = "$LAYOUT_CACHE_DIR/$cache_key.tt";

    # Serve from cache if fresh (use $REMOTE_TTL - same as remote pages)
    if ( -f $cache_path ) {
        my @st = stat($cache_path);
        if ( @st && (time() - $st[9]) < $REMOTE_TTL ) {
            return ( $cache_path, $cache_key );
        }
    }

    # Fetch remote layout
    my $content = fetch_url($url);
    unless ( defined $content && length $content ) {
        # Return stale cache if available
        return -f $cache_path ? ( $cache_path, $cache_key ) : ( undef, undef );
    }

    # Write to cache
    make_path($LAYOUT_CACHE_DIR) unless -d $LAYOUT_CACHE_DIR;
    open( my $fh, '>:utf8', $cache_path ) or do {
        log_warn("Cannot write layout cache $cache_path: $!");
        return ( undef, undef );
    };
    print $fh $content;
    close $fh;

    # Attempt to fetch theme.json manifest from same directory
    my $base_url = $url;
    $base_url =~ s{/[^/]+$}{};  # strip filename to get directory URL
    my $manifest_url = "$base_url/theme.json";
    my $manifest_raw = fetch_url($manifest_url);

    if ( defined $manifest_raw ) {
        my $manifest = eval { decode_json($manifest_raw) };
        if ( $manifest && ref $manifest->{files} eq 'ARRAY' ) {
            my $asset_dir = "$DOCROOT/lazysite-assets/$cache_key";
            make_path($asset_dir) unless -d $asset_dir;

            for my $file ( @{ $manifest->{files} } ) {
                next if $file eq 'view.tt';  # already fetched
                next if $file =~ /\.\./;     # no traversal

                my $file_url     = "$base_url/$file";
                my $file_content = fetch_url($file_url);
                next unless defined $file_content;

                my $file_path = "$asset_dir/$file";
                my $file_dir  = dirname($file_path);
                make_path($file_dir) unless -d $file_dir;

                open( my $afh, '>:raw', $file_path ) or next;
                print $afh $file_content;
                close $afh;
            }
        }
    }

    return ( $cache_path, $cache_key );
}

sub render_template {
    my ( $meta, $html_body, $query ) = @_;
    $query //= {};

    my ( $processed_body, $vars ) = render_content( $meta, $html_body, $query );

    # Second include pass - resolves :::include blocks with TT-variable paths
    if ( $meta->{_md_path} ) {
        $processed_body = convert_fenced_include( $processed_body, $meta->{_md_path}, $meta );
    }

    my ( $layout, $theme_key ) = get_layout_path( $meta, $vars );

    # Set theme_assets path for remote themes
    if ( defined $theme_key ) {
        $vars->{theme_assets} = "/lazysite-assets/$theme_key";
    }

    $vars->{content} = $processed_body;
    my $output = '';

    if ( !defined $layout ) {
        # No layout found - use built-in fallback directly
        log_warn("No view.tt found - using built-in fallback");
        my $tt_fallback = Template->new( ENCODING => 'utf8' )
            or do {
                log_warn("Cannot create fallback TT instance - serving bare content");
                return $processed_body;
            };

        $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
            or do {
                log_warn("Fallback layout error: " . $tt_fallback->error()
                    . " - serving bare content");
                return $processed_body;
            };

        return $output;
    }

    # Determine if layout is remote (from cache dir) - sandbox it
    my $is_remote = index($layout, $LAYOUT_CACHE_DIR) == 0;

    my $tt_layout = $is_remote
        ? Template->new(
            ABSOLUTE  => 1,      # needed to read cache path
            RELATIVE  => 0,
            EVAL_PERL => 0,      # no embedded Perl
            ENCODING  => 'utf8',
        )
        : Template->new(
            ABSOLUTE => 1,
            ENCODING => 'utf8',
        );

    unless ( $tt_layout ) {
        log_warn("Cannot create TT instance - serving bare content");
        return $processed_body;
    }

    # Try specified layout
    $tt_layout->process( $layout, $vars, \$output )
        or do {
            log_warn("Layout error ($layout): " . $tt_layout->error()
                . " - using built-in fallback");
            $output = '';

            # Try built-in fallback layout
            my $tt_fallback = Template->new( ENCODING => 'utf8' )
                or do {
                    log_warn("Cannot create fallback TT instance - serving bare content");
                    return $processed_body;
                };

            $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
                or do {
                    log_warn("Fallback layout error: " . $tt_fallback->error()
                        . " - serving bare content");
                    return $processed_body;
                };
        };

    return $output;
}

# --- Content type cache ---

sub ct_cache_path {
    my ($base) = @_;
    my $key = $base;
    $key =~ s{/}{:}g;
    return "$CT_CACHE_DIR/$key.ct";
}

sub write_ct {
    my ( $base, $content_type ) = @_;

    # Default or undef content type - clean stale .ct if present
    if ( !defined $content_type || $content_type eq 'text/html; charset=utf-8' ) {
        my $ct_path = ct_cache_path($base);
        unlink $ct_path if -f $ct_path;
        return;
    }

    make_path($CT_CACHE_DIR) unless -d $CT_CACHE_DIR;

    my $ct_path = ct_cache_path($base);
    open( my $fh, '>:utf8', $ct_path ) or do {
        log_warn("Cannot write content type cache $ct_path: $!");
        return;
    };
    print $fh $content_type;
    close $fh;
}

sub read_ct {
    my ($base) = @_;
    my $ct_path = ct_cache_path($base);
    return undef unless -f $ct_path;
    open( my $fh, '<:utf8', $ct_path ) or return undef;
    my $ct = <$fh>;
    close $fh;
    $ct =~ s/^\s+|\s+$//g if defined $ct;
    return $ct || undef;
}

sub html_to_base {
    my ($html_path) = @_;
    my $base = $html_path;
    $base =~ s{^\Q$DOCROOT\E/}{};
    $base =~ s/\.html$//;
    return $base;
}

sub write_html {
    my ( $html_path, $page ) = @_;

    # Skip cache write if LAZYSITE_NOCACHE is set
    return if $ENV{LAZYSITE_NOCACHE};

    # Refuse to write zero-byte content - protects against empty cache
    # files that would permanently block regeneration via DirectoryIndex
    unless ( length($page) ) {
        log_warn("write_html: refusing to write zero-byte content to $html_path");
        return;
    }

    # Verify html_path resolves within docroot - guard against symlink attacks (S1)
    # Use the parent directory for the check since the file may not exist yet.
    # Note: narrow TOCTOU gap exists between this check and the subsequent open() -
    # a symlink created after the check would not be caught. O_NOFOLLOW via sysopen
    # would close this gap but adds complexity not warranted in this deployment context.
    my $check_path = -e $html_path ? $html_path : dirname($html_path);
    my $real = realpath($check_path);
    if ( !defined $real || index( $real, $DOCROOT ) != 0 ) {
        log_warn("write_html: path $html_path resolves outside docroot - write refused");
        return;
    }

    my $dir = dirname($html_path);
    unless ( -d $dir ) {
        make_path($dir);
        # Set group to match docroot and apply setgid bit so new files
        # and subdirectories inherit the group automatically
        my $gid = ( stat($DOCROOT) )[5];
        chown -1, $gid, $dir;
        chmod 0775 | 02000, $dir;  # 02000 = setgid bit
    }

    open( my $fh, '>:utf8', $html_path ) or do {
        log_warn("Cannot write cache file $html_path: $! "
            . "- page will render uncached. "
            . "Fix with: chown \$(stat -c '%U' $DOCROOT):\$(stat -c '%G' $DOCROOT) $dir "
            . "&& chmod g+w $dir");
        return;
    };
    print $fh $page;
    close $fh;
}

# --- Output ---

sub output_page {
    my ( $content, $content_type ) = @_;
    $content_type //= 'text/html; charset=utf-8';
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\n";
    print "Content-type: $content_type\n\n";
    print $content;
}

sub forbidden {
    binmode( STDOUT, ':utf8' );
    print "Status: 403 Forbidden\n";
    print "Content-type: text/plain; charset=utf-8\n\n";
    print "403 Forbidden\n";
}

sub not_found {
    my ($uri) = @_;

    my $md_path   = "$DOCROOT/404.md";
    my $html_path = "$DOCROOT/404.html";

    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $page = is_fresh( $html_path, $md_path )
            ? read_file($html_path)
            : process_md( $md_path, $html_path );
        print "Status: 404 Not Found\n";
        print "Content-type: text/html; charset=utf-8\n\n";
        print $page;
        return;
    }

    # Bare fallback if no 404.md exists yet
    print "Status: 404 Not Found\n";
    print "Content-type: text/html; charset=utf-8\n\n";
    print "<p>Page not found: <code>$uri</code></p>\n";
}

# --- Utilities ---

sub read_file {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub log_warn {
    my ($msg) = @_;
    print STDERR "lazysite: $msg\n";
}

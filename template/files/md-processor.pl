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

my $LAYOUT        = "$DOCROOT/templates/layout.tt";
my $LAYOUT_VARS   = "$DOCROOT/templates/layout.vars";
my $REGISTRY_DIR  = "$DOCROOT/templates/registries";
my $REMOTE_TTL    = 3600;  # seconds before remote content is refetched (default 1 hour)
my $REGISTRY_TTL  = 14400; # seconds before registries are regenerated (default 4 hours)

# Allowlist of CGI environment variables that may be interpolated in layout.vars
# Note: HTTP_HOST is intentionally excluded - it is request-supplied and untrusted.
# Use SERVER_NAME for host-based URL construction.
my %ENV_ALLOWLIST = map { $_ => 1 } qw(
    SERVER_NAME SERVER_PORT REQUEST_SCHEME HTTPS
    DOCUMENT_ROOT SERVER_ADMIN
);

# --- Main ---

main();

sub main {
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Strip query string
    $uri =~ s/\?.*$//;

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

    # Fast path: .md exists and cache is fresh by mtime
    if ( @md_stat && @html_stat ) {
        if ( $html_stat[9] >= $md_stat[9] ) {
            # mtime fresh - serve cache immediately, no peek_ttl needed
            output_page( read_file($html_path) );
            return;
        }
        # mtime stale - check for page-level TTL override before regenerating
        my $ttl = peek_ttl($md_path);
        if ( defined $ttl && is_fresh_ttl_val_stat( \@html_stat, $ttl ) ) {
            output_page( read_file($html_path) );
            return;
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
        my $page = process_md( $md_path, $html_path );
        output_page($page);
        return;
    }

    # Found .url - fetch remote content
    if ( -f $url_path ) {
        my $real = realpath($url_path);
        if ( !defined $real || index( $real, $DOCROOT ) != 0 ) {
            not_found($uri);
            return;
        }
        my $page = process_url( $url_path, $html_path );
        output_page($page);
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
    my ( $md_path, $html_path ) = @_;

    my $raw             = read_file($md_path);
    my ( $meta, $body ) = parse_yaml_front_matter($raw);
    my $converted       = convert_fenced_divs($body);
    my $converted2      = convert_fenced_code($converted);
    my $converted3      = convert_oembed($converted2);
    my $html_body       = convert_md($converted3);
    my $page            = render_template( $meta, $html_body );
    $page               = convert_dt_links($page);

    write_html( $html_path, $page );
    eval { update_registries() };
    log_warn("Registry update failed: $@") if $@;

    return $page;
}

sub process_url {
    my ( $url_path, $html_path ) = @_;

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
    my $converted  = convert_fenced_divs($body);
    my $converted2 = convert_fenced_code($converted);
    my $converted3 = convert_oembed($converted2);
    my $html_body  = convert_md($converted3);
    my $page       = render_template( $meta, $html_body );
    $page          = convert_dt_links($page);

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
        agent      => 'lazydev/1.0',
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
        if ( $yaml =~ /^register\s*:\s*\n((?:[ \t]*-[^\n]*\n)*)/m ) {
            my $block = $1;
            my @registries;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @registries, strip_tt_directives($1);
            }
            $meta{register} = \@registries;
        }

        # Parse tt_page_var block (indented key: value pairs)
        if ( $yaml =~ /^tt_page_var\s*:\s*\n((?:[ \t]+\S[^\n]*\n)*)/m ) {
            my $block = $1;
            my %tt_vars;
            while ( $block =~ /^[ \t]+(\w+)\s*:\s*(.+)$/mg ) {
                $tt_vars{$1} = $2;
            }
            $meta{tt_page_var} = \%tt_vars;
        }

        # Parse scalar key: value pairs (skip tt_page_var and register blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            # Strip TT directives from all scalar values including title and subtitle
            $meta{$1} = strip_tt_directives($2);
        }
    }

    return ( \%meta, $text );
}

sub convert_fenced_divs {
    my ($text) = @_;

    $text =~ s{
        ^:::[ \t]+(\S+)[ \t]*\n  # opening ::: classname
        (.*?)                     # content
        ^:::[ \t]*\n              # closing :::
    }{
        my $class = $1;
        my $body  = $2;
        # Reject class names containing unsafe characters (S4)
        # Valid: word chars and hyphens only, must start with a word char
        if ( $class =~ /\A[\w][\w-]*\z/ ) {
            qq(<div class="$class">\n${body}</div>\n);
        }
        else {
            log_warn("Fenced div: rejected unsafe class name '$class'");
            $body;
        }
    }gsmxe;

    return $text;
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

        if ( $val =~ s/^url:// ) {
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
    return () unless -f $LAYOUT_VARS;

    my $text = read_file($LAYOUT_VARS);
    my %defs;

    while ( $text =~ /^(\w+)\s*:\s*(.+)$/mg ) {
        $defs{$1} = $2;
    }

    return resolve_tt_vars(\%defs);
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

                # Derive URL from path
                ( my $url = $path ) =~ s{^\Q$DOCROOT\E}{};
                $url =~ s/\.md$//;
                $url =~ s{/index$}{/};

                push @pages, {
                    url      => $url,
                    title    => $meta->{title}    || '',
                    subtitle => $meta->{subtitle} || '',
                    register => $meta->{register} || [],
                };
            }
        }
        closedir($dh);
    }

    return @pages;
}

sub render_template {
    my ( $meta, $html_body ) = @_;

    my $tt = Template->new(
        ABSOLUTE => 1,
        ENCODING => 'utf8',
    ) or die "Template error: " . Template->error() . "\n";

    # Site vars are base - page vars override
    my %site_vars = resolve_site_vars();
    my %page_vars = resolve_tt_vars( $meta->{tt_page_var} || {} );

    my $vars = {
        %site_vars,
        %page_vars,
        page_title    => $meta->{title}    || '',
        page_subtitle => $meta->{subtitle} || '',
    };

    # First pass: process TT tags in the content body
    my $processed_body = '';
    $tt->process( \$html_body, $vars, \$processed_body )
        or do {
            log_warn("TT content processing error: " . $tt->error() . " - using raw content");
            $processed_body = $html_body;
        };

    # Second pass: render full layout with processed content
    $vars->{content} = $processed_body;
    my $output = '';
    $tt->process( $LAYOUT, $vars, \$output )
        or die "Template process error: " . $tt->error() . "\n";

    return $output;
}

sub write_html {
    my ( $html_path, $page ) = @_;

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
    my ($content) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\n";
    print "Content-type: text/html; charset=utf-8\n\n";
    print $content;
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
    print STDERR "lazydev: $msg\n";
}

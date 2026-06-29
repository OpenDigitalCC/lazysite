#!/usr/bin/perl
use strict;
use warnings;
use Text::MultiMarkdown;
use Template;
use File::Basename qw(dirname);
use File::Path qw(make_path);
# P-1: LWP::UserAgent is require()d lazily inside fetch_url / fetch_oembed
# / fetch_remote_layout. These paths are rare relative to cache-hit
# traffic, so deferring the ~20ms of LWP module load keeps the hot path
# fast.
use Cwd qw(realpath);
use Encode qw(decode);
use Socket qw(inet_aton inet_ntoa);
use URI;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use POSIX qw(strftime);

my $LOG_COMPONENT = 'processor';

# --- Plugin descriptor ---

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'lazysite',
        name        => 'Site Configuration',
        description => 'Core lazysite.conf settings: site identity, layout, theme, search, and manager',
        version     => '1.0',
        config_file => '',
        # SM044: layouts_repo is in config_keys so action_plugin_save
        # treats it as write-allowed for the site plugin.
        #
        # SM068: layouts_repo now also appears in config_schema as
        # a readonly_with_link entry — the operator sees its current
        # value on Config with a link to /manager/themes where it's
        # editable. SITE_SCHEMA in config.md duplicates this; they
        # must stay in sync until SM042 unifies them.
        config_keys => [qw(site_name site_url layout theme layouts_repo
                           nav_file search_default webdav_enabled
                           manager manager_path manager_groups)],
        config_schema => [
            { key => 'site_name', label => 'Site name', type => 'text',
              default => 'My Site', required => JSON::PP::true() },
            { key => 'site_url', label => 'Site URL', type => 'text',
              default => '${REQUEST_SCHEME}://${SERVER_NAME}' },
            # SM044: dropdown_layouts / dropdown_themes_for_active_layout
            # are dynamically-populated selects rendered by config.md's
            # JS. Options come from manager-api endpoints
            # (layouts-available / themes-for-layout). The 'text' fallback
            # in renderSiteForm keeps these sensible on older UIs.
            # The active layout/theme switcher lives on /manager/appearance;
            # Config shows them read-only with a link there (was inline
            # dropdowns here pre-Appearance).
            { key => 'layout', label => 'Active layout',
              type => 'readonly_with_link', default => '',
              link_href => '/manager/appearance',
              link_label => 'Manage on Appearance' },
            { key => 'theme',  label => 'Active theme',
              type => 'readonly_with_link', default => '',
              link_href => '/manager/appearance',
              link_label => 'Manage on Appearance' },
            { key => 'layouts_repo', label => 'Layouts repo',
              type => 'readonly_with_link', default => '',
              link_href => '/manager/appearance',
              link_label => 'Edit on Appearance' },
            { key => 'nav_file', label => 'Navigation file', type => 'text',
              default => 'lazysite/nav.conf' },
            { key => 'search_default', label => 'Pages searchable by default', type => 'select',
              options => ['true', 'false'], default => 'true' },
            { key => 'manager', label => 'Manager', type => 'select',
              options => ['disabled', 'enabled'], default => 'disabled' },
            { key => 'manager_path', label => 'Manager URL path', type => 'text',
              default => '/manager',
              show_when => { key => 'manager', value => ['enabled'] } },
            { key => 'manager_groups', label => 'Manager access groups', type => 'text',
              default => '',
              show_when => { key => 'manager', value => ['enabled'] } },
            { key => 'webdav_enabled', label => 'WebDAV publishing', type => 'select',
              options => ['disabled', 'enabled'], default => 'disabled' },
        ],
        actions => [],
    });
    exit 0;
}

# --- Configuration ---

my $DOCROOT     = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

my $LAZYSITE_DIR  = "$DOCROOT/lazysite";
my $LAZYSITE_URI  = "/lazysite";
my $PREVIEW_COOKIE = 'lzs_preview';   # SM071: theme/layout preview cookie

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
# D013: layouts/ is the new structural root. A local layout lives at
# $LAYOUT_DIR/NAME/layout.tt with optional $LAYOUT_DIR/NAME/layout.json
# metadata. Themes nest under layouts/NAME/themes/THEME/. No flat-template
# fallback ($LAZYSITE_DIR/templates/*.tt) and no default view.tt path —
# if no layout is installed, the embedded $FALLBACK_LAYOUT is the sole
# fallback.
my $LAYOUT_DIR    = "$LAZYSITE_DIR/layouts";
my $REGISTRY_DIR  = "$LAZYSITE_DIR/templates/registries";
my $MANAGER_LAYOUT = "$LAZYSITE_DIR/manager/layout.tt";
my $REMOTE_TTL       = 3600;  # seconds before remote content is refetched (default 1 hour)
my $REGISTRY_TTL     = 14400; # seconds before registries are regenerated (default 4 hours)
# SM091: the cache base normally lives under the docroot, but a read-only
# browse (the dev server's --auto-index) can relocate it off the docroot via
# LAZYSITE_CACHE_DIR so pointing the processor at an arbitrary tree writes
# nothing into it. Unset (production / tests) keeps the original location.
my $CACHE_BASE       = $ENV{LAZYSITE_CACHE_DIR} || "$LAZYSITE_DIR/cache";
my $LAYOUT_CACHE_DIR = "$CACHE_BASE/layouts";
my $CT_CACHE_DIR     = "$CACHE_BASE/ct";
my $TT_COMPILE_DIR   = "$CACHE_BASE/tt";   # P-4 TT on-disk compile cache
my %AUTH_CONTEXT;    # populated by main() auth check, read by render_content()

# Built-in fallback template - used when no layout.tt is found
my $FALLBACK_LAYOUT = <<'END_FALLBACK';
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    [% IF page_subtitle %]<meta name="description" content="[% page_subtitle | html %]">[% END %]
    <title>[% page_title %][% IF site_name %]  -  [% site_name %][% END %]</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px;
               margin: 2rem auto; padding: 0 1rem; color: #333; }
        .site-bar { display: flex; align-items: center; gap: 0.75rem;
                    padding: 0.5rem 0; font-size: 0.85rem; flex-wrap: wrap; }
        .site-bar a { color: #0066cc; text-decoration: none; font-weight: 600; }
        .site-bar a:hover { text-decoration: underline; }
        .site-bar .edit-btn { font-size: 0.8rem; padding: 0.15rem 0.5rem;
               border: 1px solid #ccc; border-radius: 3px; background: #f9f9f9;
               color: #555; text-decoration: none; cursor: pointer; font-weight: 400; }
        .site-bar .edit-btn:hover { background: #eee; color: #333; }
        .site-bar form { display: flex; gap: 0.3rem; }
        .site-bar input[type="search"] { padding: 0.2rem 0.4rem; font-size: 0.8rem;
               border: 1px solid #ccc; border-radius: 3px; width: 140px; }
        .site-bar button { padding: 0.2rem 0.5rem; font-size: 0.8rem; cursor: pointer; }
        hr.site-rule { border: none; border-top: 1px solid #eee; margin: 0 0 1.5rem; }
        .nav-link { margin-right: 1rem; color: #0066cc; text-decoration: none; }
        .nav-link:hover { text-decoration: underline; }
        .nav-child { margin-right: 0.75rem; font-size: 0.85rem; }
        .nav-link[aria-current="page"] { font-weight: 600; }
        .nav-group {
            font-size: 0.7rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: #888;
            padding: 0.5rem 0 0.2rem;
            margin-right: 0.75rem;
            display: inline-block;
        }
        h1 { border-bottom: 1px solid #eee; padding-bottom: 0.5rem; }
        pre { background: #f5f5f5; padding: 1rem; overflow-x: auto; }
        code { background: #f5f5f5; padding: 0.2em 0.4em; }
        footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #eee;
                 font-size: 0.85rem; color: #888; }
        a { color: #0066cc; }
    </style>
</head>
<body>
<div class="site-bar" id="site-bar">
    <a href="/">[% IF site_name %][% site_name %][% ELSE %]Home[% END %]</a>
    <!-- SM099: client-toggled so the cached page shows the right control. Both
         start hidden; the injected auth-sync script reveals one from the lzs_session
         marker cookie. -->
    <a href="/cgi-bin/lazysite-auth.pl?action=logout" data-ls-auth-out style="font-size:0.8rem;color:#888;font-weight:400;margin-left:auto;display:none;">Sign out</a>
    <a href="/login" data-ls-auth-in style="font-size:0.8rem;margin-left:auto;font-weight:400;display:none;">Sign in</a>
    <noscript><a href="/login" style="font-size:0.8rem;margin-left:auto;font-weight:400;">Sign in</a></noscript>
    <form action="/search-results" method="get">
        <input type="search" name="q" placeholder="Search..." aria-label="Search">
        <button type="submit">Go</button>
    </form>
</div>
<hr class="site-rule" id="site-rule">
<script>if(window!==window.top){var b=document.getElementById('site-bar');var r=document.getElementById('site-rule');if(b)b.style.display='none';if(r)r.style.display='none';}</script>
[% IF nav.size %]
<nav style="margin-bottom:1.5rem;padding-bottom:0.75rem;border-bottom:1px solid #eee;font-size:0.9rem;">
  [% FOREACH item IN nav %]
    [%# Three cases, distinguished by whether item.url is set and
        whether children exist:
          - url present                : leaf link or clickable parent
          - url empty/absent           : group heading (not a link) %]
    [% IF item.url %]
    <a href="[% item.url %]" class="nav-link"[% IF request_uri == item.url %] aria-current="page"[% END %]>[% item.label %]</a>
    [% ELSE %]
    <span class="nav-group">[% item.label %]</span>
    [% END %]
    [% IF item.children %]
      [% FOREACH child IN item.children %]
      <a href="[% child.url %]" class="nav-link nav-child"[% IF request_uri == child.url %] aria-current="page"[% END %]>[% child.label %]</a>
      [% END %]
    [% END %]
  [% END %]
</nav>
[% END %]
<main>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
    [% content %]
</main>
<footer>
    [% IF page_modified %]
    <p style="font-size:0.8rem;color:#aaa;">Last updated: <time datetime="[% page_modified_iso %]">[% page_modified %]</time></p>
    [% END %]
    <p>Rendered by <a href="https://lazysite.io">lazysite</a>
    [% IF site_name %]- [% site_name %][% END %]
    - no layout.tt found, using built-in fallback</p>
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

# --- Auth ---

{
    # F7 (D007): single-pass front-matter peek, memoised per
    # request. Callers in main() previously opened the .md file up
    # to five times (peek_auth, peek_payment, peek_query_params,
    # peek_ttl, peek_content_type); now the first peek reads the
    # file, the rest hit this cache. Cache key is (path, mtime) so
    # an mtime change between peeks (shouldn't happen within one
    # request, but be safe) invalidates.
    my %_peek_cache;

    sub _reset_peek_cache { %_peek_cache = () }

    sub _peek_md {
        my ($path) = @_;
        return {} unless $path;
        my @st = stat($path);
        return {} unless @st;
        my $key = "$path:$st[9]";
        return $_peek_cache{$key} if exists $_peek_cache{$key};

        my %m;
        my @groups;
        my @qp;
        my ( $in_groups, $in_qp );

        open my $fh, '<:utf8', $path or do {
            $_peek_cache{$key} = \%m;
            return \%m;
        };
        while ( my $line = <$fh> ) {
            last if $. > 1 && $line =~ /^---/;

            # scalar keys
            if    ( $line =~ /^auth\s*:\s*(\w+)/i )          { $m{auth} = lc $1 }
            elsif ( $line =~ /^ttl\s*:\s*(\d+)/ )            { $m{ttl} = $1 }
            elsif ( $line =~ /^api\s*:\s*true/i )            { $m{api} = 1 }
            elsif ( $line =~ /^raw\s*:\s*true/i )            { $m{raw} = 1 }
            elsif ( $line =~ /^content_type\s*:\s*(.+)/ )    {
                ( my $v = $1 ) =~ s/^\s+|\s+$//g;
                $m{content_type} = $v;
            }

            # payment.* scalar keys
            for my $pk (qw(payment payment_amount payment_currency
                           payment_network payment_address
                           payment_asset payment_description)) {
                if ( $line =~ /^\Q$pk\E\s*:\s*(.+)$/ ) {
                    ( my $v = $1 ) =~ s/\s+$//;
                    $m{$pk} = $v;
                }
            }

            # auth_groups: block
            if ( $line =~ /^auth_groups\s*:\s*$/ ) {
                $in_groups = 1; $in_qp = 0; next;
            }
            if ( $in_groups ) {
                if ( $line =~ /^\s+-\s+(.+)$/ ) {
                    ( my $g = $1 ) =~ s/^\s+|\s+$//g;
                    push @groups, $g;
                    next;
                }
                $in_groups = 0 if $line !~ /^\s/;
            }

            # query_params: block
            if ( $line =~ /^query_params\s*:\s*$/ ) {
                $in_qp = 1; $in_groups = 0; next;
            }
            if ( $in_qp ) {
                if ( $line =~ /^[ \t]+-[ \t]*(\S+)/ ) {
                    push @qp, $1;
                    next;
                }
                $in_qp = 0 if $line !~ /^\s/;
            }
        }
        close $fh;

        $m{groups}       = \@groups if @groups;
        $m{query_params} = \@qp     if @qp;

        $_peek_cache{$key} = \%m;
        return \%m;
    }
}

sub peek_auth {
    my ($path) = @_;
    my $m = _peek_md($path);
    # Matches the old peek_auth contract: hashref with `auth`
    # (possibly undef) and `groups` (always arrayref, possibly
    # empty). peek_auth was the only peek that returned {} on
    # "no file" rather than undef; preserve that.
    return {} unless $path && -f $path;
    return {
        auth   => $m->{auth},
        groups => $m->{groups} // [],
    };
}

sub check_auth {
    my ( $uri, $auth_meta, $site_vars ) = @_;

    my $auth_level = $auth_meta->{auth}
        || $site_vars->{auth_default}
        || 'none';

    # Login page always public
    my $redirect_path = $site_vars->{auth_redirect} || '/login';
    return { ok => 1 } if index( $uri, $redirect_path ) == 0;

    # Manager pages have their own access control - skip auth_default enforcement
    # but still read auth headers so TT vars are populated
    my $manager_path = $site_vars->{manager_path} || '/manager';
    if ( index( $uri, "$manager_path/" ) == 0 || $uri eq $manager_path ) {
        $auth_level = 'none';
    }

    # Convert header names to env var format (X-Remote-User -> HTTP_X_REMOTE_USER)
    my $make_env = sub {
        my $h = shift;
        $h = 'HTTP_' . uc($h);
        $h =~ s/-/_/g;
        return $h;
    };

    my $auth_user   = $ENV{ $make_env->( $site_vars->{auth_header_user}   || 'X-Remote-User' ) }   // '';
    my $auth_name   = $ENV{ $make_env->( $site_vars->{auth_header_name}   || 'X-Remote-Name' ) }   // '';
    my $auth_email  = $ENV{ $make_env->( $site_vars->{auth_header_email}  || 'X-Remote-Email' ) }  // '';
    my $auth_groups = $ENV{ $make_env->( $site_vars->{auth_header_groups} || 'X-Remote-Groups' ) } // '';

    my $authenticated = $auth_user ne '' ? 1 : 0;

    # For 'none' pages, return auth context without enforcement
    if ( $auth_level eq 'none' ) {
        return {
            ok            => 1,
            auth_user     => $auth_user,
            auth_name     => $auth_name,
            auth_email    => $auth_email,
            auth_groups   => [ split /\s*,\s*/, $auth_groups ],
            authenticated => $authenticated,
        };
    }

    if ( !$authenticated && $auth_level eq 'required' ) {
        my $next = uri_encode($uri);
        return { redirect => "$redirect_path?next=$next" };
    }

    # Group check
    my @required = @{ $auth_meta->{groups} // [] };
    if ( $authenticated && @required ) {
        my %user_groups = map { lc($_) => 1 } split /\s*,\s*/, $auth_groups;
        my $in_group = grep { $user_groups{ lc($_) } } @required;
        unless ($in_group) {
            return {
                forbidden            => 1,
                auth_user            => $auth_user,
                auth_name            => $auth_name,
                auth_denied_reason   => 'insufficient_groups',
                auth_required_groups => \@required,
            };
        }
    }

    return {
        ok            => 1,
        auth_user     => $auth_user,
        auth_name     => $auth_name,
        auth_email    => $auth_email,
        auth_groups   => [ split /\s*,\s*/, $auth_groups ],
        authenticated => $authenticated,
    };
}

sub _is_manager {
    my ( $site_vars, $auth_user, $auth_groups ) = @_;
    return 0 unless $auth_user;
    my $manager_groups = $site_vars->{manager_groups} // '';
    $manager_groups =~ s/^\s+|\s+$//g;
    if ( !length $manager_groups ) {
        # L-3: config advisory, not an operational warning. Under CGI
        # every request is a new process, so the "once per process"
        # closure-state trick from the earlier revision just produced
        # one WARN per hit. Log at DEBUG so noisy production logs don't
        # carry it; the dev server surfaces it once at startup.
        log_event('DEBUG', '-',
            'manager_groups not set - any authenticated user has manager access',
            suggestion => 'set manager_groups in lazysite.conf');
        return 1;
    }
    my %user_groups = map { lc($_) => 1 } split /\s*,\s*/, ( $auth_groups // '' );
    return scalar grep { $user_groups{ lc($_) } }
        split /\s*,\s*/, $manager_groups;
}

sub serve_403 {
    my ($auth_result) = @_;
    my $md_path   = "$DOCROOT/403.md";

    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $html_path = "$DOCROOT/403.html";
        my $page = process_md( $md_path, $html_path, (stat($md_path))[9], {} );
        print "Status: 403 Forbidden\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print $page;
    }
    else {
        print "Status: 403 Forbidden\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print "<!DOCTYPE html><html><head><title>403 Forbidden</title></head><body>";
        print "<h1>Access Denied</h1>";
        if ( ( $auth_result->{auth_denied_reason} // '' ) eq 'insufficient_groups' ) {
            print "<p>You do not have permission to view this page.</p>";
        }
        else {
            print "<p>Authentication required.</p>";
        }
        print "</body></html>";
    }
}

# --- Payment ---

my %PAYMENT_CONTEXT;  # populated by main(), read by render_content()
my %PREVIEW_CONTEXT;  # SM071: preview layout/theme override, set by main()

sub peek_payment {
    my ($path) = @_;
    my $m = _peek_md($path);
    my %out;
    for my $k (qw(payment payment_amount payment_currency
                  payment_network payment_address
                  payment_asset payment_description)) {
        $out{$k} = $m->{$k} if defined $m->{$k};
    }
    return \%out;
}

sub check_payment {
    my ( $uri, $payment_meta, $auth_result, $site_vars ) = @_;

    return { ok => 1 } unless
        ( $payment_meta->{payment} // '' ) eq 'required';

    # Check group bypass - auth_groups in payment_meta
    my @bypass_groups = @{ $payment_meta->{auth_groups} // [] };
    if ( @bypass_groups && $auth_result->{authenticated} ) {
        my %user_groups = map { lc($_) => 1 }
            @{ $auth_result->{auth_groups} // [] };
        my $bypassed = grep { $user_groups{ lc($_) } } @bypass_groups;
        return { ok => 1, bypassed => 1 } if $bypassed;
    }

    # Check payment proof header
    my $verified_header = $site_vars->{payment_header_verified}
        || 'X-Payment-Verified';
    my $verified_env = 'HTTP_' . uc($verified_header);
    $verified_env =~ s/-/_/g;

    my $verified = $ENV{$verified_env} // '';
    if ( $verified eq '1' ) {
        my $payer_header = $site_vars->{payment_header_payer}
            || 'X-Payment-Payer';
        my $payer_env = 'HTTP_' . uc($payer_header);
        $payer_env =~ s/-/_/g;
        return {
            ok    => 1,
            paid  => 1,
            payer => $ENV{$payer_env} // '',
        };
    }

    return {
        payment_required => 1,
        amount           => $payment_meta->{payment_amount}       // '0',
        currency         => $payment_meta->{payment_currency}     // 'USD',
        network          => $payment_meta->{payment_network}      // 'base',
        address          => $payment_meta->{payment_address}      // '',
        asset            => $payment_meta->{payment_asset}        // '',
        description      => $payment_meta->{payment_description}  // '',
    };
}

sub serve_402 {
    my ($payment_result) = @_;

    # Build x402 payment response header
    # Assumption: amount is in human-readable decimal (e.g. 0.01 USD)
    # Convert to smallest unit assuming USDC (6 decimals)
    my $amount_raw = int( ( $payment_result->{amount} // 0 ) * 1_000_000 );
    my $network    = $payment_result->{network}  || 'base';
    my $address    = $payment_result->{address}  || '';
    my $asset      = $payment_result->{asset}    || '';

    my $x_payment = encode_json({
        version => '1.0',
        accepts => [{
            scheme            => 'exact',
            network           => $network,
            maxAmountRequired => "$amount_raw",
            to                => $address,
            asset             => $asset,
            extra             => {
                name    => $payment_result->{currency} || 'USDC',
                version => '1',
            },
        }],
    });

    binmode( STDOUT, ':utf8' );

    my $md_path = "$DOCROOT/402.md";
    if ( -f $md_path ) {
        # Set payment context for TT rendering
        %PAYMENT_CONTEXT = (
            payment_required    => 1,
            payment_amount      => $payment_result->{amount}      // '',
            payment_currency    => $payment_result->{currency}    // '',
            payment_network     => $payment_result->{network}     // '',
            payment_address     => $payment_result->{address}     // '',
            payment_description => $payment_result->{description} // '',
        );
        my $page = process_md( $md_path, "$DOCROOT/402.html",
                               (stat($md_path))[9], {} );
        print "Status: 402 Payment Required\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "X-Payment-Response: $x_payment\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print $page;
    }
    else {
        print "Status: 402 Payment Required\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "X-Payment-Response: $x_payment\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print "<!DOCTYPE html><html><head><title>Payment Required</title></head><body>";
        print "<h1>Payment Required</h1>";
        print "<p>This content requires payment of ";
        print( ( $payment_result->{amount} // '0' ) . " "
             . ( $payment_result->{currency} // 'USD' ) );
        print ".</p></body></html>";
    }
}

# --- Main ---

main();

# Parse the request's query string into a hash of name => value.
# Values are URL-decoded, UTF-8 decoded, and HTML-escaped so they
# are safe for interpolation in rendered pages. Returns a hashref.
#
# UTF-8 handling: after percent-decoding to raw bytes, we decode
# the byte string as UTF-8 so the resulting Perl string holds
# proper code points (e.g. %E2%9C%93 -> U+2713). Without this
# step TT's :utf8 output layer would treat each raw byte as a
# Latin-1 character and re-encode it individually, producing
# mojibake (C3 A2 C2 9C C2 93 instead of E2 9C 93 for U+2713).
#
# Malformed UTF-8 in the query string falls back to the raw
# byte-decoded string (rather than crashing the request) - the
# strict Encode::decode throws on invalid sequences and we catch.
sub parse_query_string {
    my ($qs_source) = @_;
    my %query_params;
    return \%query_params unless defined $qs_source && length $qs_source;
    for my $pair ( split /&/, $qs_source ) {
        my ( $key, $val ) = split /=/, $pair, 2;
        next unless defined $key && length $key;
        $key =~ s/\+/ /g;
        $key =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $val = '' unless defined $val;
        $val =~ s/\+/ /g;
        $val =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

        # Decode as UTF-8. eval + strict-mode guard falls back to
        # the raw byte string on malformed input.
        $key = eval { decode( 'UTF-8', $key, 1 ) } // $key;
        $val = eval { decode( 'UTF-8', $val, 1 ) } // $val;

        # HTML-escape value before storing so TT renders it safely.
        # Applied after UTF-8 decode so we're escaping Unicode
        # characters, not individual UTF-8 bytes.
        $val =~ s/&/&amp;/g;
        $val =~ s/</&lt;/g;
        $val =~ s/>/&gt;/g;
        $val =~ s/"/&quot;/g;
        $val =~ s/'/&#39;/g;
        $query_params{$key} = $val;
    }
    return \%query_params;
}

# C-1 trust gate. Strip HTTP_X_REMOTE_* and HTTP_X_PAYMENT_*
# headers from %ENV unless one of the trusted-source signals is
# present: LAZYSITE_AUTH_TRUSTED=1 (set by lazysite-auth.pl after
# cookie validation) or auth_proxy_trusted: true in lazysite.conf
# (operator opt-in for upstream auth proxies). Logs a WARN if a
# client attempted to set these directly.
sub apply_trust_gate {
    my ($uri) = @_;
    my %sv = resolve_site_vars();
    my $proxy_trusted = lc( $sv{auth_proxy_trusted} // 'false' );
    my $auth_trusted  = $ENV{LAZYSITE_AUTH_TRUSTED}  // '';
    return if ( $auth_trusted eq '1' ) || ( $proxy_trusted eq 'true' );

    if ( $ENV{HTTP_X_REMOTE_USER} ) {
        log_event('WARN', $uri,
            'untrusted auth header ignored - set auth_proxy_trusted: true to enable proxy auth',
            header => 'X-Remote-User',
            value  => substr( $ENV{HTTP_X_REMOTE_USER}, 0, 32 ));
    }
    if ( $ENV{HTTP_X_PAYMENT_VERIFIED} ) {
        log_event('WARN', $uri,
            'untrusted payment header ignored',
            header => 'X-Payment-Verified');
    }
    for my $hdr (qw(
        HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS
        HTTP_X_REMOTE_NAME HTTP_X_REMOTE_EMAIL
        HTTP_X_PAYMENT_VERIFIED HTTP_X_PAYMENT_PAYER
    )) {
        delete $ENV{$hdr};
    }
}

# Enforce manager-path access control. Returns truthy if the
# request was fully handled (manager disabled -> forbidden,
# unauthenticated -> redirect, /manager -> /manager/ fixup).
# Caller must treat a truthy return as "done, stop processing
# this request". Returns falsy when the URI is not a manager
# path, or the user is authorised to proceed.
sub handle_manager_path {
    my ($uri) = @_;
    my %sv = resolve_site_vars();
    my $manager_path = $sv{manager_path} || '/manager';

    return 0
        unless $uri eq $manager_path
            || index( $uri, "$manager_path/" ) == 0;

    my $manager_enabled = lc( $sv{manager} // 'disabled' );
    if ( $manager_enabled ne 'enabled' ) {
        forbidden();
        return 1;
    }

    my $auth_user   = $ENV{HTTP_X_REMOTE_USER}   // '';
    my $auth_groups = $ENV{HTTP_X_REMOTE_GROUPS} // '';

    unless ( _is_manager( \%sv, $auth_user, $auth_groups ) ) {
        my $redirect = $sv{auth_redirect} || '/login';
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        print "Location: $redirect?next=" . uri_encode($uri) . "\r\n\r\n";
        return 1;
    }

    # /manager -> /manager/ for directory index
    if ( $uri eq $manager_path ) {
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        print "Location: $manager_path/\r\n\r\n";
        return 1;
    }
    return 0;
}

# Attempt to serve a cached .html. Returns truthy if the request
# was served from cache. Callers should return on truthy.
# $html_stat and $md_stat are arrayrefs (possibly empty).
sub try_serve_cache {
    my ( $base, $md_path, $html_path, $html_stat, $md_stat ) = @_;
    return 0 unless @$md_stat && @$html_stat;

    if ( $html_stat->[9] >= $md_stat->[9] ) {
        log_event('DEBUG', $ENV{REDIRECT_URL} // '-', 'cache hit');
        my $ct  = read_ct($base);
        my $ttl = peek_ttl($md_path);
        output_page( _inject_admin_bar_live( read_file($html_path), $md_path ),
            $ct, $ttl );
        return 1;
    }

    # mtime stale but page-level TTL may still keep the cache valid
    my $ttl = peek_ttl($md_path);
    if ( defined $ttl && is_fresh_ttl_val_stat( $html_stat, $ttl ) ) {
        my $ct = read_ct($base);
        output_page( _inject_admin_bar_live( read_file($html_path), $md_path ),
            $ct, $ttl );
        return 1;
    }
    return 0;
}

# Match the auth surface (login / logout) for "never cache these"
# decisions. The URL may be either the conf-configured
# auth_redirect value (default /login) or the corresponding
# /logout path; both are matched for their exact value and any
# sub-path.
sub is_auth_surface {
    my ($uri) = @_;
    my %sv = resolve_site_vars();
    my $auth_redirect = $sv{auth_redirect} || '/login';
    my $logout_path   = $auth_redirect;
    $logout_path =~ s{/login\b}{/logout};
    return    $uri eq $auth_redirect
           || index( $uri, "$auth_redirect/" ) == 0
           || $uri eq $logout_path
           || index( $uri, "$logout_path/" ) == 0;
}

sub main {
    # M-2 / PC-2: localise %ENV for the request so $ENV writes below (log
    # level, NOCACHE, etc.) cannot leak across requests under FastCGI / D016.
    local %ENV = %ENV;

    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Capture query string before stripping
    my $qs_source = '';
    if ( $uri =~ s/\?(.*)$// ) {
        $qs_source = $1;
    }
    elsif ( defined $ENV{QUERY_STRING} && length $ENV{QUERY_STRING} ) {
        $qs_source = $ENV{QUERY_STRING};
    }
    my %query_params = %{ parse_query_string($qs_source) };

    # Block access to lazysite system directory
    if ( $uri eq $LAZYSITE_URI || index( $uri, $LAZYSITE_URI . '/' ) == 0 ) {
        forbidden();
        return;
    }

    # Set log level from conf (env var takes priority). No local needed
    # here - %ENV is already localised at the top of main().
    {
        my %sv = resolve_site_vars();
        $ENV{LAZYSITE_LOG_LEVEL}  = $sv{log_level}
            if $sv{log_level} && !$ENV{LAZYSITE_LOG_LEVEL};
        $ENV{LAZYSITE_LOG_FORMAT} = $sv{log_format}
            if $sv{log_format} && !$ENV{LAZYSITE_LOG_FORMAT};
    }

    # Trust gate: strip HTTP_X_REMOTE_* / HTTP_X_PAYMENT_* unless
    # a trusted source (auth wrapper or configured proxy) set them.
    apply_trust_gate($uri);

    # Manager path gate. Returns truthy when the request is
    # already handled (forbidden, redirected, or bounced to login).
    return if handle_manager_path($uri);

    # NOTE: managers are NOT forced past the cache any more. The admin bar is no
    # longer baked into the rendered (cached) HTML - it is injected per-request at
    # output time (_inject_admin_bar_live) - so a manager can be served the same
    # bar-free cached page as everyone else and still get their bar. This both
    # restores cache benefit for managers and fixes the bar "not always showing"
    # when a manager request happened to be served from cache.

    # Sanitise URI against path traversal
    my $base = sanitise_uri($uri);
    unless ( defined $base ) {
        not_found($uri);
        return;
    }

    # SM073: .brief sidecars are private - never served publicly. In
    # production Apache denies them directly (FilesMatch); this covers
    # processor-routed requests (the dev server, or any non-existent path).
    if ( $base =~ /\.brief$/ ) {
        not_found($uri);
        return;
    }

    my $md_path   = "$DOCROOT/$base.md";
    my $url_path  = "$DOCROOT/$base.url";
    my $html_path = "$DOCROOT/$base.html";

    # Stat both source and cache files once - pass results to avoid redundant syscalls
    my @html_stat = stat($html_path);
    my @md_stat   = stat($md_path);

    # Auth check - before cache reads to prevent serving protected cached pages
    my $auth_protected = 0;
    my $auth_result    = { ok => 1 };
    my $auth_peek      = {};
    my %site_vars_peek;
    if ( @md_stat ) {
        $auth_peek         = peek_auth($md_path);
        %site_vars_peek    = resolve_site_vars();
        $auth_result        = check_auth( $uri, $auth_peek, \%site_vars_peek );

        if ( $auth_result->{redirect} ) {
            binmode( STDOUT, ':utf8' );
            print "Status: 302 Found\r\n";
            print "Location: " . $auth_result->{redirect} . "\r\n\r\n";
            return;
        }
        if ( $auth_result->{forbidden} ) {
            %AUTH_CONTEXT = (
                authenticated        => 1,
                auth_user            => $auth_result->{auth_user}            // '',
                auth_name            => $auth_result->{auth_name}            // '',
                auth_denied_reason   => $auth_result->{auth_denied_reason}   // '',
                auth_required_groups => $auth_result->{auth_required_groups} // [],
                no_password          => $ENV{LAZYSITE_AUTH_NO_PASSWORD} ? 1 : 0,
            );
            serve_403($auth_result);
            return;
        }

        # Set auth context for TT rendering
        %AUTH_CONTEXT = (
            authenticated => $auth_result->{authenticated} // 0,
            auth_user     => $auth_result->{auth_user}     // '',
            auth_name     => $auth_result->{auth_name}     // '',
            auth_email    => $auth_result->{auth_email}    // '',
            auth_groups   => $auth_result->{auth_groups}   // [],
            no_password   => $ENV{LAZYSITE_AUTH_NO_PASSWORD} ? 1 : 0,
        );

        # Mark as protected if auth required or group-restricted
        my $auth_level = $auth_peek->{auth}
            || $site_vars_peek{auth_default}
            || 'none';
        $auth_protected = 1
            if $auth_level eq 'required'
            || ( $auth_peek->{groups} && @{ $auth_peek->{groups} } );
    }

    # Payment check (after auth - auth group bypass may apply)
    my $payment_protected = 0;
    if ( @md_stat ) {
        my $payment_peek = peek_payment($md_path);

        # Merge auth_groups from auth peek for bypass check
        if ( exists $auth_peek->{groups} && @{ $auth_peek->{groups} } ) {
            $payment_peek->{auth_groups} = $auth_peek->{groups};
        }

        my $payment_result = check_payment(
            $uri, $payment_peek, $auth_result, \%site_vars_peek );

        if ( $payment_result->{payment_required} ) {
            serve_402($payment_result);
            return;
        }

        if ( ( $payment_peek->{payment} // '' ) eq 'required' ) {
            $payment_protected = 1;

            %PAYMENT_CONTEXT = (
                payment_required => 0,
                payment_amount   => $payment_peek->{payment_amount}   // '',
                payment_currency => $payment_peek->{payment_currency} // '',
                payment_address  => $payment_peek->{payment_address}  // '',
                payment_paid     => $payment_result->{paid}           // 0,
                payment_payer    => $payment_result->{payer}          // '',
                payment_bypassed => $payment_result->{bypassed}       // 0,
            );
        }
    }

    # Combined protection flag. auth_protected / payment_protected come
    # from front-matter; is_auth_surface() covers login/logout, which
    # ship with `auth: none` but must never be cached because they
    # embed per-request TT variables (query.next etc.).
    my $protected = $auth_protected || $payment_protected
                 || is_auth_surface($uri);

    # SM071: theme/layout preview. A valid preview cookie overrides the
    # active layout/theme for this request only (%PREVIEW_CONTEXT, merged
    # in render_content) and forces the request uncacheable - never served
    # from cache, never written to cache (NOCACHE), and no-store on output
    # via the protected flag. Reset per request so a stale value cannot
    # leak under a persistent interpreter.
    %PREVIEW_CONTEXT = ();
    if ( my $pv = check_preview() ) {
        %PREVIEW_CONTEXT       = ( layout => $pv->{layout}, theme => $pv->{theme} );
        $protected             = 1;
        $ENV{LAZYSITE_NOCACHE} = '1';
        log_event( 'INFO', $uri, 'preview render',
            layout => $pv->{layout}, theme => $pv->{theme}, user => $pv->{user} );
    }

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

    # Fast path: serve from cache if eligible. Skip when NOCACHE,
    # query-carrying request, or any protection flag is set.
    unless ( $ENV{LAZYSITE_NOCACHE} || $has_query_request || $protected ) {
        return if try_serve_cache( $base, $md_path, $html_path,
                                   \@html_stat, \@md_stat );
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

        # Inject protection flag into filtered_query to prevent caching
        if ( $protected ) {
            $filtered_query{_protected} = 1;
        }

        my $page = process_md( $md_path, $html_path, $md_stat[9], \%filtered_query );
        my $ct   = peek_content_type($md_path);
        my $ttl  = $protected ? undef : peek_ttl($md_path);
        write_ct( $base, $ct ) unless $protected;
        log_event('INFO', $uri, 'page rendered');
        # Admin bar added here (post-cache, per-viewer), not inside the cached page.
        output_page( _inject_admin_bar_live( $page, $md_path ), $ct, $ttl, $protected );
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
        output_page( _inject_admin_bar_live( $page, $url_path ), $ct );
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
    return if $uri =~ /\0/;

    # Reject path traversal sequences
    return if $uri =~ m{(?:^|/)\.\.(?:/|$)};

    # Reject absolute paths or suspicious characters
    return if $uri =~ m{^/};
    return if $uri =~ m{[<>"'\\]};

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

    # D035: resolve the active layout's directory so fenced components
    # (::: name -> components/name.tt) can be found. Page override wins, else the
    # site default. Local layouts only (remote/URL layouts skip this for now).
    my $cmp_layout = ( defined $meta->{layout} && length $meta->{layout} )
        ? $meta->{layout}
        : do { my %sv = resolve_site_vars(); $sv{layout} };
    my $layout_dir = ( defined $cmp_layout && length $cmp_layout
            && $cmp_layout !~ m{://} ) ? "$LAYOUT_DIR/$cmp_layout" : undef;

    # api: true - body is pure TT, no Markdown pipeline, no layout
    if ( $meta->{api} && $meta->{api} =~ /^true$/i ) {
        my ( $processed_body ) = render_content( $meta, $body, $query );
        $processed_body =~ s/^\s+|\s+$//g;  # trim for clean JSON
        $page = $processed_body;
    }
    # raw: true - Markdown pipeline runs, no layout
    elsif ( $meta->{raw} && $meta->{raw} =~ /^true$/i ) {
        my $converted_form  = convert_fenced_form($body, $meta);
        my $converted_comp  = convert_fenced_components($converted_form, $layout_dir, $md_path, $meta);
        my $converted       = convert_fenced_divs($converted_comp);
        my $converted_inc   = convert_fenced_include($converted, $md_path, $meta);
        my $converted2      = convert_fenced_code($converted_inc);
        my $converted3      = convert_oembed($converted2);
        my $html_body       = convert_md($converted3);
        my ( $processed_body ) = render_content( $meta, $html_body, $query );
        $page = $processed_body;
    }
    # Normal mode - full pipeline with layout
    else {
        my $converted_form  = convert_fenced_form($body, $meta);
        my $converted_comp  = convert_fenced_components($converted_form, $layout_dir, $md_path, $meta);
        my $converted       = convert_fenced_divs($converted_comp);
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
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'registry update failed', error => $@) if $@;
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
    log_event('WARN', $ENV{REDIRECT_URL} // '-', 'registry update failed', error => $@) if $@;

    return $page;
}

sub fetch_url {
    my ($url) = @_;

    # Only allow http/https
    return unless $url =~ m{\Ahttps?://};

    # H-4: SSRF guard - reject private / loopback / link-local / multicast
    # IP ranges before touching the wire.
    unless ( is_safe_url($url) ) {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'SSRF blocked',
            url => substr( $url, 0, 100 ));
        return;
    }

    # P-1: load LWP::UserAgent only on first use.
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        timeout => 10,
        agent   => 'lazysite/1.0',
    );

    my $response = $ua->get($url);

    return unless $response->is_success;
    return $response->decoded_content;
}

# H-4: reject URLs that resolve to RFC1918 / loopback / link-local /
# multicast / CGNAT / IPv6-loopback / IPv6-link-local addresses. IPv4-only
# resolution via inet_aton is a deliberate choice - IPv6 private-range
# detection is more involved and we'd rather fail closed than parse
# partial v6 addresses incorrectly.
sub is_safe_url {
    my ($url) = @_;
    my $uri  = URI->new($url);
    my $host = $uri->host // '';
    return 0 unless length $host;

    # Syntactic IPv6 rejection for literals (e.g. http://[::1]/)
    return 0 if $host =~ /\A\[?::1\]?\z/;
    return 0 if $host =~ /\A\[?fe[89ab][0-9a-f]/i;   # link-local v6
    return 0 if $host =~ /\A\[?f[cd][0-9a-f]{2}:/i;  # unique-local v6

    my $packed = inet_aton($host);
    return 0 unless $packed;
    my $ip = inet_ntoa($packed);

    return 0 if $ip eq '0.0.0.0';
    return 0 if $ip =~ /\A127\./;                       # loopback
    return 0 if $ip =~ /\A10\./;                        # RFC1918
    return 0 if $ip =~ /\A172\.(?:1[6-9]|2\d|3[01])\./; # RFC1918
    return 0 if $ip =~ /\A192\.168\./;                  # RFC1918
    return 0 if $ip =~ /\A169\.254\./;                  # link-local / metadata
    return 0 if $ip =~ /\A(?:22[4-9]|23\d)\./;          # multicast
    return 0 if $ip =~ /\A100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./; # CGNAT

    return 1;
}

sub peek_ttl {
    my ($md_path) = @_;
    return _peek_md($md_path)->{ttl};
}

sub peek_content_type {
    my ($path) = @_;
    my $m = _peek_md($path);
    return $m->{content_type}                  if $m->{content_type};
    return                                      unless $m->{raw} || $m->{api};
    return 'application/json; charset=utf-8'   if $m->{api};
    return 'text/plain; charset=utf-8'         if $m->{raw};
    return 'text/html; charset=utf-8';
}

sub peek_query_params {
    my ($md_path) = @_;
    return unless $md_path && -f $md_path;
    return _peek_md($md_path)->{query_params};
}

sub is_fresh_ttl_val_stat {
    my ( $html_stat, $ttl ) = @_;
    return 0 unless @$html_stat;
    return ( time() - $html_stat->[9] ) < $ttl;
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

# --- D035 Phase 3: minimal nested-YAML for front-matter `sections:` -----------
# A self-contained indentation parser for the subset `sections:` needs: a top
# sequence of single-key maps, nested maps, nested sequences, inline flow maps
# {k: v, ...} / seqs [a, b], and quoted/bareword scalars. Only runs for pages
# that declare `sections:`; everything else is untouched. Not a general YAML.
sub _yaml_scalar {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return undef if $s eq '' || $s eq '~' || lc $s eq 'null';
    return $1 if $s =~ /^"(.*)"$/s;
    return $1 if $s =~ /^'(.*)'$/s;
    return $s;
}

sub _yaml_split_flow {
    my ($s) = @_;
    my @parts;
    my ( $cur, $depth, $q ) = ( '', 0, '' );
    for my $ch ( split //, $s ) {
        if ($q) { $cur .= $ch; $q = '' if $ch eq $q; next }
        if ( $ch eq '"' || $ch eq "'" ) { $q = $ch; $cur .= $ch; next }
        if ( $ch eq '{' || $ch eq '[' ) { $depth++; $cur .= $ch; next }
        if ( $ch eq '}' || $ch eq ']' ) { $depth--; $cur .= $ch; next }
        if ( $ch eq ',' && $depth == 0 ) { push @parts, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    push @parts, $cur if $cur =~ /\S/;
    return @parts;
}

sub _yaml_value {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    if ( $s =~ /^\{(.*)\}$/s ) {
        my %h;
        for my $pair ( _yaml_split_flow($1) ) {
            next unless $pair =~ /^\s*(.+?)\s*:\s*(.*)$/s;
            $h{ _yaml_scalar($1) } = _yaml_value($2);
        }
        return \%h;
    }
    if ( $s =~ /^\[(.*)\]$/s ) {
        return [ map { _yaml_value($_) } _yaml_split_flow($1) ];
    }
    return _yaml_scalar($s);
}

# Recursive block parser over [indent, text] tokens.
sub _yaml_block {
    my ( $toks, $i, $ind ) = @_;
    return undef if $$i > $#$toks || $toks->[$$i][0] < $ind;
    my $first = $toks->[$$i][1];

    if ( $first =~ /^-(?:\s|$)/ ) {    # sequence
        my @seq;
        while ( $$i <= $#$toks
            && $toks->[$$i][0] == $ind
            && $toks->[$$i][1] =~ /^-(?:\s|$)/ )
        {
            ( my $rest = $toks->[$$i][1] ) =~ s/^-\s*//;
            my @sub;
            push @sub, [ $ind + 2, $rest ] if length $rest;
            $$i++;
            while ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                push @sub, $toks->[$$i];
                $$i++;
            }
            my $j = 0;
            push @seq, _yaml_block( \@sub, \$j, $ind + 2 );
        }
        return \@seq;
    }

    if ( $first !~ /^[\[{]/ && $first =~ /^(.+?)\s*:\s*(.*)$/ ) {    # mapping
        my %map;
        while ( $$i <= $#$toks && $toks->[$$i][0] == $ind ) {
            my $line = $toks->[$$i][1];
            last if $line =~ /^-(?:\s|$)/;
            last unless $line =~ /^(.+?)\s*:\s*(.*)$/;
            my ( $k, $v ) = ( _yaml_scalar($1), $2 );
            $$i++;
            if ( defined $v && $v =~ /\S/ ) {
                $map{$k} = _yaml_value($v);
            }
            elsif ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                $map{$k} = _yaml_block( $toks, $i, $toks->[$$i][0] );
            }
            else { $map{$k} = undef }
        }
        return \%map;
    }

    my $v = _yaml_value($first);    # bare scalar / flow
    $$i++;
    return $v;
}

sub _parse_sections {
    my ($block) = @_;
    my @toks;
    for my $line ( split /\n/, $block ) {
        next if $line !~ /\S/;
        next if $line =~ /^\s*#/;
        my ($lead) = $line =~ /^(\s*)/;
        ( my $expanded = $lead ) =~ s/\t/    /g;
        ( my $text = $line ) =~ s/^\s+//;
        $text =~ s/\s+$//;
        push @toks, [ length $expanded, $text ];
    }
    return [] unless @toks;
    my $i    = 0;
    my $data = _yaml_block( \@toks, \$i, $toks[0][0] );
    return ref $data eq 'ARRAY' ? $data : [];
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

        # Parse auth_groups list (- item lines)
        if ( $yaml =~ /^auth_groups\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @groups;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @groups, $1;
            }
            $meta{auth_groups} = \@groups;
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

        # D035 Phase 3: parse the nested `sections:` block (data-driven pages).
        # Captures indented/blank lines after `sections:` up to the next
        # column-0 key, then hands them to the minimal nested-YAML parser.
        if ( $yaml =~ /^sections\s*:[ \t]*\n((?:[ \t]+\S[^\n]*\n?|[ \t]*\n)*)/m ) {
            my $parsed = _parse_sections($1);
            $meta{sections} = $parsed if @$parsed;
        }

        # Parse scalar key: value pairs (skip tt_page_var, register, query_params blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            next if $1 eq 'query_params';
            next if $1 eq 'sections';    # nested block; parsed above (and \s* here would eat its first line)
            next if $1 eq 'tags' && ref $meta{tags} eq 'ARRAY';
            next if $1 eq 'auth_groups' && ref $meta{auth_groups} eq 'ARRAY';
            # Strip TT directives from all scalar values including title and subtitle
            my ( $k, $v ) = ( $1, strip_tt_directives($2) );
            # YAML quoting: a matched pair of surrounding quotes is syntax, not
            # content - strip one level so `title: "Welcome"` yields Welcome (not
            # a literal "Welcome" that a template then double-quotes).
            $v =~ s/\s+\z//;
            $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
            $meta{$k} = $v;
        }

        # Sanitise auth value
        if ( defined $meta{auth} ) {
            $meta{auth} = lc($meta{auth});
            $meta{auth} = 'none'
                unless $meta{auth} =~ /^(required|optional|none)$/;
        }

        # Sanitise form name
        if ( defined $meta{form} ) {
            $meta{form} =~ s/[^a-zA-Z0-9_-]//g;
            delete $meta{form} unless length $meta{form};
        }
    }

    return ( \%meta, $text );
}

# --- Forms ---

# --- SM071 Phase 1: theme/layout preview ---------------------------------
#
# A signed, short-lived cookie lets an authorised user render the live
# site against an alternative layout/theme for their session only. The
# cookie reuses the auth-cookie primitive (payload ":" hmac_sha256_hex),
# signed with the shared auth secret at lazysite/auth/.secret. It is
# minted elsewhere (manager UI / SM071 control API); here we only verify
# it and, when valid, expose the override (%PREVIEW_CONTEXT) and force the
# request uncacheable. Payload: v1:<exp-epoch>:<layout>:<theme>:<user>.

# Read a single cookie value from the request. '' when absent.
sub read_request_cookie {
    my ($name) = @_;
    my $cookies = $ENV{HTTP_COOKIE} // '';
    for my $pair ( split /;\s*/, $cookies ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && defined $v;
        return $v if $k eq $name;
    }
    return '';
}

# Read-only load of the shared auth secret. Unlike the auth wrapper we
# never create it here: if it is absent, no valid preview cookie can
# exist, so verification fails closed.
sub load_preview_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    chomp( my $s = <$fh> );
    close $fh;
    return ( defined $s && length $s ) ? $s : undef;
}

# Constant-time compare (mirrors lazysite-auth.pl const_eq).
sub preview_const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b && length $a == length $b;
    my $diff = 0;
    $diff |= ord( substr $a, $_, 1 ) ^ ord( substr $b, $_, 1 )
        for 0 .. length($a) - 1;
    return $diff == 0;
}

# Verify the preview cookie. Returns { layout, theme, user } when a
# valid, unexpired cookie is present, else undef. No filesystem access
# on the common (no-cookie) path.
sub check_preview {
    my $cookie = read_request_cookie($PREVIEW_COOKIE);
    return undef unless length $cookie;

    my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
    return undef unless defined $payload && defined $sig;

    my $secret = load_preview_secret();
    return undef unless defined $secret;
    return undef
        unless preview_const_eq( $sig, hmac_sha256_hex( $payload, $secret ) );

    my ( $ver, $exp, $layout, $theme, $user ) = split /:/, $payload, 5;
    return undef unless defined $ver && $ver eq 'v1';
    return undef unless defined $exp && $exp =~ /^\d+$/ && time() < $exp;
    $layout //= '';
    $theme  //= '';
    return undef
        unless length $layout
        && $layout =~ /^[A-Za-z0-9_-]+$/
        && $theme  =~ /^[A-Za-z0-9_-]*$/;

    return { layout => $layout, theme => $theme, user => ( $user // '' ) };
}

sub load_form_secret {
    my $secret_path = "$LAZYSITE_DIR/forms/.secret";
    my $forms_dir   = "$LAZYSITE_DIR/forms";
    make_path($forms_dir) unless -d $forms_dir;

    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or do {
            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot read form secret', error => $!);
            return '';
        };
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }

    # M-6: fail closed if CSPRNG unavailable.
    open( my $rand, '<:raw', '/dev/urandom' )
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close($rand);
    die "Short read from /dev/urandom ($got of 32 bytes)\n"
        unless defined $got && $got == 32;
    my $s = unpack( 'H*', $raw );

    open( my $fh, '>', $secret_path ) or do {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot write form secret', error => $!);
        return $s;
    };
    chmod 0o600, $secret_path;
    print $fh "$s\n";
    close($fh);
    return $s;
}

sub convert_fenced_form {
    my ( $text, $meta ) = @_;
    $meta //= {};

    $text =~ s{
        ^:::[ \t]+form[ \t]*\n    # opening ::: form
        (.*?)                      # field definitions
        ^:::[ \t]*\n               # closing :::
    }{
        _render_form( $1, $meta );
    }gesmx;

    return $text;
}

sub _render_form {
    my ( $body, $meta ) = @_;

    my $form_name = $meta->{form} // '';
    unless ( $form_name ) {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'form block found but no form key in front matter');
        return "<!-- lazysite: form: key required in front matter -->\n";
    }

    my $ts     = time();
    my $secret = load_form_secret();
    my $tk     = hmac_sha256_hex( $ts, $secret );

    my @fields;
    for my $line ( split /\n/, $body ) {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;

        my ( $name, $label, $rules_str ) = split /\s*\|\s*/, $line, 3;
        $name  //= '';
        $label //= '';
        $rules_str //= '';
        $name  =~ s/^\s+|\s+$//g;
        $label =~ s/^\s+|\s+$//g;

        next unless length $name;

        if ( $name eq 'submit' ) {
            push @fields, qq(  <div class="form-field form-submit">\n)
                        . qq(    <button type="submit">$label</button>\n)
                        . qq(  </div>\n);
            next;
        }

        # Parse rules. Tokens are whitespace-separated, but a key:"value" may
        # quote a value that contains spaces (e.g. placeholder:"Your full name"
        # or pattern:"[0-9 +()-]{7,20}").
        my %rules;
        my @rule_tokens;
        my $rs = $rules_str;
        while ( length $rs ) {
            $rs =~ s/^\s+//;
            last unless length $rs;
            # select: takes the REST of the line - its comma-separated options may
            # contain spaces, so put select: last among a field's rules. (Quotes
            # around the list or an option are tolerated and stripped on render.)
            if    ( $rs =~ s/^(select:.*)\z//s )        { push @rule_tokens, $1; }
            elsif ( $rs =~ s/^([A-Za-z]+:)"([^"]*)"// )  { push @rule_tokens, "$1$2"; }
            elsif ( $rs =~ s/^(\S+)// )                  { push @rule_tokens, $1; }
            else  { last; }
        }
        for my $r ( @rule_tokens ) {
            if ( $r eq 'required' )      { $rules{required} = 1; }
            elsif ( $r eq 'optional' )   { $rules{optional} = 1; }
            elsif ( $r eq 'email' )      { $rules{type} = 'email'; }
            elsif ( $r =~ /^(tel|date|time|number|url|password)$/ ) { $rules{type} = $1; }
            elsif ( $r eq 'textarea' )   { $rules{textarea} = 1; }
            elsif ( $r =~ /^select:(.+)/ ) { $rules{select} = [ split /,/, $1 ]; }
            elsif ( $r =~ /^max:(\d+)/ ) { $rules{max} = $1; }
            elsif ( $r =~ /^min:(\d+)/ ) { $rules{min} = $1; }
            elsif ( $r =~ /^pattern:(.+)/ )     { $rules{pattern} = $1; }
            elsif ( $r =~ /^placeholder:(.+)/ ) { $rules{placeholder} = $1; }
        }
        my $ph_attr = '';
        if ( defined $rules{placeholder} ) {
            ( my $ph = $rules{placeholder} ) =~ s/&/&amp;/g;
            $ph =~ s/"/&quot;/g;
            $ph_attr = qq( placeholder="$ph");
        }

        my $req_attr = $rules{required} ? ' required' : '';
        my $max      = $rules{max} || 1000;
        my $req_mark = $rules{required}
            ? ' <span class="required">*</span>' : '';

        my $field_html;
        if ( $rules{textarea} ) {
            $field_html = qq(    <textarea name="$name" id="$name")
                        . qq( maxlength="$max"$ph_attr$req_attr></textarea>\n);
        }
        elsif ( $rules{select} ) {
            $field_html = qq(    <select name="$name" id="$name"$req_attr>\n);
            $field_html .= qq(      <option value="">-- Select --</option>\n);
            for my $opt ( @{ $rules{select} } ) {
                $opt =~ s/^\s+|\s+$//g;
                $opt =~ s/^"+//; $opt =~ s/"+$//;    # tolerate a quoted option list / option
                $opt =~ s/^\s+|\s+$//g;
                next unless length $opt;
                $field_html .= qq(      <option value="$opt">$opt</option>\n);
            }
            $field_html .= qq(    </select>\n);
        }
        else {
            my $type  = $rules{type} || 'text';
            my $attrs = '';
            if ( $type eq 'number' ) {
                # For numbers, min/max are value bounds (not maxlength).
                $attrs .= qq( min="$rules{min}") if defined $rules{min};
                $attrs .= qq( max="$rules{max}") if defined $rules{max};
            }
            else {
                $attrs .= qq( maxlength="$max");
            }
            # tel gets a sensible default validation pattern unless overridden.
            my $pat = $rules{pattern};
            $pat = '[\\d\\s()+.-]{6,20}' if !defined $pat && $type eq 'tel';
            if ( defined $pat ) {
                $pat =~ s/&/&amp;/g;
                $pat =~ s/"/&quot;/g;
                $attrs .= qq( pattern="$pat");
            }
            $field_html = qq(    <input type="$type" name="$name" id="$name")
                        . $attrs . $ph_attr . qq($req_attr>\n);
        }

        push @fields, qq(  <div class="form-field">\n)
                     . qq(    <label for="$name">$label$req_mark</label>\n)
                     . $field_html
                     . qq(  </div>\n);
    }

    my $fields_html = join( '', @fields );

    return <<"END_FORM";
<form method="POST"
      action="/cgi-bin/form-handler.pl"
      class="lazysite-form"
      data-form="$form_name">
  <input type="hidden" name="_form" value="$form_name">
  <input type="hidden" name="_ts" value="$ts">
  <input type="hidden" name="_tk" value="$tk">
  <div style="position:absolute;left:-9999px;top:-9999px;"
       aria-hidden="true">
    <label for="_hp">Leave this empty</label>
    <input type="text" name="_hp" id="_hp" value=""
           tabindex="-1" autocomplete="off">
  </div>
$fields_html  <div class="form-status" aria-live="polite"></div>
</form>
<script>
(function() {
  var form = document.querySelector('.lazysite-form[data-form="$form_name"]');
  if (!form) return;
  form.addEventListener('submit', function(e) {
    e.preventDefault();
    var btn    = form.querySelector('button[type=submit]');
    var status = form.querySelector('.form-status');
    btn.disabled = true;
    status.textContent = 'Sending...';
    fetch(form.action, {
      method: 'POST',
      body: new FormData(form)
    })
    .then(function(r) {
      if (!r.ok) throw new Error('Server returned ' + r.status);
      return r.json();
    })
    .then(function(data) {
      if (data.ok) {
        form.innerHTML = '<p class="form-success">' +
          (data.message || 'Thank you - message sent.') + '</p>';
      } else {
        status.textContent = data.error || 'An error occurred.';
        btn.disabled = false;
      }
    })
    .catch(function(e) {
      status.textContent = 'Could not send: ' + e.message;
      btn.disabled = false;
    });
  });
})();
</script>
END_FORM
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
            # Render the body's Markdown (block AND inline) so headings/lists
            # inside a box don't leak as literal '##' - Text::MultiMarkdown
            # otherwise treats <div> content as verbatim HTML. Skip pre-render if
            # the body nests another fenced block (include/oembed/form) that the
            # later pipeline passes must still see.
            my $inner = ( $body =~ /^:::/m ) ? $body : convert_md($body);
            qq(<div class="$class">\n${inner}</div>\n);
        }
        else {
            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'fenced div rejected unsafe class', class => $class);
            $body;
        }
    }gsmxe;

    return $text;
}

# --- Content components (D035 Phase 2) ------------------------------------
# A ::: <name> fence whose <name> matches components/<name>.tt under the active
# layout is rendered THROUGH that component: the inner Markdown becomes
# `content`, key="value" pairs on the opening line become `attrs`, and direct
# child ::: <slot> fences become `slots.<slot>`. Fence names with no matching
# component pass through untouched to convert_fenced_divs. Balanced (nesting-
# aware), and byte-preserving for everything that is not a component block.
sub _component_exists {
    my ( $layout_dir, $name ) = @_;
    return 0 unless defined $name && $name =~ /\A[\w-]+\z/;
    return ( -f "$layout_dir/components/$name.tt" ) ? 1 : 0;
}

sub _md_fragment {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    return '' unless defined $text && $text =~ /\S/;
    $text .= "\n" unless $text =~ /\n\z/;    # fence closers need a trailing newline
    # Run the inner through the same fence passes as the page body, so a component
    # can contain nested components, fenced divs and includes - then Markdown.
    my $t = convert_fenced_components( $text, $layout_dir, $md_path, $meta );
    $t = convert_fenced_divs($t);
    $t = convert_fenced_include( $t, $md_path, $meta ) if defined $md_path;
    my $html = convert_md($t);
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    return $html;
}

sub convert_fenced_components {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    return $text unless defined $layout_dir && -d "$layout_dir/components";
    return $text unless $text =~ /^:::[ \t]+[\w-]+/m;   # fast bail

    my @lines = split /\n/, $text, -1;
    my @out;
    my $i = 0;
    while ( $i <= $#lines ) {
        my $l = $lines[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*(.*?)[ \t]*$/
            && _component_exists( $layout_dir, $1 ) )
        {
            my ( $name, $attr ) = ( $1, $2 );
            my @inner;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#lines && $depth > 0 ) {
                my $x = $lines[$j];
                if    ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @inner, $x }
                elsif ( $x =~ /^:::[ \t]*$/ )  { $depth--; push @inner, $x if $depth > 0 }
                else                           { push @inner, $x }
                $j++;
            }
            if ( $depth != 0 ) { push @out, $l; $i++; next; }   # unbalanced: leave as-is
            push @out, _render_component( $layout_dir, $name, $attr,
                join( "\n", @inner ), $md_path, $meta );
            $i = $j;
        }
        else { push @out, $l; $i++; }
    }
    return join "\n", @out;
}

sub _render_component {
    my ( $layout_dir, $name, $attr_str, $inner, $md_path, $meta ) = @_;

    my %attrs;
    while ( $attr_str =~ /([\w-]+)\s*=\s*"([^"]*)"/g ) { $attrs{$1} = $2 }
    while ( $attr_str =~ /([\w-]+)\s*=\s*'([^']*)'/g ) { $attrs{$1} //= $2 }

    # Direct-child ::: <slot> fences whose name is NOT itself a component become
    # named slots; a child fence that IS a component (or any other content) goes
    # to content, where _md_fragment renders it (nested components).
    my ( %slots, @content_lines );
    my @il = split /\n/, $inner, -1;
    my $i  = 0;
    while ( $i <= $#il ) {
        my $l = $il[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*.*$/ ) {
            my $fence = $1;
            my @sb;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#il && $depth > 0 ) {
                my $x = $il[$j];
                if    ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @sb, $x }
                elsif ( $x =~ /^:::[ \t]*$/ )  { $depth--; push @sb, $x if $depth > 0 }
                else                           { push @sb, $x }
                $j++;
            }
            if ( $depth == 0 ) {
                # A child fence that is itself a component, or a reserved built-in
                # (include/oembed/form), belongs to content so the pipeline renders
                # it; any other name is a named slot.
                if ( _component_exists( $layout_dir, $fence )
                    || $fence =~ /\A(?:include|oembed|form)\z/ )
                {
                    push @content_lines, $l, @sb, ':::';
                }
                else {
                    $slots{$fence} =
                        _md_fragment( join( "\n", @sb ), $layout_dir, $md_path, $meta );
                }
                $i = $j;
                next;
            }
        }
        push @content_lines, $l;
        $i++;
    }

    my $content =
        _md_fragment( join( "\n", @content_lines ), $layout_dir, $md_path, $meta );

    my $tt = Template->new(
        ABSOLUTE     => 1,
        EVAL_PERL    => 0,
        INCLUDE_PATH => $layout_dir,
        FILTERS      => { markdown => \&_markdown_filter },
    );
    my $rendered = '';
    $tt->process( "components/$name.tt",
        { content => $content, attrs => \%attrs, slots => \%slots }, \$rendered )
        or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'component render failed',
            component => $name, error => $tt->error() );
        return "<!-- component '$name' failed to render -->";
        };
    $rendered =~ s/\s+\z//;
    return $rendered;
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
            log_event("WARN", $ENV{REDIRECT_URL} // "-", "include fetch failed", source => $source);
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
            log_event("WARN", $ENV{REDIRECT_URL} // "-", "include path invalid", source => $source);
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        if ( ! -f $real ) {
            log_event("WARN", $ENV{REDIRECT_URL} // "-", "include file not found", source => $source);
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        $content = eval { read_file($real) };
        if ( $@ || !defined $content ) {
            log_event("WARN", $ENV{REDIRECT_URL} // "-", "include failed", source => $source, error => $@);
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

# Text::MultiMarkdown paragraph-wraps top-level block HTML that is not isolated
# by blank lines (e.g. a hero <section> with Markdown inside), emitting invalid
# <p><section>...</section></p>. Strip the spurious <p>/</p> that hug a
# block-level element. (Reported from an AI-partner site review, 2026-06.)
sub unwrap_block_html {
    my ($html) = @_;
    my $block = qr/(?:section|article|aside|nav|header|footer|figure|figcaption|main|div|details|summary|address|blockquote|form|fieldset|table|ul|ol|dl|hr|style)/i;
    $html =~ s{<p>\s*(<$block\b)}{$1}g;
    $html =~ s{(</$block>)\s*</p>}{$1}g;
    return $html;
}

sub convert_md {
    my ($body) = @_;

    # Protect <script> blocks from Markdown processing
    my @scripts;
    $body =~ s{(<script[^>]*>)(.*?)(</script>)}{
        my $placeholder = "SCRIPTBLOCK_" . scalar(@scripts) . "_END";
        push @scripts, "$1$2$3";
        $placeholder
    }gse;

    my $md = Text::MultiMarkdown->new(
        use_fenced_code_blocks => 1,
    );
    my $html = $md->markdown($body);

    # Restore <script> blocks
    for my $i ( 0 .. $#scripts ) {
        $html =~ s/(?:<p>)?SCRIPTBLOCK_${i}_END(?:<\/p>)?/$scripts[$i]/;
    }

    return unwrap_block_html($html);
}

# Content components (D035): a TT filter that renders a value containing Markdown
# to HTML, reusing the page Markdown pipeline. A single-paragraph result is
# unwrapped so inline fields (e.g. heading="A site that's *alive*.") stay inline;
# multi-block content keeps its block structure.
sub _markdown_filter {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    my $html = convert_md("$text");
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    if ( $html =~ m{\A<p>(.*)</p>\z}s && index( $1, '<p>' ) < 0 ) {
        $html = $1;    # inline: drop the single enclosing paragraph
    }
    return $html;
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
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "oembed no endpoint", url => $url);
        return;
    }

    my $oembed_url = $endpoint . '?url=' . uri_encode($url) . '&format=json';
    my $raw = fetch_url($oembed_url);
    unless ($raw) {
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "oembed fetch failed", url => $oembed_url);
        return;
    }

    # Parse JSON safely using JSON::PP (S3)
    # Note: JSON::PP gives correct string values but the html field content
    # itself is still trusted as-is. A compromised or malicious provider
    # could return arbitrary HTML. Restrict OEMBED_PROVIDERS to trusted
    # hosts if this is a concern in your deployment.
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data || !defined $data->{html} ) {
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "oembed parse failed", url => $oembed_url, error => $@);
        return;
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
    return unless $page;

    if ( $page =~ m{<link[^>]+type=["']application/json\+oembed["'][^>]+href=["']([^"']+)["']}i
      || $page =~ m{<link[^>]+href=["']([^"']+)["'][^>]+type=["']application/json\+oembed["']}i )
    {
        return $1;
    }

    return;
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

# tt_page_var `json:` source - load a LOCAL JSON file (docroot-relative or a full
# docroot path) and expose the DECODED data structure (hash/array) to the page so
# the body can [% FOREACH row IN data.rows %]. Docroot-contained only; returns ''
# (a falsey scalar, so FOREACH/IF degrade quietly) on missing / invalid / out-of-
# tree, with a WARN. No remote fetch - use a local data file.
sub resolve_json {
    my ($src) = @_;
    my $path =
          index( $src, $DOCROOT ) == 0 ? $src
        : $src =~ m{^/}                ? $DOCROOT . $src
        :                                "$DOCROOT/$src";
    my $real = realpath($path);
    if ( !defined $real || index( $real, $DOCROOT ) != 0 || !-f $real ) {
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

sub resolve_tt_vars {
    my ($defs) = @_;
    my %vars;

    for my $key ( keys %$defs ) {
        my $val = strip_tt_directives( $defs->{$key} );

        if ( $val =~ s/^scan:// ) {
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_scan($val);
        }
        elsif ( $val =~ s/^json://i ) {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_json($val);
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
                log_event("WARN", $ENV{REDIRECT_URL} // "-", "tt var fetch failed", key => $key, val => $val);
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

{
    # P-2: per-process memoization of resolve_site_vars(). This function is
    # called up to 6 times per request (main(), render_content,
    # update_registries, etc). Under CGI, one process = one request, so
    # the cache is request-scoped automatically.
    #
    # *** FastCGI / D016 note ***
    # Under a persistent-process model the cache MUST be reset at the
    # start of every request iteration. The FastCGI wrapper should call
    # reset_request_state() (below) before dispatching.
    my %_site_vars_cache;
    my $_site_vars_loaded = 0;

    sub resolve_site_vars {
        return %_site_vars_cache if $_site_vars_loaded;
        return ()                 unless -f $CONF_FILE;

        my $text = read_file($CONF_FILE);
        my %defs;
        while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) {
            $defs{$1} = $2;
        }

        my %vars = resolve_tt_vars( \%defs );

        my $nav_file = $vars{nav_file}
            ? "$DOCROOT/" . $vars{nav_file}
            : "$LAZYSITE_DIR/nav.conf";
        $vars{nav} = parse_nav($nav_file);

        %_site_vars_cache  = %vars;
        $_site_vars_loaded = 1;
        return %_site_vars_cache;
    }

    # Reset all per-request caches. Call at the top of each request loop
    # iteration under FastCGI (D016). Harmless under CGI.
    sub reset_request_state {
        %_site_vars_cache  = ();
        $_site_vars_loaded = 0;
        _reset_peek_cache();
    }
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

sub peek_search_default {
    return 1 unless -f $CONF_FILE;
    open( my $fh, '<:utf8', $CONF_FILE ) or return 1;
    while ( <$fh> ) {
        if ( /^search_default\s*:\s*(\S+)/ ) {
            close $fh;
            return $1 =~ /^false$/i ? 0 : 1;
        }
    }
    close $fh;
    return 1;
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

sub resolve_scan {
    my ($pattern) = @_;

    # Parse filter modifiers: "filter=FIELD:VALUE" (may repeat)
    my @filters;
    while ( $pattern =~ s/\s+filter=(\w+):([^\s]+)// ) {
        push @filters, { field => $1, value => $2 };
    }

    # Parse sort modifier: "sort=FIELD DIRECTION"
    my $sort_field = 'filename';
    my $sort_dir   = 'asc';
    if ( $pattern =~ s/\s+sort=(\w+)(?:\s+(asc|desc))?//i ) {
        $sort_field = lc($1);
        $sort_dir   = lc($2) if defined $2;
        # date/title/filename are the built-ins; any other identifier sorts on the
        # matching (passed-through) custom front-matter key, e.g. sort=order.
        $sort_field = 'filename' unless $sort_field =~ /^\w+$/;
    }

    # Pattern must be docroot-relative starting with /
    return [] unless $pattern =~ m{^/};

    # Build filesystem glob pattern
    my $fs_pattern = $DOCROOT . $pattern;

    # Limit to .md files only
    return [] unless $fs_pattern =~ /\.md$/;

    my @files;
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
                for my $entry ( readdir($dh) ) {
                    next if $entry =~ /^\./;
                    my $path = "$dir/$entry";
                    if ( -d $path ) {
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
        @files = glob($fs_pattern);
    }

    # Limit to 200 files
    @files = @files[0..199] if @files > 200;

    # Read site search default once if any filter references searchable
    my $search_default;

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

        # Extract raw body for search excerpt
        my $excerpt = '';
        if ( $raw =~ /^---\n.*?\n---\n(.+)/s ) {
            $excerpt = $1;
            # Drop <style>/<script> blocks and HTML comments so their CSS/JS/markup
            # never leaks into the public search excerpt (a page often opens with an
            # inline <style> block).
            $excerpt =~ s{<style\b[^>]*>.*?</style>}{ }gis;
            $excerpt =~ s{<script\b[^>]*>.*?</script>}{ }gis;
            $excerpt =~ s{<!--.*?-->}{ }gs;
            $excerpt =~ s/^\s+|\s+$//g;
            $excerpt = substr($excerpt, 0, 500) if length($excerpt) > 500;
        }

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
        my %reserved = map { $_ => 1 } qw(
            url title subtitle date tags excerpt searchable path
            layout theme auth register search );
        my %custom;
        for my $k ( keys %$meta ) {
            next if $reserved{$k} || $k =~ /^(?:tt_|_)/;
            my $v = $meta->{$k};
            if    ( ref $v eq 'ARRAY' ) { $custom{$k} = [ map { _scan_scalar($_) } @$v ] }
            elsif ( !ref $v )           { $custom{$k} = _scan_scalar($v) }
        }

        push @pages, {
            %custom,
            url        => $url,
            title      => $meta->{title}    || '',
            subtitle   => $meta->{subtitle} || '',
            date       => $date,
            tags       => \@tags,
            excerpt    => $excerpt,
            searchable => $searchable,
            # Docroot-relative, never the absolute server path: this object is
            # published in the public /search-index JSON and exposed to templates
            # as [% p.path %]. Leaking /home/<user>/web/... was an info disclosure.
            path       => ( $path =~ s{^\Q$DOCROOT\E}{}r ),
        };
    }

    # Apply filters
    for my $filter ( @filters ) {
        my $field = $filter->{field};
        my $val   = $filter->{value};

        @pages = grep {
            my $page = $_;
            my $pval = $page->{$field};

            if ( !defined $pval ) {
                0;  # field not present - exclude
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
        if    ( $sort_field eq 'date' )     { ( $va, $vb ) = ( $a->{date}, $b->{date} ) }
        elsif ( $sort_field eq 'title' )    { ( $va, $vb ) = ( lc( $a->{title} ), lc( $b->{title} ) ) }
        elsif ( $sort_field eq 'filename' ) { ( $va, $vb ) = ( $a->{path}, $b->{path} ) }
        else {
            $va = ( defined $a->{$sort_field} && !ref $a->{$sort_field} ) ? $a->{$sort_field} : '';
            $vb = ( defined $b->{$sort_field} && !ref $b->{$sort_field} ) ? $b->{$sort_field} : '';
        }
        my $cmp = ( $va =~ /^-?\d+(?:\.\d+)?$/ && $vb =~ /^-?\d+(?:\.\d+)?$/ )
            ? ( $va <=> $vb ) : ( lc($va) cmp lc($vb) );
        $sort_dir eq 'desc' ? -$cmp : $cmp;
    } @pages;

    return \@sorted;
}

{
    # P-3: cache "do we have any registry templates?" at process level.
    # Most sites don't use registries; this avoids an opendir on every
    # cache-miss render.
    my $_has_registries;    # undef = not yet probed

    sub update_registries {
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

    make_path($TT_COMPILE_DIR) unless -d $TT_COMPILE_DIR;
    my $tt = Template->new(
        ABSOLUTE    => 1,
        ENCODING    => 'utf8',
        EVAL_PERL   => 0,               # L-2
        COMPILE_DIR => $TT_COMPILE_DIR, # P-4
        COMPILE_EXT => '.ttc',          # P-4
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
            log_event("ERROR", "-", "registry template error", tmpl => $tmpl, error => $tt->error());
            next;
        };

        open( my $fh, '>:utf8', $output_path ) or do {
            log_event("WARN", "-", "cannot write registry", path => $output_path, error => $!);
            next;
        };
        print $fh $output;
        close $fh;
    }
}
}   # close P-3 _has_registries memo block

sub scan_pages {
    my @pages;

    # Find all .md and .url files recursively under docroot
    my @queue = ($DOCROOT);
    while ( my $dir = shift @queue ) {
        opendir( my $dh, $dir ) or next;
        for my $entry ( sort readdir($dh) ) {
            next if $entry =~ /^\./;
            next if $entry =~ /\.brief$/;   # SM073: briefs never index
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
    make_path($TT_COMPILE_DIR) unless -d $TT_COMPILE_DIR;
    my $tt = Template->new(
        ABSOLUTE    => 0,
        ENCODING    => 'utf8',
        EVAL_PERL   => 0,               # L-2
        COMPILE_DIR => $TT_COMPILE_DIR, # P-4
        COMPILE_EXT => '.ttc',          # P-4
    ) or die "Template error: " . Template->error() . "\n";

    my %site_vars = resolve_site_vars();
    my %page_vars = resolve_tt_vars( $meta->{tt_page_var} || {} );

    my $groups_ref  = $AUTH_CONTEXT{auth_groups};
    my $groups_str  = ref $groups_ref eq 'ARRAY' ? join( ',', @$groups_ref ) : ( $groups_ref // '' );
    my $editor_flag = _is_manager( \%site_vars, $AUTH_CONTEXT{auth_user} // '', $groups_str ) ? 1 : 0;

    my $vars = {
        %site_vars,
        %page_vars,
        %AUTH_CONTEXT,
        %PAYMENT_CONTEXT,
        %PREVIEW_CONTEXT,   # SM071: preview override wins over site layout/theme
        page_title        => $meta->{title}            || '',
        page_subtitle     => $meta->{subtitle}         || '',
        page_author       => $meta->{author}           || '',
        page_modified     => $meta->{page_modified}    || '',
        page_modified_iso => $meta->{page_modified_iso} || '',
        request_uri       => $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '',
        page_source       => do {
            my $src = $meta->{_md_path} // '';
            $src =~ s{^\Q$DOCROOT\E}{};
            $src || '';
        },
        query             => $query,
        params            => $query,
        lazysite_version  => _lazysite_version(),   # asset cache-buster (?v=)
        enabled_plugins   => _enabled_plugins(),    # conditional manager nav
        smtp_configured   => ( -f "$LAZYSITE_DIR/forms/smtp.conf" ) ? 1 : 0,  # gate emailed reset
        # SM099: a cache-safe sign in / out control. BOTH links ship hidden; the
        # injected auth-sync script reveals the right one from the lzs_session
        # cookie. Themes drop [% auth_control %] into their header instead of a
        # server-side [% IF authenticated %], which bakes the wrong state into the
        # cached HTML (the "shows Sign in while logged in" bug).
        auth_control      =>
              '<a href="/login" data-ls-auth-in class="ls-auth ls-auth-in" style="display:none">Sign in</a>'
            . '<a href="/cgi-bin/lazysite-auth.pl?action=logout" data-ls-auth-out class="ls-auth ls-auth-out" style="display:none">Sign out</a>',
        sections          => $meta->{sections} || [],  # D035 Phase 3: data-driven pages
        editor            => $editor_flag,
        year              => sprintf( '%04d', (localtime)[5] + 1900 ),
        search_enabled    => ( -f "$DOCROOT/search-results.md" || -f "$DOCROOT/search-results.url" ) ? 1 : 0,
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
            log_event("ERROR", $ENV{REDIRECT_URL} // "-", "template error, using raw content", error => $tt->error());
            $processed_body = $protected_body;
        };

    # Restore protected code blocks
    for my $i ( 0 .. $#code_blocks ) {
        $processed_body =~ s/CODEBLOCK_${i}_END/$code_blocks[$i]/;
    }

    return ( $processed_body, $vars );
}

sub get_layout_path {
    my ( $meta, $vars ) = @_;

    # Manager path gets its own dedicated template. D013: manager lives
    # outside layouts/ entirely — it's internal plumbing, not a
    # themeable layout.
    my $manager_path = $vars->{manager_path} || '/manager';
    # Match the URI resolution used for content (and request_uri TT var):
    # behind the auth wrapper, REDIRECT_URL may be unset while REQUEST_URI
    # carries the real path, so the manager-layout check must fall back too.
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';
    if ( index( $uri, $manager_path ) == 0 ) {
        return ( $MANAGER_LAYOUT, undef ) if -f $MANAGER_LAYOUT;
        return ( undef, undef );
    }

    my $name = $meta->{layout} || $vars->{layout} || '';

    if ( $name ) {
        # Remote layout: URL in layout key. Remote keeps the flat
        # /lazysite-assets/CACHE_KEY/ asset convention (D013 decision:
        # remote is a single bundled package).
        if ( $name =~ m{^https?://} ) {
            my ( $cached, $theme_key ) = fetch_remote_layout($name);
            return ( $cached, $theme_key ) if $cached;
            log_event("WARN", $ENV{REDIRECT_URL} // "-",
                "remote layout fetch failed", name => $name);
            return ( undef, undef );
        }

        $name =~ s/[^a-zA-Z0-9_-]//g;
        $name ||= '';

        if ( $name ) {
            # D013: layouts/NAME/layout.tt. No flat-template fallback.
            my $layout_path = "$LAYOUT_DIR/$name/layout.tt";
            return ( $layout_path, $name ) if -f $layout_path;

            log_event('WARN', $ENV{REDIRECT_URL} // '-',
                'layout not found, using fallback', layout => $name);
        }
    }

    return ( undef, undef );
}

# D013: resolve the theme for a given (validated) layout. Returns a hash
# with theme_name, theme_data (decoded theme.json), and is_active (true
# iff theme.json's layouts[] contains the layout name). When the theme
# cannot be loaded or is incompatible, returns an empty hash and the
# caller proceeds with no theme (no theme_assets, no theme_css).
sub resolve_theme {
    my ( $layout_name, $theme_name ) = @_;
    return {} unless defined $layout_name && length $layout_name;
    return {} unless defined $theme_name  && length $theme_name;

    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    return {} unless length $theme_name;

    my $theme_dir  = "$LAYOUT_DIR/$layout_name/themes/$theme_name";
    my $theme_json = "$theme_dir/theme.json";
    return {} unless -f $theme_json;

    open my $fh, '<:utf8', $theme_json or do {
        log_event('WARN', $ENV{REDIRECT_URL} // '-',
            'cannot open theme.json', path => $theme_json);
        return {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    unless ( ref $data eq 'HASH' ) {
        log_event('WARN', $ENV{REDIRECT_URL} // '-',
            'invalid theme.json', path => $theme_json);
        return {};
    }

    # Strict: theme must declare compatibility with the active layout.
    my $layouts = $data->{layouts};
    unless ( ref $layouts eq 'ARRAY' && grep { $_ eq $layout_name } @$layouts ) {
        log_event('WARN', $ENV{REDIRECT_URL} // '-',
            'theme not declared for layout; rendering without theme styling',
            theme => $theme_name, layout => $layout_name);
        return {};
    }

    return {
        theme_name => $theme_name,
        theme_data => $data,
        is_active  => 1,
    };
}

# D013: generate a <style> block of CSS custom properties from a theme's
# config object. Naming convention: --theme-GROUP-KEY. Only scalar
# (non-ref) values are emitted — a theme author using a nested object
# under a group key is a shape error and is skipped silently.
sub generate_theme_css {
    my ($theme_data) = @_;
    return '' unless ref $theme_data eq 'HASH';
    my $config = $theme_data->{config};
    return '' unless ref $config eq 'HASH';

    my @lines;
    for my $group ( sort keys %$config ) {
        my $group_val = $config->{$group};
        next unless ref $group_val eq 'HASH';
        next unless $group =~ /^[A-Za-z0-9_-]+$/;
        for my $key ( sort keys %$group_val ) {
            my $v = $group_val->{$key};
            next if ref $v;
            next unless $key =~ /^[A-Za-z0-9_-]+$/;
            my $safe = defined $v ? $v : '';
            # Strip anything that could break out of a declaration — the
            # theme schema says values are strings, not CSS expressions.
            $safe =~ s/[;\{\}<>]//g;
            push @lines, "  --theme-$group-$key: $safe;";
        }
    }
    return '' unless @lines;
    return "<style>\n:root {\n" . join("\n", @lines) . "\n}\n</style>";
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
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "cannot write layout cache", path => $cache_path, error => $!);
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
                # D013: remote packages now point at a layout.tt URL.
                # Still accept legacy view.tt in the files list so a
                # transitional manifest doesn't re-fetch it.
                next if $file eq 'layout.tt' || $file eq 'view.tt';
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

    my ( $layout, $layout_key ) = get_layout_path( $meta, $vars );

    # D013: $layout_key is the token used for asset URL derivation.
    # - Local layout name (e.g. "default") — asset dir becomes
    #   /lazysite-assets/LAYOUT/THEME/ once a theme resolves.
    # - Remote URL's sanitised cache key — asset dir stays flat at
    #   /lazysite-assets/CACHE_KEY/ (remote is a single bundled
    #   package; D013 nested structure does not apply).
    # - undef for the manager path and for the embedded fallback.
    my $is_remote_layout = defined $layout
        && index($layout, $LAYOUT_CACHE_DIR) == 0;

    if ( defined $layout_key && $is_remote_layout ) {
        # Remote: flat asset path, no theme resolution (§3 decision).
        # Clear theme/theme_css so templates don't try to index into
        # the conf string under theme.config.
        $vars->{theme_assets} = "/lazysite-assets/$layout_key";
        $vars->{theme}        = {};
        $vars->{theme_css}    = '';
    }
    elsif ( defined $layout_key ) {
        # Local layout. Expose layout_name and resolve the active theme
        # against it, populating theme_name, theme, theme_assets, and
        # theme_css when the theme is compatible. When no theme (or an
        # incompatible one) is active, $vars->{theme} is replaced with
        # an empty hash so [% theme.config.foo %] renders empty rather
        # than trying to index into the raw conf string.
        $vars->{layout_name} = $layout_key;
        # SM120: a page may pin a theme via front matter (theme:), preview-only and
        # sanitised the same way as layout:; falls back to the active/site theme.
        # resolve_theme still gates on layout compatibility, so an incompatible pin
        # renders as no theme rather than breaking.
        my $page_theme = ( defined $meta->{theme} && $meta->{theme} =~ /^[A-Za-z0-9_-]+$/ )
            ? $meta->{theme} : $vars->{theme};
        my $info = resolve_theme( $layout_key, $page_theme );
        if ( $info->{is_active} ) {
            $vars->{theme_name}   = $info->{theme_name};
            $vars->{theme}        = $info->{theme_data};
            $vars->{theme_assets} = "/lazysite-assets/$layout_key/" . $info->{theme_name};
            $vars->{theme_css}    = generate_theme_css( $info->{theme_data} );
        }
        else {
            $vars->{theme}     = {};
            $vars->{theme_css} = '';
        }
    }
    else {
        $vars->{theme}     = {};
        $vars->{theme_css} = '';
    }

    $vars->{content} = $processed_body;
    my $output = '';

    if ( !defined $layout ) {
        # No layout found - use built-in fallback directly
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "layout not found, using fallback");
        my $tt_fallback = Template->new( ENCODING => 'utf8', EVAL_PERL => 0 )
            or do {
                log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance');
                return $processed_body;
            };

        $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
            or do {
                log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error());
                return $processed_body;
            };

        # Admin bar injected per-request at output time, not cached (see note below).
        return $output;
    }

    # Determine if layout is remote (from cache dir) - sandbox it
    my $is_remote = $is_remote_layout;

    # D035 content components: resolve [% INCLUDE 'components/NAME.tt' %] against
    # the active layout's own directory, and expose a `markdown` filter so a
    # component can render Markdown fields. Content authors never write TT;
    # components ship inside the trusted layout package and EVAL_PERL stays off.
    my $component_dir = ( defined $layout && length $layout && -e $layout )
        ? dirname($layout) : undef;

    my $tt_layout = $is_remote
        ? Template->new(
            ABSOLUTE     => 1,                # needed to read cache path
            RELATIVE     => 0,
            EVAL_PERL    => 0,                # no embedded Perl
            ENCODING     => 'utf8',
            INCLUDE_PATH => $component_dir,   # D035: layout-local components
            FILTERS      => { markdown => \&_markdown_filter },
            COMPILE_DIR  => $TT_COMPILE_DIR,  # P-4
            COMPILE_EXT  => '.ttc',           # P-4
        )
        : Template->new(
            ABSOLUTE     => 1,
            ENCODING     => 'utf8',
            EVAL_PERL    => 0,                # L-2
            INCLUDE_PATH => $component_dir,   # D035: layout-local components
            FILTERS      => { markdown => \&_markdown_filter },
            COMPILE_DIR  => $TT_COMPILE_DIR,  # P-4
            COMPILE_EXT  => '.ttc',           # P-4
        );

    unless ( $tt_layout ) {
        log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create TT instance');
        return $processed_body;
    }

    # Try specified layout
    $tt_layout->process( $layout, $vars, \$output )
        or do {
            log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'layout error, using fallback', layout => $layout, error => $tt_layout->error());
            $output = '';

            # Try built-in fallback layout
            my $tt_fallback = Template->new( ENCODING => 'utf8', EVAL_PERL => 0 )
                or do {
                    log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance');
                    return $processed_body;
                };

            $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
                or do {
                    log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error());
                    return $processed_body;
                };
        };

    # SM112: identify the generator (+ optional author/description) in the head,
    # regardless of which layout rendered the page.
    $output = _inject_meta( $output, $vars );

    # SM099: client-side sign-in/out so a shared cached page never shows the wrong
    # auth control. Toggles [data-ls-auth-in]/[data-ls-auth-out] from the lzs_session
    # marker cookie. Injected on every page so any layout can opt in with those attrs.
    $output = _inject_auth_sync($output);

    # NOTE: the manager admin bar is deliberately NOT injected here. It is
    # per-viewer (manager-only) and this output is written to the shared page
    # cache - baking it in would leak it to anonymous visitors, or hide it from
    # managers, depending on who filled the cache. It is injected per-request at
    # output time instead (_inject_admin_bar_live), so the cached HTML is bar-free.

    return $output;
}

# SM099: reveal the correct auth control client-side from the lzs_session marker
# cookie (display-only; the signed HttpOnly cookie is still the gate). One tiny
# inline script before </body>, only acting on opt-in [data-ls-auth-*] elements.
sub _inject_auth_sync {
    my ($html) = @_;
    return $html unless $html =~ m{</body>}i;
    my $script = '<script>(function(){var on=/(?:^|;\s*)lzs_session=1(?:;|$)/.test('
        . 'document.cookie),o=document.querySelectorAll("[data-ls-auth-out]"),'
        . 'i=document.querySelectorAll("[data-ls-auth-in]"),k;'
        . 'for(k=0;k<o.length;k++)o[k].style.display=on?"":"none";'
        . 'for(k=0;k<i.length;k++)i[k].style.display=on?"none":"";})();</script>';
    # Inject before the LAST </body>, not the first: a page can legitimately
    # carry a literal "</body>" inside a JS string (e.g. the editor builds an
    # iframe srcdoc: frame.srcdoc = '...</body></html>'). Splicing a
    # <script>...</script> in there closes the page's own inline <script> early
    # - "SyntaxError: literal not terminated" - and kills the whole script. The
    # negative lookahead anchors the match to the document's real closing tag.
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

# SM112: read the installed release version once (from the install state).
my $LAZYSITE_VERSION;
# Enabled plugins from lazysite.conf's `plugins:` list, for conditional manager
# nav (e.g. hide "Visitor statistics" when the stats plugin is disabled). Keyed
# by both the raw entry (stats.pl) and its extensionless id (stats) so the layout
# can write `enabled_plugins.stats`.
sub _enabled_plugins {
    my %en;
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    open my $fh, '<:utf8', $conf or return \%en;
    my $in = 0;
    while (<$fh>) {
        chomp;
        if (/^plugins\s*:\s*$/) { $in = 1; next }
        if ( $in && /^\s+-\s+(.+?)\s*$/ ) {
            my $e = $1;
            $en{$e} = 1;                  # raw entry, e.g. stats.pl
            ( my $base = $e ) =~ s{.*/}{};        # basename (drop any path prefix)
            $en{$base} = 1;
            ( my $id = $base ) =~ s/\.[^.]+$//;   # extensionless id, e.g. stats
            $en{$id} = 1 if length $id;
        }
        elsif ( $in && /^\S/ ) { $in = 0 }
    }
    close $fh;
    return \%en;
}

sub _lazysite_version {
    return $LAZYSITE_VERSION if defined $LAZYSITE_VERSION;
    $LAZYSITE_VERSION = '';
    my $path = "$DOCROOT/lazysite/.install-state.json";
    if ( open my $fh, '<', $path ) {
        local $/; my $j = <$fh>; close $fh;
        my $d = eval { decode_json($j) };
        $LAZYSITE_VERSION = $d->{version} if $d && $d->{version};
    }
    return $LAZYSITE_VERSION;
}

# Inject <meta name="generator"> (+ author/description when available) just after
# the opening <head>. Opt out with meta_generator: false in lazysite.conf.
sub _inject_meta {
    my ( $html, $vars ) = @_;
    return $html unless $html =~ /<head[^>]*>/i;
    my $off = lc( $vars->{meta_generator} // '' );
    return $html if $off eq 'false' || $off eq 'off' || $off eq '0';

    my $esc = sub {
        my $s = shift // '';
        $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
        return $s;
    };
    my $ver = _lazysite_version();
    my @m = ( '<meta name="generator" content="' . $esc->( 'lazysite' . ( $ver ? " $ver" : '' ) ) . '">' );
    if ( length( $vars->{page_author} // '' ) ) {
        push @m, '<meta name="author" content="' . $esc->( $vars->{page_author} ) . '">';
    }
    # Only add description if the layout did not already emit one.
    if ( length( $vars->{page_subtitle} // '' ) && $html !~ /<meta\s+name=["']description["']/i ) {
        push @m, '<meta name="description" content="' . $esc->( $vars->{page_subtitle} ) . '">';
    }
    my $block = "\n    " . join( "\n    ", @m );
    $html =~ s/(<head[^>]*>)/$1$block/i;
    return $html;
}

sub _inject_admin_bar {
    my ( $html, $vars ) = @_;

    my $manager = $vars->{manager} // '';
    return $html unless $manager eq 'enabled';

    my $page_source = $vars->{page_source} // '';
    my $request_uri = $vars->{request_uri} // '';

    # Don't inject on manager pages - they have their own chrome
    my $manager_path = $vars->{manager_path} || '/manager';
    return $html if $request_uri eq $manager_path
                  || index( $request_uri, "$manager_path/" ) == 0;

    # Who is viewing? Use the same rule as the /manager route protection.
    my $auth_user   = $ENV{HTTP_X_REMOTE_USER}   // '';
    my $auth_groups = $ENV{HTTP_X_REMOTE_GROUPS} // '';
    my $is_manager  = _is_manager( $vars, $auth_user, $auth_groups );

    # Manager tools: Manage / Edit / no-password warning / sign-out.
    # SM069: the core theme switcher that used to live here has been
    # removed. It POSTed to action=theme-activate from a live-site
    # page without the CSRF token (the manager-api CSRF wrapper only
    # runs on /manager/* pages), so the server rejected the POST and
    # the switch silently failed. The duplicate is also out of scope:
    # /manager/config's Active theme dropdown (SM044) is now the
    # single path to set the site-wide active theme.
    my $manager_tools = '';
    if ( $is_manager ) {
        $manager_tools .= '<a href="/manager/" style="color:#6db3f2;text-decoration:none;">Manage</a>';

        if ( $page_source ) {
            $manager_tools .= '<a href="/manager/edit?path=' . $page_source
                           .  '" style="color:#6db3f2;text-decoration:none;">Edit</a>';
        }

        if ( $ENV{LAZYSITE_AUTH_NO_PASSWORD} ) {
            $manager_tools .= '<span style="color:#f5a623;">&#9888; No password set for your account.</span>';
            $manager_tools .= '<a href="/manager/users" style="color:#f5a623;text-decoration:underline;">Set one</a>';
        }

        my $user = $vars->{auth_name} || $vars->{auth_user} || '';
        if ( $user ) {
            $manager_tools .= '<span style="margin-left:auto;">' . $user . '</span>';
            $manager_tools .= '<a href="/cgi-bin/lazysite-auth.pl?action=logout" style="color:#888;text-decoration:none;">Sign out</a>';
        }
    }

    # F0017 stub: when the cookie-based per-visitor theme variant
    # switcher lands, it will populate $variant_switcher here,
    # outside the $is_manager gate so all visitors can use it. For
    # now the bar never carries a switcher.
    my $variant_switcher = '';

    # Nothing to show? Skip the bar entirely.
    return $html unless length $manager_tools || length $variant_switcher;

    my $bar = '<div id="ls-admin-bar" style="'
        . 'position:fixed;top:0;left:0;right:0;z-index:99999;'
        . 'background:#1a1a1a;color:#aaa;font:12px system-ui,sans-serif;'
        . 'padding:2px 12px;display:flex;align-items:center;gap:10px;'
        . '">';
    $bar .= $manager_tools;
    $bar .= $variant_switcher;
    $bar .= '</div>';
    $bar .= '<div id="ls-admin-spacer" style="height:22px;"></div>';

    # Hide in iframes
    $bar .= '<script>if(window!==window.top){var ab=document.getElementById("ls-admin-bar");'
          . 'var sp=document.getElementById("ls-admin-spacer");'
          . 'if(ab)ab.style.display="none";if(sp)sp.style.display="none";}</script>';

    # Anchor to the FIRST <body> after </head>, not the first <body> anywhere: a
    # page can carry a literal "<body>" inside a head comment or script string
    # (e.g. the manager CSRF wrapper's explanatory comment). Splicing the bar -
    # which itself contains <script>...</script> - into a head <script> closes that
    # script early and corrupts the whole page. Fall back to a bare <body> only if
    # there is no </head> (fragment), where there is no head to be confused by.
    if ( $html =~ m{</head\s*>}i ) {
        $html =~ s{(</head\s*>[\s\S]*?<body[^>]*>)}{$1$bar}i;
    }
    else {
        $html =~ s/(<body[^>]*>)/$1$bar/i;
    }

    return $html;
}

# Inject the manager admin bar at OUTPUT time, per-request, so it is never written
# to the shared page cache - baking it in would leak it to anonymous visitors, or
# hide it from a manager, depending on who filled the cache. Sources everything
# from the live request: site config (manager on/off + manager_groups),
# %AUTH_CONTEXT (the viewer), and the page's source path for the Edit link. No-op
# on body-less / non-HTML output.
sub _inject_admin_bar_live {
    my ( $html, $md_path ) = @_;
    return $html unless defined $html && $html =~ /<body/i;
    my %sv = resolve_site_vars();
    return $html unless ( $sv{manager} // '' ) eq 'enabled';

    my $page_source = $md_path // '';
    $page_source =~ s{^\Q$DOCROOT\E/}{};   # docroot-relative, for the Edit link

    my $groups = $AUTH_CONTEXT{auth_groups} || [];
    my $bar_vars = {
        %sv,                                     # manager, manager_path, manager_groups
        # Behind the auth wrapper (every /manager/* page) REDIRECT_URL is unset and
        # the real path is in REQUEST_URI - same resolution as the request_uri TT
        # var and get_layout_path. Using REDIRECT_URL alone left request_uri empty,
        # so the "skip on manager pages" guard never fired and the bar was injected
        # into the manager page (and into a <body> in its head comment).
        request_uri => ( $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '' ),
        page_source => $page_source,
        auth_user   => $AUTH_CONTEXT{auth_user} // '',
        auth_name   => $AUTH_CONTEXT{auth_name} // '',
        auth_groups =>
            ( ref $groups eq 'ARRAY' ? join( ',', @$groups ) : ( $groups // '' ) ),
    };
    return _inject_admin_bar( $html, $bar_vars );
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
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "cannot write content type cache", path => $ct_path, error => $!);
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

    # Skip cache write if LAZYSITE_NOCACHE is set
    return if $ENV{LAZYSITE_NOCACHE};

    # Refuse to write zero-byte content - protects against empty cache
    # files that would permanently block regeneration via DirectoryIndex
    unless ( length($page) ) {
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "refusing zero-byte cache write", path => $html_path);
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
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "cache path outside docroot", path => $html_path);
        return;
    }

    my $dir = dirname($html_path);
    unless ( -d $dir ) {
        make_path($dir);
        # Set group to match docroot and apply setgid bit so new files
        # and subdirectories inherit the group automatically.
        my $gid = ( stat($DOCROOT) )[5];
        chown -1, $gid, $dir;
        chmod 0o775 | 0o2000, $dir;  # L-8: explicit octal; 0o2000 = setgid
    }

    # P-5: atomic write via tempfile + rename so readers never see a torn
    # file. $html_path.tmp.$$ is pid-scoped to avoid concurrent writers
    # collapsing on the same temp name.
    my $tmp = "$html_path.tmp.$$";
    open( my $fh, '>:utf8', $tmp ) or do {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot write cache tempfile', path => $tmp, error => $!);
        return;
    };
    print $fh $page;
    close $fh;
    unless ( rename $tmp, $html_path ) {
        my $err = $!;
        unlink $tmp;
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot rename cache tempfile', path => $html_path, error => $err);
        return;
    }
}

# --- Output ---

sub output_page {
    my ( $content, $content_type, $ttl, $auth_protected ) = @_;
    $content_type //= 'text/html; charset=utf-8';
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\n";
    print "Content-type: $content_type\n";
    # L-1: baseline security headers. CSP and HSTS are deliberately NOT
    # emitted here - CSP is site-specific (depends on what external
    # resources pages load) and HSTS depends on whether TLS is in use;
    # both belong in the Apache vhost config.
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: SAMEORIGIN\n";
    print "Referrer-Policy: strict-origin-when-cross-origin\n";
    if ( $auth_protected ) {
        print "Cache-Control: no-store, private\n";
    }
    elsif ( defined $ttl && $ttl > 0 ) {
        print "Cache-Control: public, max-age=$ttl\n";
    }
    else {
        print "Cache-Control: no-cache, must-revalidate\n";
    }
    print "Vary: Cookie\n";
    print "\n";
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

sub log_event {
    my ($level, $context, $message, %extra) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map  { '"' . _json_str($_) . '":"' . _json_str($extra{$_}) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"'     . _json_str($level)          . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT)  . '"'
            . ',"context":"'   . _json_str($context)        . '"'
            . ',"message":"'   . _json_str($message)        . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

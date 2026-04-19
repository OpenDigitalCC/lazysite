#!/usr/bin/perl
use strict;
use warnings;
use Text::MultiMarkdown;
use Template;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use LWP::UserAgent;
use Cwd qw(realpath);
use JSON::PP qw(decode_json encode_json);
use Digest::SHA qw(hmac_sha256_hex);
use POSIX qw(strftime);

my $LOG_COMPONENT = 'processor';

# --- Plugin descriptor ---

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'lazysite',
        name        => 'Site Configuration',
        description => 'Core lazysite.conf settings: site identity, theme, search, and manager',
        version     => '1.0',
        config_file => '',
        config_keys => [qw(site_name site_url theme nav_file
                           search_default manager manager_path manager_groups)],
        config_schema => [
            { key => 'site_name', label => 'Site name', type => 'text',
              default => 'My Site', required => JSON::PP::true() },
            { key => 'site_url', label => 'Site URL', type => 'text',
              default => '${REQUEST_SCHEME}://${SERVER_NAME}' },
            { key => 'theme', label => 'Active theme', type => 'text',
              default => '' },
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
my %AUTH_CONTEXT;    # populated by main() auth check, read by render_content()

# Built-in fallback template - used when no view.tt is found
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
    [% IF authenticated %]
    <span style="font-size:0.8rem;color:#888;margin-left:auto;">[% auth_name || auth_user %]</span>
    <a href="/logout" style="font-size:0.8rem;color:#888;font-weight:400;">Sign out</a>
    [% ELSE %]
    <a href="/login" style="font-size:0.8rem;margin-left:auto;font-weight:400;">Sign in</a>
    [% END %]
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
    [% IF item.url %]
    <a href="[% item.url %]" style="margin-right:1rem;color:#0066cc;text-decoration:none;"[% IF request_uri == item.url %] aria-current="page" style="margin-right:1rem;color:#0066cc;text-decoration:none;font-weight:600;"[% END %]>[% item.label %]</a>
    [% ELSE %]
    <span style="margin-right:0.5rem;color:#888;font-size:0.85rem;">[% item.label %]</span>
    [% END %]
    [% FOREACH child IN item.children %]
    <a href="[% child.url %]" style="margin-right:0.75rem;color:#0066cc;text-decoration:none;font-size:0.85rem;"[% IF request_uri == child.url %] aria-current="page"[% END %]>[% child.label %]</a>
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

# --- Auth ---

sub peek_auth {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or return {};
    my ( $auth, @groups, $in_groups );
    while ( <$fh> ) {
        last if $. > 1 && /^---/;
        $auth = $1 if /^auth\s*:\s*(\w+)/i;
        if ( /^auth_groups\s*:\s*$/ ) { $in_groups = 1; next }
        if ( $in_groups && /^\s+-\s+(.+)$/ ) {
            my $g = $1;
            $g =~ s/^\s+|\s+$//g;
            push @groups, $g;
        }
        elsif ( $in_groups && !/^\s/ ) { $in_groups = 0 }
    }
    close $fh;
    return { auth => $auth, groups => \@groups };
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
    my ($site_vars, $auth_user, $auth_groups) = @_;
    return 0 unless $auth_user;
    my $manager_groups = $site_vars->{manager_groups} // '';
    $manager_groups =~ s/^\s+|\s+$//g;
    return 1 unless length $manager_groups;
    my %user_groups = map { lc($_) => 1 } split /\s*,\s*/, ( $auth_groups // '' );
    return scalar grep { $user_groups{ lc($_) } } split /\s*,\s*/, $manager_groups;
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

sub peek_payment {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or return {};
    my %meta;
    my %want = map { $_ => 1 } qw(payment payment_amount payment_currency
        payment_network payment_address payment_asset payment_description);
    while ( <$fh> ) {
        last if $. > 1 && /^---/;
        if ( /^([\w]+)\s*:\s*(.+)$/ && $want{$1} ) {
            $meta{$1} = $2;
            $meta{$1} =~ s/\s+$//;
        }
    }
    close $fh;
    return \%meta;
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

sub main {
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Capture query string before stripping
    my %query_params;
    my $qs_source = '';
    if ( $uri =~ s/\?(.*)$// ) {
        $qs_source = $1;
    }
    elsif ( defined $ENV{QUERY_STRING} && length $ENV{QUERY_STRING} ) {
        $qs_source = $ENV{QUERY_STRING};
    }
    if ( length $qs_source ) {
        my $qs = $qs_source;
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

    # Set log level from conf (env var takes priority)
    {
        my %sv = resolve_site_vars();
        $ENV{LAZYSITE_LOG_LEVEL}  = $sv{log_level}
            if $sv{log_level} && !$ENV{LAZYSITE_LOG_LEVEL};
        $ENV{LAZYSITE_LOG_FORMAT} = $sv{log_format}
            if $sv{log_format} && !$ENV{LAZYSITE_LOG_FORMAT};
    }

    # Manager path enforcement
    {
        my %sv = resolve_site_vars();
        my $manager_enabled = lc( $sv{manager} // 'disabled' );
        my $manager_path    = $sv{manager_path}  || '/manager';
        my $manager_groups  = $sv{manager_groups} || '';

        if ( $uri eq $manager_path || index( $uri, "$manager_path/" ) == 0 ) {
            if ( $manager_enabled ne 'enabled' ) {
                forbidden();
                return;
            }

            my $auth_user   = $ENV{HTTP_X_REMOTE_USER}   // '';
            my $auth_groups = $ENV{HTTP_X_REMOTE_GROUPS} // '';

            unless ( _is_manager( \%sv, $auth_user, $auth_groups ) ) {
                my $redirect = $sv{auth_redirect} || '/login';
                binmode( STDOUT, ':utf8' );
                print "Status: 302 Found\r\n";
                print "Location: $redirect?next=" . uri_encode($uri) . "\r\n\r\n";
                return;
            }

            # Redirect /manager to /manager/ for directory index
            if ( $uri eq $manager_path ) {
                binmode( STDOUT, ':utf8' );
                print "Status: 302 Found\r\n";
                print "Location: $manager_path/\r\n\r\n";
                return;
            }
        }
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

    # Combined protection flag
    my $protected = $auth_protected || $payment_protected;

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
    # Skip cache if LAZYSITE_NOCACHE is set, query request active, or protected
    unless ( $ENV{LAZYSITE_NOCACHE} || $has_query_request || $protected ) {
        if ( @md_stat && @html_stat ) {
            if ( $html_stat[9] >= $md_stat[9] ) {
                # mtime fresh - serve cache immediately
                log_event('DEBUG', $uri, 'cache hit');
                my $ct  = read_ct($base);
                my $ttl = peek_ttl($md_path);
                output_page( read_file($html_path), $ct, $ttl );
                return;
            }
            # mtime stale - check for page-level TTL override before regenerating
            my $ttl = peek_ttl($md_path);
            if ( defined $ttl && is_fresh_ttl_val_stat( \@html_stat, $ttl ) ) {
                my $ct = read_ct($base);
                output_page( read_file($html_path), $ct, $ttl );
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

        # Inject protection flag into filtered_query to prevent caching
        if ( $protected ) {
            $filtered_query{_protected} = 1;
        }

        my $page = process_md( $md_path, $html_path, $md_stat[9], \%filtered_query );
        my $ct   = peek_content_type($md_path);
        my $ttl  = $protected ? undef : peek_ttl($md_path);
        write_ct( $base, $ct ) unless $protected;
        log_event('INFO', $uri, 'page rendered');
        output_page( $page, $ct, $ttl, $protected );
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
        my $converted_form  = convert_fenced_form($body, $meta);
        my $converted       = convert_fenced_divs($converted_form);
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
        my $converted       = convert_fenced_divs($converted_form);
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

        # Parse scalar key: value pairs (skip tt_page_var, register, query_params blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            next if $1 eq 'query_params';
            next if $1 eq 'tags' && ref $meta{tags} eq 'ARRAY';
            next if $1 eq 'auth_groups' && ref $meta{auth_groups} eq 'ARRAY';
            # Strip TT directives from all scalar values including title and subtitle
            $meta{$1} = strip_tt_directives($2);
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

    my $s;
    if ( open( my $rand, '<', '/dev/urandom' ) ) {
        read( $rand, my $bytes, 32 );
        close($rand);
        $s = unpack( 'H*', $bytes );
    }
    else {
        $s = hmac_sha256_hex( time() . $$ . rand(), 'lazysite-form' );
    }

    open( my $fh, '>', $secret_path ) or do {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot write form secret', error => $!);
        return $s;
    };
    chmod 0600, $secret_path;
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

        # Parse rules
        my %rules;
        for my $r ( split /\s+/, $rules_str ) {
            if ( $r eq 'required' )      { $rules{required} = 1; }
            elsif ( $r eq 'optional' )   { $rules{optional} = 1; }
            elsif ( $r eq 'email' )      { $rules{type} = 'email'; }
            elsif ( $r eq 'textarea' )   { $rules{textarea} = 1; }
            elsif ( $r =~ /^select:(.+)/ ) { $rules{select} = [ split /,/, $1 ]; }
            elsif ( $r =~ /^max:(\d+)/ ) { $rules{max} = $1; }
        }

        my $req_attr = $rules{required} ? ' required' : '';
        my $max      = $rules{max} || 1000;
        my $req_mark = $rules{required}
            ? ' <span class="required">*</span>' : '';

        my $field_html;
        if ( $rules{textarea} ) {
            $field_html = qq(    <textarea name="$name" id="$name")
                        . qq( maxlength="$max"$req_attr></textarea>\n);
        }
        elsif ( $rules{select} ) {
            $field_html = qq(    <select name="$name" id="$name"$req_attr>\n);
            $field_html .= qq(      <option value="">-- Select --</option>\n);
            for my $opt ( @{ $rules{select} } ) {
                $opt =~ s/^\s+|\s+$//g;
                $field_html .= qq(      <option value="$opt">$opt</option>\n);
            }
            $field_html .= qq(    </select>\n);
        }
        else {
            my $type = $rules{type} || 'text';
            $field_html = qq(    <input type="$type" name="$name" id="$name")
                        . qq( maxlength="$max"$req_attr>\n);
        }

        push @fields, qq(  <div class="form-field">\n)
                     . qq(    <label for="$name">$label$req_mark</label>\n)
                     . $field_html
                     . qq(  </div>\n);
    }

    my $fields_html = join( '', @fields );

    return <<"END_FORM";
<form method="POST"
      action="/cgi-bin/lazysite-form-handler.pl"
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
            qq(<div class="$class">\n${body}</div>\n);
        }
        else {
            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'fenced div rejected unsafe class', class => $class);
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
        return undef;
    }

    my $oembed_url = $endpoint . '?url=' . uri_encode($url) . '&format=json';
    my $raw = fetch_url($oembed_url);
    unless ($raw) {
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "oembed fetch failed", url => $oembed_url);
        return undef;
    }

    # Parse JSON safely using JSON::PP (S3)
    # Note: JSON::PP gives correct string values but the html field content
    # itself is still trusted as-is. A compromised or malicious provider
    # could return arbitrary HTML. Restrict OEMBED_PROVIDERS to trusted
    # hosts if this is a concern in your deployment.
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data || !defined $data->{html} ) {
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "oembed parse failed", url => $oembed_url, error => $@);
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

sub resolve_site_vars {
    return () unless -f $CONF_FILE;

    my $text = read_file($CONF_FILE);
    my %defs;

    while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) {
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
        $sort_field = 'filename'
            unless $sort_field =~ /^(date|title|filename)$/;
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

        push @pages, {
            url        => $url,
            title      => $meta->{title}    || '',
            subtitle   => $meta->{subtitle} || '',
            date       => $date,
            tags       => \@tags,
            excerpt    => $excerpt,
            searchable => $searchable,
            path       => $path,
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
        %AUTH_CONTEXT,
        %PAYMENT_CONTEXT,
        page_title        => $meta->{title}            || '',
        page_subtitle     => $meta->{subtitle}         || '',
        page_modified     => $meta->{page_modified}    || '',
        page_modified_iso => $meta->{page_modified_iso} || '',
        request_uri       => $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '',
        page_source       => do {
            my $src = $meta->{_md_path} // '';
            $src =~ s{^\Q$DOCROOT\E}{};
            $src || '';
        },
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
            log_event("ERROR", $ENV{REDIRECT_URL} // "-", "template error, using raw content", error => $tt->error());
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

    # Manager path gets dedicated view
    my $manager_path = $vars->{manager_path} || '/manager';
    my $uri = $ENV{REDIRECT_URL} // '';
    if ( index( $uri, $manager_path ) == 0 ) {
        my $manager_view = "$THEMES_DIR/manager/view.tt";
        return ( $manager_view, undef ) if -f $manager_view;
        return ( undef, undef );
    }

    my $name = $meta->{layout} || $vars->{theme} || '';

    if ( $name ) {
        # Check if theme is a remote URL
        if ( $name =~ m{^https?://} ) {
            my ( $cached, $theme_key ) = fetch_remote_layout($name);
            return ( $cached, $theme_key ) if $cached;
            log_event("WARN", $ENV{REDIRECT_URL} // "-", "remote layout fetch failed", name => $name);
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

            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'layout not found, using default', layout => $name);
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
        log_event("WARN", $ENV{REDIRECT_URL} // "-", "view not found, using fallback");
        my $tt_fallback = Template->new( ENCODING => 'utf8' )
            or do {
                log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance');
                return $processed_body;
            };

        $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
            or do {
                log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error());
                return $processed_body;
            };

        return _inject_admin_bar( $output, $vars );
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
        log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create TT instance');
        return $processed_body;
    }

    # Try specified layout
    $tt_layout->process( $layout, $vars, \$output )
        or do {
            log_event('ERROR', $ENV{REDIRECT_URL} // '-', 'layout error, using fallback', layout => $layout, error => $tt_layout->error());
            $output = '';

            # Try built-in fallback layout
            my $tt_fallback = Template->new( ENCODING => 'utf8' )
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

    # Inject admin bar after <body> - outside the theme
    $output = _inject_admin_bar( $output, $vars );

    return $output;
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

    # Manager tools: Manage / Edit / core theme switcher / sign-out
    my $manager_tools = '';
    if ( $is_manager ) {
        $manager_tools .= '<a href="/manager/" style="color:#6db3f2;text-decoration:none;">Manage</a>';

        if ( $page_source ) {
            $manager_tools .= '<a href="/manager/edit?path=' . $page_source
                           .  '" style="color:#6db3f2;text-decoration:none;">Edit</a>';
        }

        # Core theme switcher - changes site default (writes lazysite.conf, clears cache)
        my $themes_dir = "$LAZYSITE_DIR/themes";
        my @installed_themes;
        if ( -d $themes_dir ) {
            opendir( my $dh, $themes_dir );
            for my $t ( sort readdir $dh ) {
                next if $t =~ /^\./;
                next if $t eq 'manager';
                next unless -d "$themes_dir/$t" && -f "$themes_dir/$t/view.tt";
                push @installed_themes, $t;
            }
            closedir $dh;
        }

        if ( @installed_themes > 1 ) {
            my $current = $vars->{theme} || '';
            $manager_tools .= '<select id="ls-theme-sel" data-current="' . $current . '" style="'
                           .  'font-size:11px;background:#333;color:#ccc;border:1px solid #555;'
                           .  'border-radius:3px;padding:1px 4px;cursor:pointer;">';
            for my $t (@installed_themes) {
                my $sel = $t eq $current ? ' selected' : '';
                $manager_tools .= "<option value=\"$t\"$sel>$t</option>";
            }
            $manager_tools .= '</select>';
        }

        if ( $ENV{LAZYSITE_AUTH_NO_PASSWORD} ) {
            $manager_tools .= '<span style="color:#f5a623;">&#9888; No password set for your account.</span>';
            $manager_tools .= '<a href="/manager/users" style="color:#f5a623;text-decoration:underline;">Set one</a>';
        }

        my $user = $vars->{auth_name} || $vars->{auth_user} || '';
        if ( $user ) {
            $manager_tools .= '<span style="margin-left:auto;">' . $user . '</span>';
            $manager_tools .= '<a href="/logout" style="color:#888;text-decoration:none;">Sign out</a>';
        }
    }

    # TODO (D013): theme variant switcher - cookie-based, theme-defined,
    # rendered outside the $is_manager gate so all visitors can use it.
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

    # Theme switcher: activate site-wide via manager API, with confirm + reload
    if ( $is_manager ) {
        $bar .= '<script>(function(){'
              . 'var sel=document.getElementById("ls-theme-sel");'
              . 'if(!sel)return;'
              . 'sel.addEventListener("change",function(){'
              . 'var t=sel.value,cur=sel.dataset.current;'
              . 'if(t===cur)return;'
              . 'if(!confirm("Switch site theme to "+t+"? This affects all visitors.")){sel.value=cur;return;}'
              . 'fetch("/cgi-bin/lazysite-manager-api.pl?action=theme-activate&path="+encodeURIComponent(t),{method:"POST"})'
              . '.then(function(r){return r.json();})'
              . '.then(function(d){if(d.ok){location.reload();}'
              . 'else{alert("Failed: "+(d.error||"unknown"));sel.value=cur;}})'
              . '.catch(function(e){alert("Error: "+e.message);sel.value=cur;});'
              . '});})();</script>';
    }

    # Hide in iframes
    $bar .= '<script>if(window!==window.top){var ab=document.getElementById("ls-admin-bar");'
          . 'var sp=document.getElementById("ls-admin-spacer");'
          . 'if(ab)ab.style.display="none";if(sp)sp.style.display="none";}</script>';

    $html =~ s/(<body[^>]*>)/$1$bar/i;

    return $html;
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
        # and subdirectories inherit the group automatically
        my $gid = ( stat($DOCROOT) )[5];
        chown -1, $gid, $dir;
        chmod 0775 | 02000, $dir;  # 02000 = setgid bit
    }

    open( my $fh, '>:utf8', $html_path ) or do {
        log_event('WARN', $ENV{REDIRECT_URL} // '-', 'cannot write cache file', path => $html_path, error => $!);
        return;
    };
    print $fh $page;
    close $fh;
}

# --- Output ---

sub output_page {
    my ( $content, $content_type, $ttl, $auth_protected ) = @_;
    $content_type //= 'text/html; charset=utf-8';
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\n";
    print "Content-type: $content_type\n";
    if ( $auth_protected ) {
        print "Cache-Control: no-store, private\n";
    }
    elsif ( defined $ttl && $ttl > 0 ) {
        print "Cache-Control: public, max-age=$ttl\n";
    }
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

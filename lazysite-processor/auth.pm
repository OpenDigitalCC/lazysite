package main;

# lazysite-processor/auth.pm - the processor's auth gate: who the request says
# it is, whether a page lets them in, and the refusals when it does not.
#
# HOLDS   check_auth(), the page gate: auth: none / required / optional, the
#         page's auth_groups, the login and manager carve-outs, and the
#         identity read from the (renameable) X-Remote-* headers; peek_auth()
#         and _peek_md(), the single-pass front-matter peek every peek_* reads,
#         with its per-request memo and _reset_peek_cache; _is_manager and
#         _site_grants_manager, the local copy of Auth::Settings'
#         site_grants_manager (ADR 0001); _serve_manager_forbidden, the
#         terminal 403 at /manager/ for an account without `ui`; serve_403,
#         the access refusal rendered from the domain's 403.md.
# OWNS    the page-level auth decision (auth_default, auth_redirect, groups);
#         the unsecured-site rule - no group grants manager access, so every
#         signed-in user is one - and its fail-closed store read (SM906 T3);
#         the 403's content root and header set (SM381).
# CALLS   uri_encode, _groups_grant_cap, _esc_html, output_page,
#         _request_croot, _system_page_md, process_md, _sanitise_not_found,
#         _rewrite_if_changed, _chrome_lang, _chrome, log_event (the script and
#         its parts); JSON::PP::decode_json by its full name (loaded by the
#         script's `use`, before its parts load).
# READS   $DOCROOT and $LAZYSITE_DIR; SETS %ACCESS_REC (the script's, declared
#         `our` there).
#
# The trust gate is NOT here: apply_trust_gate stays in the script's request
# entry, which runs before any of this for a request (lints 13 and 38).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S20). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, %ACCESS_REC );

# --- Auth ---

{
    # F7 (D007): single-pass front-matter peek, memoised per
    # request. Before it, every caller opened the .md file for
    # itself - peek_auth, peek_payment, peek_query_params, peek_ttl
    # and peek_content_type, plus the tt_deps and nocache reads in
    # the cache path, seven sites today; now the first peek reads
    # the file, the rest hit this cache. Cache key is (path, mtime) so
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
            if    ( $line =~ /^auth\s*:\s*(\w+)/i )   { $m{auth}    = lc $1 }
            elsif ( $line =~ /^ttl\s*:\s*(\d+)/ )     { $m{ttl}     = $1 }
            elsif ( $line =~ /^api\s*:\s*true/i )     { $m{api}     = 1 }
            elsif ( $line =~ /^nocache\s*:\s*true/i ) { $m{nocache} = 1 }
            elsif ( $line =~ /^raw\s*:\s*true/i )     { $m{raw}     = 1 }
            # SM656: the page says what KIND of page it is. The admin bar is
            # injected for anyone holding `ui`, which is a property of the
            # PERSON - and on an application page the bar's Edit link opens the
            # Markdown of a page whose body is a script, which is the fastest
            # way to break the application and the most prominent action
            # offered to the person most likely to click it.
            elsif ( $line =~ /^admin_bar\s*:\s*(\w+)/i ) { $m{admin_bar} = lc $1 }
            # SM812: a section's index names the theme its pages inherit. Only a
            # name the page key would accept is recorded, so an unusable value
            # reads as absent and the walk carries on upwards.
            elsif ( $line =~ /^theme\s*:\s*["']?([A-Za-z0-9_-]+)["']?\s*$/ ) { $m{theme} = $1 }
            elsif ( $line =~ /^content_type\s*:\s*(.+)/ ) {
                ( my $v = $1 ) =~ s/^\s+|\s+$//g;
                $m{content_type} = $v;
            }

            # payment.* scalar keys
            for my $pk ( qw(payment payment_amount payment_currency
                payment_network payment_address
                payment_asset payment_description) ) {
                if ( $line =~ /^\Q$pk\E\s*:\s*(.+)$/ ) {
                    ( my $v = $1 ) =~ s/\s+$//;
                    $m{$pk} = $v;
                }
            }

            # auth_groups: block
            if ( $line =~ /^auth_groups\s*:\s*$/ ) {
                $in_groups = 1; $in_qp = 0; next;
            }
            if ($in_groups) {
                if ( $line =~ /^\s+-\s+(.+)$/ ) {
                    ( my $g = $1 ) =~ s/^\s+|\s+$//g;
                    push @groups, $g;
                    next;
                }
                $in_groups = 0 if $line !~ /^\s/;
            }

            # SM311: does this page read anything OTHER than itself?
            #
            # Only the presence of the block is recorded, not its contents. The
            # record itself is written at render time by the code that actually
            # resolved the sources, which is the only place that knows what a
            # `scan:` glob matched. Parsing the sources here would mean two
            # implementations of that question, and the second one would drift.
            #
            # SM888 A2: THIS ANSWERS FOR TWO OF THE THREE SOURCE KINDS. An
            # `::: include` is in the BODY, and this peek stops at the front
            # matter on purpose - a scan puts 200 pages through it. So the
            # cache-hit path asks this AND whether a record already exists,
            # and the two together cover all three. See try_serve_cache.
            $m{tt_deps} = 1 if $line =~ /^tt_page_var\s*:\s*$/;

            # SM857: a `db:...(mine)` binding renders per viewer, so the page
            # takes the gated page's cache treatment (see `$per_viewer` in
            # main). DELIBERATELY WIDER THAN THE GRAMMAR: any front-matter line
            # with `db:` and the word `mine` on it. This is a trigger, not a
            # second parser - a false positive costs a cached render, and a
            # binding this misses is refused by resolve_db, never cached.
            $m{db_mine} = 1 if $line =~ /\bdb:/i && $line =~ /\bmine\b/;

            # query_params: block
            if ( $line =~ /^query_params\s*:\s*$/ ) {
                $in_qp = 1; $in_groups = 0; next;
            }
            if ($in_qp) {
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

    my $auth_user = $ENV{ $make_env->( $site_vars->{auth_header_user} || 'X-Remote-User' ) } // '';
    my $auth_name = $ENV{ $make_env->( $site_vars->{auth_header_name} || 'X-Remote-Name' ) } // '';
    my $auth_email = $ENV{ $make_env->( $site_vars->{auth_header_email} || 'X-Remote-Email' ) } // '';
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
        my %user_groups = map  { lc($_) => 1 } split /\s*,\s*/, $auth_groups;
        my $in_group    = grep { $user_groups{ lc($_) } } @required;
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

# SM138: does ANY group grant manager access (ui / manage_users / the manager
# flag)? When none does, the site is unsecured/dev and any authenticated user is
# a manager. Local copy of the same decision Auth::Settings::site_grants_manager
# makes - the render path stays module-free (ADR 0001).
sub _site_grants_manager {
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return 0 unless -f $f;
    # SM906 T3 follow-up: A STORE THAT EXISTS AND CANNOT BE READ IS SECURED.
    # "0" here means "unsecured site - every signed-in user is a manager", so an
    # unreadable or undecodable groups-settings.json made every session render as
    # an operator. Absent stays unsecured (a site with no groups yet); present but
    # unreadable fails closed, as Auth::Settings::site_grants_manager now does.
    open my $fh, '<:raw', $f or do {
        log_event( 'WARN', '-', 'cannot read groups-settings.json - treating the site as secured',
            error => "$!" );
        return 1;
    };
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) };
    close $fh;
    if ( ref $gs ne 'HASH' ) {
        log_event( 'WARN', '-', 'groups-settings.json does not decode - treating the site as secured' );
        return 1;
    }
    for my $g ( keys %{$gs} ) {
        my $cfg = $gs->{$g};
        next unless ref $cfg eq 'HASH';
        return 1 if $cfg->{ui} || $cfg->{manage_users} || $cfg->{manager};
    }
    return 0;
}

sub _is_manager {
    my ( $site_vars, $auth_user, $auth_groups ) = @_;
    return 0 unless $auth_user;
    # SM095: Manager-UI access is the `ui` channel capability, granted via a
    # group. SM138: the lazysite.conf manager_groups fallback is retired (the
    # migration granted those groups their capabilities explicitly).
    return 1 if _groups_grant_cap( 'ui', split /\s*,\s*/, ( $auth_groups // '' ) );
    unless ( _site_grants_manager() ) {
        # L-3: config advisory, not an operational warning (DEBUG - under CGI
        # every request is a new process; the dev server surfaces it once).
        log_event( 'DEBUG', '-',
            'no group grants manager access - any authenticated user has it',
            suggestion => 'grant the ui capability to a group on the Groups page' );
        return 1;
    }
    return 0;
}

# login-loop fix: an authenticated account without the `ui` capability that
# reaches /manager/ gets this terminal 403 - a clear explanation instead of a
# redirect back to /login (which, seeing the valid session, would loop). Names
# the likely cause (an API/MCP-only account) and the remedy (the connector, or an
# sysop granting `ui`). Self-contained so it renders even if a layout/theme is
# broken.
sub _serve_manager_forbidden {
    my ( $sv, $auth_user ) = @_;
    my $manager_path = $sv->{manager_path} || '/manager';
    my $site         = _esc_html( $sv->{site_name} // 'this site' );
    my $who          = _esc_html($auth_user);
    $ACCESS_REC{s} //= 403;    # SM140
                               # SM381: through output_page, like every other refusal.
    my $body = <<"HTML";
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Manager access not permitted</title></head>
<body style="font-family:system-ui,sans-serif;max-width:520px;margin:3em auto;padding:0 1em;line-height:1.5;">
<h1 style="font-size:1.3rem;">Manager access not permitted</h1>
<p>You are signed in to $site as <strong>$who</strong>, but this account is not
permitted to use the manager interface.</p>
<p>This is normal for an API / MCP account: connect your AI assistant through the
<em>connector</em> rather than the browser manager.</p>
<p>If you should have manager access, ask a sysop to grant your group the
<strong>ui</strong> capability on the Groups page. You can
<a href="/logout">sign out</a> in the meantime.</p>
</body></html>
HTML
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '403 Forbidden' );
}

sub serve_403 {
    my ($auth_result) = @_;

    # SM381: THE DOMAIN'S CONTENT ROOT, and through output_page.
    #
    # Two defects, both of which SM253 already fixed for the 404 and neither of
    # which was carried across:
    #
    #   the ROOT   _system_page_md was called with no content root and the cache
    #              slot was hard-coded to $DOCROOT, so on a multi-domain
    #              instance domain B's 403 was RENDERED INTO domain A's docroot
    #              and then served to both. One site's branding and navigation
    #              shown to a visitor refused on another.
    #   the HEADERS this printed its own status line and content type, so the
    #              two responses a scanner is most likely to reach carried no
    #              nosniff, no frame options, no HSTS and no CSP. The comment on
    #              _security_headers claimed every response path called it; it
    #              was not true of these two.
    my $croot   = _request_croot();
    my $md_path = _system_page_md( '403', $croot ) // "$DOCROOT/403.md";    # SM201

    $ACCESS_REC{s} //= 403;    # SM140
    $ACCESS_REC{ar} = 1;       # SM223: an ACCESS refusal, not a missing page
    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $html_path = "$croot/403.html";
        my $page      = process_md( $md_path, $html_path, ( stat($md_path) )[9], {} );

        # SM371: an error page is not the canonical version of anything, and the
        # cached file the front end serves at 403.html must not say otherwise.
        $page = _sanitise_not_found($page);
        _rewrite_if_changed( $html_path, $page ) if -f $html_path;

        # SM381: through output_page, which carries the baseline header set and
        # records the byte count for analytics. no-store/private is what
        # output_page already emits for an auth-protected response, which this
        # is by definition.
        return output_page( $page, 'text/html; charset=utf-8', undef, 1,
            '403 Forbidden' );
    }
    # SM381: the bare fallback goes through output_page too. It is the path a
    # site reaches before 403.md exists - a fresh install - so leaving it
    # printing its own headers would mean the responses least likely to be
    # noticed are the ones without the header set.
    my $lang = _chrome_lang();
    my $body
        = qq{<!DOCTYPE html><html lang="$lang"><head><meta charset="utf-8">}
        . '<title>403 Forbidden</title></head><body>'
        . '<h1>' . _chrome('forbidden.title') . '</h1>'
        . '<p>'
        . (
        ( ( $auth_result->{auth_denied_reason} // '' ) eq 'insufficient_groups' )
        ? _chrome('forbidden.insufficient')
        : _chrome('auth.required')
        )
        . '</p></body></html>';
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '403 Forbidden' );
}

1;

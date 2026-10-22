package main;

# lazysite-processor/auth.pm - the processor's auth gate: who the request says
# it is, whether a page lets them in, and the refusals when it does not.
#
# HOLDS   check_auth(), the page gate: auth: none / required / optional, the
#         page's auth_groups, the login and manager carve-outs, and the
#         identity from Lazysite::Auth::Identity (SM1131); peek_auth()
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
# CALLS   uri_encode, _groups_grant_cap, _esc_html, output_page, _access_keys_read,
#         _request_croot, _system_page_md, process_md, _sanitise_not_found,
#         _rewrite_if_changed, _chrome_lang, _chrome, _draft_is, _draft_stat,
#         _pp_page_may_ask, log_event (the script and its parts); JSON::PP::decode_json by its
#         full name (loaded by the script's `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $CONF_FILE, $DRAFT_BYTES (SM1030: the peek reads a
#         draft from memory) and $REQUEST_IDENT (SM1181: the held identity value); SETS %ACCESS_REC (the script's, declared `our`
#         there).
#
# The trust gate is NOT here: apply_trust_gate stays in the script's request
# entry, which runs before any of this for a request (lints 13 and 38).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S20). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing up front - ADR 0001 keeps the render path free of the Lazysite::
# tree; the one identity reader is loaded on first use by _lazy_lib (SM1131).
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $CONF_FILE, $DRAFT_BYTES, $REQUEST_IDENT, %ACCESS_REC );

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
        # SM1030: a draft stands in for the file at its path - read from memory,
        # and memoised under its own key so it never answers for the file.
        my $draft = _draft_is($path);
        my @st    = $draft ? _draft_stat() : stat($path);
        return {} unless @st;
        my $key = $draft ? "\0draft:$path" : "$path:$st[9]";
        return $_peek_cache{$key} if exists $_peek_cache{$key};

        my %m;
        my @qp;
        my $in_qp;
        # SM980: the FRONT MATTER, for _access_keys_read - only when the file
        # opens with one; a page without front matter declares no access keys.
        my ( $fm_text, $has_fm ) = ( '', 0 );
        my %pp_may = map { $_ => 1 } _pp_page_may_ask();    # SM1266

        my $fh;
        ( $draft ? open( $fh, '<:utf8', \$DRAFT_BYTES ) : open( $fh, '<:utf8', $path ) ) or do {
            $_peek_cache{$key} = \%m;
            return \%m;
        };
        while ( my $line = <$fh> ) {
            last if $. > 1 && $line =~ /^---/;
            if    ( $. == 1 && $line =~ /^\x{FEFF}?---/ ) { $has_fm = 1 }
            elsif ($has_fm)                               { $fm_text .= $line }

            # scalar keys (SM980: `auth` is read with the other access keys,
            # below the loop, by _access_keys_read)
            if    ( $line =~ /^ttl\s*:\s*(\d+)/ )     { $m{ttl}     = $1 }
            elsif ( $line =~ /^api\s*:\s*true/i )     { $m{api}     = 1 }
            elsif ( $line =~ /^nocache\s*:\s*true/i ) { $m{nocache} = 1 }
            elsif ( $line =~ /^raw\s*:\s*true/i )     { $m{raw}     = 1 }
            # SM1174 (L-16), SM1266: `camera: self` - and since SM1266 the same
            # for every feature a page may ask for (_pp_page_may_ask), such as
            # `geolocation: self` - the ONE value that lets this page alone send
            # <feature>=(self) on https. Exactly that and nothing else reads as a
            # grant - `*`, a URL, `Self` or a typo leaves the page on <feature>=()
            # - and only inside the front matter, so a body line that happens to
            # read "camera: self" grants nothing.
            elsif ( $has_fm
                && $line =~ /^([a-z-]+)[ \t]*:[ \t]*([\x22\x27]?)self\2[ \t]*\r?$/
                && $pp_may{$1} )
            {
                push @{ $m{permissions} }, $1;
            }
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
                # SM1213: one pair of quotes is YAML syntax, as everywhere else
                # in the front matter - `"text/html"` kept its quotes, so the
                # ADR 0006 downgrade did not match it and it was sent as written.
                $v =~ s/\A"(.*)"\z/$1/ or $v =~ s/\A'(.*)'\z/$1/;
                $m{content_type} = $v;
            }

            # payment.* scalar keys (SM980: `payment` itself is an access key,
            # read below the loop)
            for my $pk ( qw(payment_amount payment_currency
                payment_network payment_address
                payment_asset payment_description) ) {
                if ( $line =~ /^\Q$pk\E\s*:\s*(.+)$/ ) {
                    ( my $v = $1 ) =~ s/\s+$//;
                    $m{$pk} = $v;
                }
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

            # SM747 C: an `odoo-identity:` binding renders who the viewer is in Odoo,
            # so the page is per viewer and takes the same treatment. A trigger, not a
            # parser: one this misses is refused by resolve_odoo_identity, never cached.
            $m{odoo_me} = 1 if $line =~ /\bodoo-identity:/;

            # query_params: block
            if ( $line =~ /^query_params\s*:\s*$/ ) {
                $in_qp = 1; next;
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

        # SM1213: api: and raw: AS THE RENDER READS THEM, too. The render serves
        # a page verbatim on its own reading (_front_matter_scalars: the last
        # one, one pair of quotes stripped) and the downgrade of a script-capable
        # content type (peek_content_type, ADR 0006) read only the line test
        # above - so `api: "true"` was served verbatim as the text/html it
        # declared. Either reading marks the page; the line test stays, because
        # wider is the safe direction here.
        # A text whose reading dies (bytes that are not UTF-8, SM976 Q15h) leaves the
        # peek with what the line test found, as before; one such page in a scan
        # must not fail the scan.
        if ($has_fm) {
            my %rs;
            eval {
                for my $kv ( _front_matter_scalars($fm_text) ) {
                    $rs{ $kv->[0] } = $kv->[1] if $kv->[0] eq 'api' || $kv->[0] eq 'raw';
                }
                1;
            };
            for my $k (qw(api raw)) { $m{$k} = 1 if ( $rs{$k} // '' ) =~ /\Atrue\z/i }
        }

        # SM980: auth, auth_groups and payment, read by the one reader.
        # `groups` keeps its contract (present only when the page names
        # some); a key that cannot be read is recorded with its reason,
        # and check_auth refuses the page to everyone.
        my $ak = _access_keys_read($fm_text);
        $m{auth}    = $ak->{auth}    if defined $ak->{auth};
        $m{payment} = $ak->{payment} if defined $ak->{payment};
        $m{groups} = $ak->{auth_groups} if ref $ak->{auth_groups} eq 'ARRAY' && @{ $ak->{auth_groups} };
        # SM1139: the address lists a page names, on the same terms as its groups.
        for my $k (qw(addresses addresses_deny)) {
            $m{$k} = $ak->{$k} if ref $ak->{$k} eq 'ARRAY' && @{ $ak->{$k} };
        }
        $m{access_unreadable} = $ak->{unreadable} if %{ $ak->{unreadable} };
        $m{query_params}      = \@qp              if @qp;

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
    return {} unless $path && ( -f $path || _draft_is($path) );    # SM1030
    return {
        auth   => $m->{auth},
        groups => $m->{groups} // [],
        # SM1139: the address lists the page names (empty when it names none).
        addresses      => $m->{addresses}      // [],
        addresses_deny => $m->{addresses_deny} // [],
        # SM993: a paid page's auth_groups is its payment bypass, not a sign-in.
        payment => $m->{payment},
        # SM980: { key => why } for an access key that cannot be read.
        ( $m->{access_unreadable} ? ( unreadable => $m->{access_unreadable} ) : () ),
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
    my $in_manager = ( index( $uri, "$manager_path/" ) == 0 || $uri eq $manager_path ) ? 1 : 0;
    if ($in_manager) {
        $auth_level = 'none';
    }

    # SM1131: who is asking comes from the one reader (_request_identity), not
    # from a header name spelled here - the page gate used to be the only reader
    # that honoured the configured names.
    my $ident       = _request_identity( conf => $site_vars );
    my $auth_user   = $ident->{user};
    my $auth_name   = $ident->{name};
    my $auth_email  = $ident->{email};
    my @auth_groups = @{ $ident->{groups} };

    my $authenticated = $auth_user ne '' ? 1 : 0;

    # SM980 (ruled 2026-10-11, "Parse it + fail closed"): AN ACCESS KEY THE
    # ENGINE CANNOT READ REFUSES THE PAGE TO EVERYONE. `auth_groups: [a, b]`
    # was not read at all, so the page applied no group restriction and every
    # signed-in user got it, rows and all; `auth: "required"` and
    # `payment: "required"` did the same for anonymous visitors. The flow
    # list is read now; what is still unreadable is a restriction the author
    # meant and the engine cannot apply, and the safe answer to that is no.
    # 403 for everyone, signed in or not, and a line naming the key.
    #
    # SM993 (ruled 2026-10-12, Finding 4, "Fix both as recommended"): `auth:
    # manager` is enforced by the manager path's own gate and by nothing else, so
    # on a content page it served the page to anonymous visitors. Outside the
    # manager path it is UNREADABLE, by the reader's own words.
    my %unreadable = %{ ref $auth_meta->{unreadable} eq 'HASH' ? $auth_meta->{unreadable} : {} };
    if ( !$in_manager && ( $auth_meta->{auth} // '' ) eq 'manager' ) {
        $unreadable{auth} = _access_keys_read( "auth: manager\n", 'content' )->{unreadable}{auth};
    }
    if (%unreadable) {
        my $u = \%unreadable;
        for my $k ( sort keys %$u ) {
            log_event( 'WARN', $uri, 'access key unreadable - page refused to everyone',
                key => $k, why => $u->{$k} );
        }
        # SM1189 (0.15.10 walk, F-2): `addresses: zz60-mine` (a bare value) was
        # refused with "sign in", to a member who was signed in. When the only
        # keys the engine cannot read are address rules, the refusal is the one
        # SM1139 ruled for every refusal by address - this page is not available
        # from your address - which sends nobody to a sign-in that cannot help and,
        # like those, names no list and no key (the author is told by the validator
        # and `lazysite check`, the visitor is not). Still a refusal to everyone.
        my $only_address = !grep { !/\Aaddresses(?:_deny)?\z/ } keys %$u;
        # SM1201 (SM1189's open note): a bare `auth_groups: staff` said "sign in" the
        # same way, to a member who was signed in. When the keys the engine cannot
        # read are only address and group rules, no sign-in can help either, and
        # the refusal is a plain sentence naming no key and no group (the author is
        # told by the validator and `lazysite check`). A page whose unreadable keys
        # include `auth` or `payment` keeps its existing refusal: there a sign-in
        # or a payment is what the page was asking for.
        my $only_rules = !grep { !/\A(?:addresses(?:_deny)?|auth_groups)\z/ } keys %$u;
        return {
            forbidden          => 1,
            auth_user          => $auth_user,
            auth_name          => $auth_name,
            auth_denied_reason => $only_address ? 'address' : $only_rules ? 'unreadable_rule' : 'unreadable_access_key',
        };
    }

    # SM993 (ruled 2026-10-12, Finding 3, "Fix both as recommended"): AUTH_GROUPS
    # MEANS SIGNED IN. With `auth: none` (the default) or `optional` the group
    # test below never ran for an anonymous visitor - nor, for `none`, for anyone
    # - so the page went to the public while a signed-in non-member was refused.
    # A page naming groups is read as `auth: required`. Not on a PAID page: there
    # auth_groups is the list that skips payment (docs/payment, check_payment)
    # and everyone else is charged, which stays as it was. Not under the manager
    # path, whose own gate decides.
    my @required = @{ $auth_meta->{groups} // [] };
    $auth_level = 'required'
        if @required && !$in_manager && ( $auth_meta->{payment} // '' ) ne 'required';

    # For 'none' pages, return auth context without enforcement
    if ( $auth_level eq 'none' ) {
        return {
            ok            => 1,
            auth_user     => $auth_user,
            auth_name     => $auth_name,
            auth_email    => $auth_email,
            auth_groups   => [@auth_groups],
            authenticated => $authenticated,
        };
    }

    if ( !$authenticated && $auth_level eq 'required' ) {
        my $next = uri_encode($uri);
        return { redirect => "$redirect_path?next=$next" };
    }

    # Group check
    if ( $authenticated && @required ) {
        my %user_groups = map  { lc($_) => 1 } @auth_groups;
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
        auth_groups   => [@auth_groups],
        authenticated => $authenticated,
    };
}

# SM1131: THE PROCESSOR'S WAY TO THE ONE IDENTITY READER. Lazysite::Auth::Identity
# is the only code that reads the identity headers out of the environment; the
# processor reaches it by the lazy loader (ADR 0001 keeps the render path from
# loading the lib tree up front), and every processor reader - the page gate, the
# manager entry, the layout's admin bar, the data sources, the scan - calls this.
# `conf` is the caller's site vars when it has them; otherwise the reader reads the
# processor's own conf file. `proxy` is the render path's answer to "is the proxy
# trusted for this request" - _proxy_identity, the pinned copy the trust gate
# asked (SM1129) - so the reader decides which header names count by the same
# answer that decided which headers survived the gate, and never by the flag.
#
# SM1181 S2 (SM1082 C2): `identity` is the request's identity value when one is
# held ($REQUEST_IDENT; the pool's front door sets it from S3), and the reader
# then returns it and reads no environment. `pool` says this is a FastCGI worker,
# where the reader never believes LAZYSITE_AUTH_TRUSTED from %ENV (R3, T3), as the
# trust gate does not.
sub _request_identity {
    my (%o) = @_;
    _lazy_lib('Lazysite::Auth::Identity');
    return Lazysite::Auth::Identity::request_identity(
        ( ref $o{conf} eq 'HASH' ? () : ( conf_file => $CONF_FILE ) ),
        lazysite_dir => $LAZYSITE_DIR,
        proxy        => _proxy_identity(),
        identity     => $REQUEST_IDENT,
        pool         => ( _runtime() eq 'pool' ? 1 : 0 ),
        %o );
}

# SM1070: the account has no password, so the admin bar warns. SM1181 S2: from the
# held identity value when there is one; otherwise the wrapper's
# LAZYSITE_AUTH_NO_PASSWORD on plain CGI. In the pool that flag is a FastCGI
# parameter like the sentinel and is not read (R3): only a value says it.
sub _request_no_password {
    if ( ref $REQUEST_IDENT eq 'HASH' ) { return $REQUEST_IDENT->{no_password} ? 1 : 0 }
    return _runtime() eq 'pool' ? 0 : ( $ENV{LAZYSITE_AUTH_NO_PASSWORD} ? 1 : 0 );
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
    # SM1135: groups a trusted proxy named grant `ui` only if the operator marked
    # them (R1); page and file access by name is unaffected.
    return 1 if _groups_grant_cap( 'ui', _cap_groups( split /\s*,\s*/, ( $auth_groups // '' ) ) );
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

# SM1140: the manager refused by the visitor's address (manager_addresses). Stands
# alone for the same reason _serve_manager_forbidden does, and says the one ruled
# sentence without naming a list.
sub _serve_manager_address_refused {
    my ($sv) = @_;
    $ACCESS_REC{s} //= 403;
    $ACCESS_REC{ar} = 1;    # an ACCESS refusal, as serve_403 records
    my $body = <<"HTML";
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Access Denied</title></head>
<body style="font-family:system-ui,sans-serif;max-width:520px;margin:3em auto;padding:0 1em;line-height:1.5;">
<h1 style="font-size:1.3rem;">Access Denied</h1>
<p>This page is not available from your address.</p>
</body></html>
HTML
    return output_page( $body, 'text/html; charset=utf-8', undef, 1, '403 Forbidden' );
}

# SM1201: the refusal for an access rule the engine cannot read and no sign-in can
# mend (a bare auth_groups, as SM1189 did for addresses). Plain: it names no key and
# no group, and it does not send the reader to sign in.
sub _unreadable_rule_sentence { return 'This page is not available.' }

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

        # SM1139: the refusal by address says the ruled sentence. The shipped 403
        # page has a branch for it; a site's own copy of the page may not, and
        # would say "sign in" to a visitor no sign-in can admit. So the sentence
        # is put after the first heading when the page did not carry it.
        # SM1201: and the same for the sentence of a rule that cannot be read.
        my $reason = $auth_result->{auth_denied_reason} // '';
        if ( $reason eq 'address' || $reason eq 'unreadable_rule' ) {
            my $said = $reason eq 'address' ? _address_refusal_sentence() : _unreadable_rule_sentence();
            unless ( index( $page, $said ) >= 0 ) {
                my $p = "<p>$said</p>";
                $page =~ s{(</h1>)}{$1$p}i or $page =~ s{(<body[^>]*>)}{$1$p}i or $page = $p . $page;
            }
        }

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
        ( ( $auth_result->{auth_denied_reason} // '' ) eq 'address' )
        ? _address_refusal_sentence()    # SM1139
        : ( ( $auth_result->{auth_denied_reason} // '' ) eq 'unreadable_rule' )
        ? _unreadable_rule_sentence()    # SM1201
        : ( ( $auth_result->{auth_denied_reason} // '' ) eq 'insufficient_groups' )
        ? _chrome('forbidden.insufficient')
        : _chrome('auth.required')
        )
        . '</p></body></html>';
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '403 Forbidden' );
}

1;

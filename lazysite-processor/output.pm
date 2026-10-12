package main;

# lazysite-processor/output.pm - the processor's responses and their headers.
#
# HOLDS   output_page(): every rendered response - status, content type, the
#         security header set, Content-Language, Cache-Control, and the form
#         timing token minted fresh per response over the cached
#         placeholders; forbidden() and not_found() (the 404 page through
#         output_page, with _sanitise_not_found and _rewrite_if_changed);
#         _security_headers, _content_security_policy, _inline_script_hashes,
#         _csp_mode and _is_manager_request (the ADR 0001 copy of
#         Lazysite::SecurityHeaders, pinned by value by t/lint/55), with
#         _csp_origin_ok and _csp_allow (P16, the allow-lists; t/lint/225); _conf_value
#         and _conf_flag_enabled, the lazysite.conf readers; _ai_partner_doc, the .well-known/ai-partner
#         document built from the live config; _request_croot.
# OWNS    the bytes of a response's head; which security headers it carries;
#         what the site's discovery document says.
# CALLS   process_md, _system_page_md, _chrome, load_form_secret, is_fresh,
#         _draft_requested,
#         confine_content_root, _cache_umask, read_file, resolve_site_vars,
#         log_event (the script
#         and its parts); hmac_sha256_hex, sha256, encode_base64 (imported by
#         the script's `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $REQUEST_CROOT, $RESPONSE_LANG, %ACCESS_REC,
#         $FORM_TS_PLACEHOLDER, $FORM_TK_PLACEHOLDER (the script's, declared
#         `our` there; the two placeholders are set in the script's BEGIN,
#         which runs after this part loads and before any sub here is called).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S12). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $REQUEST_CROOT, $RESPONSE_LANG, %ACCESS_REC, $FORM_TS_PLACEHOLDER, $FORM_TK_PLACEHOLDER );

# --- Output ---

sub output_page {
    # SM253: $status lets a non-200 response (the 404 path) share this function,
    # and therefore the baseline security headers. Optional and last, so every
    # existing caller keeps emitting 200 unchanged.
    # SM381: $extra carries response headers only one caller has - the 402's
    # X-Payment-Response. Optional and last for the same reason $status was:
    # every existing caller is unchanged.
    my ( $content, $content_type, $ttl, $auth_protected, $status, $extra ) = @_;
    $content_type //= 'text/html; charset=utf-8';
    $status       //= '200 OK';

    # SM252: mint the form timing token HERE, per response, rather than at render
    # time where it would be baked into the cached page and shared by every
    # visitor. This is the single choke point every path reaches - fresh render,
    # cache hit and the TTL path alike - so there is nowhere for a stale token to
    # get out.
    my $ph_ts    = $FORM_TS_PLACEHOLDER;
    my $ph_tk    = $FORM_TK_PLACEHOLDER;
    my $has_form = defined $content && index( $content, $ph_ts ) >= 0;
    if ($has_form) {
        my $ts = time();
        my $tk = hmac_sha256_hex( $ts, load_form_secret() );
        $content =~ s/\Q$ph_ts\E/$ts/g;
        $content =~ s/\Q$ph_tk\E/$tk/g;
    }

    my ($code) = $status =~ /\A(\d{3})/;
    $ACCESS_REC{s} //= ( $code // 200 );          # SM140
    $ACCESS_REC{b} = length( $content // '' );    # SM140
    binmode( STDOUT, ':utf8' );
    print "Status: $status\n";
    print "Content-type: $content_type\n";
    # L-1 set the baseline here and recorded a decision that SM352 has since
    # overturned, so the reasoning is kept rather than quietly replaced. It read:
    # "CSP and HSTS are deliberately NOT emitted here - CSP is site-specific and
    # HSTS depends on whether TLS is in use; both belong in the Apache vhost
    # config." SM286 settled that the other way - "belongs in the vhost config"
    # is the reasoning behind SM248, SM268 H17 and SM283 - so HSTS is emitted
    # here, gated on the connection actually being secure.
    #
    # CSP is STILL not emitted, for the reason L-1 gave and one more: this file
    # alone inlines <style> and <script> in eight places, so no policy worth
    # setting fits today. t/lint/56 holds that inventory - ten entries across
    # the engine - which is what a report-only collector would otherwise have
    # had to discover from live traffic, for a fact the source already states.
    print "$_\n" for _security_headers( html => $content );          # SM352
    print "$_\n" for @{ $extra || [] };                              # SM381
    print "Content-Language: $RESPONSE_LANG\n" if $RESPONSE_LANG;    # SM179 (P1)
    if ($auth_protected) {
        print "Cache-Control: no-store, private\n";
    }
    elsif ($has_form) {
        # SM252, second half: minting per response fixes the SERVER cache and
        # achieves nothing if a shared HTTP cache then hands one response to
        # everyone. A page carrying a form is per-visitor by definition, so it
        # must not be publicly cacheable however generous its page TTL.
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
    $ACCESS_REC{s} //= 403;    # SM140
                               # SM381: through output_page like every other refusal.
    return output_page( "403 Forbidden\n", 'text/plain; charset=utf-8',
        undef, 1, '403 Forbidden' );
}

# SM352: the response security headers.
#
# DELIBERATE local copy of Lazysite::SecurityHeaders::security_headers - the
# render path loads no Lazysite modules (ADR 0001), exactly as _acl_allows_read
# copies Auth::Acl and _private_root_for copies Lazysite::Private. t/lint/55
# pins the pair, and pins it by VALUE: it evaluates both and compares the header
# lines, so a copy that drifts in the max-age or drops a denied capability fails
# rather than merely looking different.
#
# Every response path here calls this - and SM381 is what made that TRUE rather
# than merely stated. Before SM352 three of the four known paths wrote their own
# shorter list, which is why the site's stylesheets and artwork answered without
# X-Frame-Options or Referrer-Policy while the homepage carried both.
#
# THE SENTENCE ABOVE WAS WRONG FOR LONGER THAN THE DEFECT IT DESCRIBED. SM352
# fixed "the four paths" and left this claiming all of them, while 402, 403, the
# ACL static refusal, the manager-access refusal, forbidden(), five redirects,
# the 500, the registry outputs and two .well-known endpoints each still printed
# their own. A comment asserting completeness is a claim like any other, and this
# one went unchecked because it read like a description of the code beneath it.
#
# Counted, so the claim can be re-checked rather than re-trusted: every
# `print "Status:` in this file is either output_page itself or is followed by
# this call.
# SM352: the CSP. A DELIBERATE COPY of Lazysite::SecurityHeaders, like the
# header set below it - the render path loads no Lazysite modules (ADR 0001) -
# and pinned to the module BY VALUE by t/lint/55, which drives both and compares
# what they produce.
#
# MEASURED before it was written: 22 of the 23 shipped layouts inline a
# <script>, so `script-src 'self'` alone would take down every site running a
# shipped layout, which is all of them. Hashing what is actually in the response
# covers the catalogue, the manager's head script and anything a future layout
# adds - without the engine knowing what any of them are, and without
# 'unsafe-inline', which would permit injected script exactly as readily as
# authored script.
#
# The bytes hashed are EXACTLY what sits between the tags. A hash over a trimmed
# or normalised copy matches nothing and fails silently in the browser, on a
# page that renders blank.
sub _inline_script_hashes {
    my ($html) = @_;
    return () unless defined $html && length $html;
    my ( @hashes, %seen );
    while ( $html =~ m{<script\b([^>]*)>(.*?)</script\s*>}gis ) {
        my ( $attrs, $body ) = ( $1, $2 );
        next if $attrs =~ /\bsrc\s*=/i;    # covered by 'self'
            # SM384: HASH THE BYTES THE BROWSER RECEIVES, NOT THE CHARACTERS.
            #
            # A TT-rendered response is a CHARACTER string. Digest::SHA operates on
            # bytes and DIES on a wide character - "Wide character in subroutine
            # entry" - so a single non-ASCII character anywhere inside an inline
            # script aborted the response mid-headers and the browser got a 200 with
            # an empty body. On the manager that is every page, in the DEFAULT
            # report-only mode, because the manager's own scripts carry non-ASCII.
            #
            # And the quieter half: U+0080-U+00FF does not die. It hashes the
            # LATIN-1 byte where the browser hashes the two UTF-8 bytes it actually
            # received, so the hash simply does not match and the script is refused
            # with no error anywhere.
            #
            # Found by driving a real browser against a real manager. Nothing in
            # this suite renders a manager page end to end through the real layout,
            # which is why every test passed.
        my $bytes = $body;
        utf8::encode($bytes) if utf8::is_utf8($bytes);
        my $b64 = encode_base64( sha256($bytes), '' );
        next if $seen{$b64}++;
        push @hashes, "'sha256-$b64'";
    }
    return @hashes;
}

# P16 (ruled 2026-10-12, "Add allow-lists"): $allow is { script, connect, img,
# frame } => [ origins ], each appended to its directive's default sources -
# script-src's before the hashes. A MARKED COPY of
# Lazysite::SecurityHeaders::content_security_policy (ADR 0001), compared by
# value in t/lint/55; the origins are filtered here as there.
sub _content_security_policy {
    my ( $hashes, $allow ) = @_;
    my %a = map {
        my $d = $_;
        ( $d => [ grep { _csp_origin_ok($_) } @{ ( ref $allow eq 'HASH' && $allow->{$d} ) || [] } ] )
    } qw(script connect img frame);
    return join '; ',
        q{default-src 'self'},
        q{base-uri 'self'},
        q{object-src 'none'},
        q{form-action 'self'},
        q{frame-ancestors 'self'},
        q{style-src 'self' 'unsafe-inline'},
        join( ' ', q{img-src 'self' data: https:}, @{ $a{img} } ),
        q{media-src 'self' https:},
        join( ' ', q{frame-src 'self' https:}, @{ $a{frame} } ),
        q{font-src 'self' data:},
        join( ' ', q{connect-src 'self'}, @{ $a{connect} } ),
        join( ' ', q{script-src 'self'}, @{ $a{script} }, @{ $hashes || [] } );
}

# P16: is this an origin a CSP allow-list may name - https://host[:port], the
# host DNS-shaped with two labels or more, a leading `*.` allowed, and nothing
# else? A MARKED COPY of Lazysite::SecurityHeaders::csp_origin_ok; t/lint/225
# runs both over the same texts.
sub _csp_origin_ok {
    my ($o) = @_;
    return 0 unless defined $o && !ref $o;
    return $o =~ m{\A https:// (?: \*\. )?
        [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )?
        (?: \. [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )? )+
        (?: : [1-9][0-9]{0,4} )? \z}xi ? 1 : 0;
}

# P16: this response's allow-lists - the site's csp_<d>_src, or the serving
# domain's alias.<host>.csp_<d>_src (resolve_site_vars overlays it), each entry
# that is not an origin dropped and logged. None on the manager: its pages load
# nothing from elsewhere, and an allow-list there would widen the one surface
# where an injection reaches an operator's session. Outside a render (the
# lint's extracted copy) there are none.
sub _csp_allow {
    return {} if _is_manager_request();
    my %sv = eval { resolve_site_vars() };
    my %allow;
    for my $d (qw(script connect img frame)) {
        my $raw = $sv{"csp_${d}_src"};
        next unless defined $raw && !ref $raw && length $raw;
        my %seen;
        for my $o ( grep { length } split /[\s,]+/, $raw ) {
            if ( _csp_origin_ok($o) ) { push @{ $allow{$d} }, lc $o unless $seen{ lc $o }++; next }
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                "csp_${d}_src entry is not an https origin - left out of the policy", entry => $o );
        }
    }
    return \%allow;
}

sub _security_headers {
    my (%opt) = @_;
    my @h = (
        'X-Content-Type-Options: nosniff',
        'X-Frame-Options: SAMEORIGIN',
        'Referrer-Policy: strict-origin-when-cross-origin',
        'Permissions-Policy: accelerometer=(), browsing-topics=(), camera=(), '
            . 'display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), '
            . 'microphone=(), midi=(), payment=(), usb=(), xr-spatial-tracking=()',
    );

    # Same test the session cookie uses for its Secure flag, so there is one
    # answer to "is this connection secure" rather than two that can disagree.
    # A front end that does not set it gets no HSTS, which is the safe way for
    # this to fail - the engine asks the proxy for nothing.
    push @h, 'Strict-Transport-Security: max-age=300' if $ENV{HTTPS};

    # Only on HTML: a stylesheet or an image has no script to govern.
    #
    # SM380: the MODE is a site decision and the default is REPORT-ONLY. Step 5
    # shipped this enforcing with no way to turn it down, and a CSP hash covers
    # a <script> BLOCK and NOT an inline event-handler attribute - so an
    # enforcing policy silently stops the manager's own onclick= controls
    # firing, which no processor-driven test can see because the failure is in a
    # browser.
    if ( defined $opt{html} ) {
        # SM429: see Lazysite::SecurityHeaders - this is the processor's pinned
        # copy (t/lint/55 compares the two by value). same-origin-allow-popups,
        # because the manager's open-in-new-tab and the OAuth popup flow both
        # depend on opened windows keeping their opener.
        push @h, 'Cross-Origin-Opener-Policy: same-origin-allow-popups';
        my $mode = _csp_mode();

        # SM380: THE MANAGER IS NEVER ENFORCED, whatever the site is set to,
        # until its inline handlers are converted.
        #
        # A CSP hash covers a <script> BLOCK and not an inline event-handler
        # ATTRIBUTE. The manager's pages carry 186 of them - 59 in static markup
        # and 127 generated inside JS strings with interpolated arguments - so
        # enforcing there would silently stop a sysop's controls firing.
        #
        # Report-only rather than a looser manager policy: 'unsafe-inline' would
        # break nothing either, and would weaken the ONE surface where an
        # injection reaches an operator's session. Reporting weakens nothing and
        # records the debt. SM380 carries the conversion.
        $mode = 'report-only' if $mode eq 'enforce' && _is_manager_request();

        if ( $mode ne 'off' ) {
            my $name
                = $mode eq 'enforce'
                ? 'Content-Security-Policy'
                : 'Content-Security-Policy-Report-Only';
            push @h, "$name: "
                . _content_security_policy( [ _inline_script_hashes( $opt{html} ) ], _csp_allow() );
        }
    }
    return @h;
}

# Is this request for the manager UI? Read from the URI rather than from the
# rendered content, because the content is what we are deciding a policy FOR and
# matching on it would make the policy depend on the page it governs.
sub _is_manager_request {
    my $uri = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '';
    $uri =~ s/\?.*\z//;
    my $mp = eval { my %sv = resolve_site_vars(); $sv{manager_path} } || '/manager';
    return ( $uri eq $mp || index( $uri, "$mp/" ) == 0 ) ? 1 : 0;
}

# The CSP mode from lazysite.conf. A deliberate copy of
# Lazysite::SecurityHeaders::_csp_mode (ADR 0001), pinned by t/lint/55.
#
# AN UNRECOGNISED VALUE IS REPORT-ONLY, NOT OFF. A typo must not silently
# disable the header - the direction SM356 found failing open on the update
# channel, where a misspelling granted rather than refused.
sub _csp_mode {
    my $v = _conf_value('csp');
    return 'report-only' unless defined $v && length $v;
    $v = lc $v;
    $v =~ s/^\s+|\s+$//g;
    $v = 'report-only' if $v eq 'report_only' || $v eq 'reportonly';
    return ( grep { $_ eq $v } qw(enforce report-only off) ) ? $v : 'report-only';
}

# A raw string value from lazysite.conf. _conf_flag_enabled answers yes/no; this
# answers "what did they write", which a three-way setting needs.
sub _conf_value {
    my ($key) = @_;
    open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" or return undef;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\Q$key\E\s*:\s*(\S+)/;
        close $fh;
        return $1;
    }
    close $fh;
    return undef;
}

# SM190: is a lazysite.conf service flag enabled? A tiny standalone reader - the
# processor loads no Lazysite modules - mirroring Lazysite::Util::service_enabled:
# default OFF; enabled / true / yes / on / 1 = on.
sub _conf_flag_enabled {
    my ($key) = @_;
    open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" or return 0;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\Q$key\E\s*:\s*(\S+)/;
        close $fh;
        my $v = lc $1;
        return ( $v eq 'enabled' || $v eq 'true' || $v eq 'yes' || $v eq 'on' || $v eq '1' )
            ? 1
            : 0;
    }
    close $fh;
    return 0;
}

# SM190: build the .well-known/ai-partner discovery document from the LIVE config.
# Each machine endpoint is listed only when its service killswitch is on, so the
# doc can never advertise an endpoint that would 404 (webdav_enabled / mcp_enabled
# / control_api_enabled / token_exchange_enabled). The descriptive fields (auth /
# capabilities / scope / docs) are stable and non-config-driven. Returns a hashref
# for JSON::PP to encode - always valid JSON, no template comma hazards.
sub _ai_partner_doc {
    my ($site_url) = @_;
    ( my $base = $site_url // '' ) =~ s{/+$}{};

    my $webdav   = _conf_flag_enabled('webdav_enabled');
    my $mcp      = _conf_flag_enabled('mcp_enabled');
    my $control  = _conf_flag_enabled('control_api_enabled');
    my $exchange = _conf_flag_enabled('token_exchange_enabled');

    my %endpoints;
    $endpoints{webdav}  = "$base/dav/"                            if $webdav;
    $endpoints{control} = "$base/cgi-bin/lazysite-manager-api.pl" if $control;
    $endpoints{mcp}     = "$base/cgi-bin/lazysite-mcp.pl"         if $mcp;
    if ($exchange) {
        $endpoints{exchange} = "$base/cgi-bin/lazysite-auth.pl?action=exchange";
        $endpoints{rotate}   = "$base/cgi-bin/lazysite-auth.pl?action=rotate";
    }

    my %modes;
    $modes{api} =
        'WebDAV (file ops, bulk) + control API (theme/layout/acl/config) over Basic auth; '
        . 'the full surface, best for scripted builds.'
        if $webdav || $control;
    $modes{mcp} =
        'Remote MCP server at the mcp endpoint exposing the maintenance verbs as tools; '
        . "add as a connector with bearer auth '<partner-id>:<lzs_ token>'. Best for an "
        . 'MCP-capable agent; one file per write call. tools/list is filtered to what '
        . 'the presenting credential may call: with no credential, or an account '
        . 'without the mcp capability, it lists only whoami and describe_capabilities, '
        . 'and their descriptions say why (SM714).'
        if $mcp;

    return {
        site      => $base,
        endpoints => \%endpoints,
        modes     => \%modes,

        # SM910 WK2: WHY `endpoints` IS EMPTY, WHICH IT WOULD NOT SAY.
        #
        # Reported as "two fields that were never filled", and measured: they
        # populate whenever the service is on. So the report's premise is not the
        # defect - the defect is that an empty object cannot be told apart from an
        # unfinished one. A network surface is off unless the operator enables it,
        # so an empty `endpoints` is the ordinary state of a site that publishes
        # over none of them, and a partner reading it had no way to know that.
        #
        # Stated as an explicit map, in the vocabulary `whoami` already uses for
        # the same fact (`services.mcp: false`), so the two answers about one
        # site read the same way.
        services => {
            webdav   => ( $webdav   ? JSON::PP::true() : JSON::PP::false() ),
            control  => ( $control  ? JSON::PP::true() : JSON::PP::false() ),
            mcp      => ( $mcp      ? JSON::PP::true() : JSON::PP::false() ),
            exchange => ( $exchange ? JSON::PP::true() : JSON::PP::false() ),
        },
        auth => {
            scheme       => 'basic',
            token_prefix => 'lzs_',
            note         =>
                'Basic auth: username = your partner id from your onboarding brief, password = '
                . 'the lzs_ access token. Exchange the operator-issued pairing key (lzp_) at the '
                . 'exchange endpoint for {token, expires_at}; rotate before expiry. One live '
                . 'credential per account.',
        },
        capabilities => [qw(webdav manage_themes manage_layouts manage_config analytics)],

        # SM910 WK1: WHAT THAT LIST IS, because a partner was told to confirm its
        # brief against this document and did. The list is the site's partner
        # SURFACE - the capabilities a grant here can be given - and it is not
        # anybody's grant; on the reported host it differed from the partner's
        # real grant in both directions, five of nine, and the brief was the one
        # telling the truth. A document that cannot be mistaken for a grant has to
        # say so in the document, not only in the brief that points at it.
        capabilities_note =>
            'The capabilities this site can grant a partner, not the capabilities YOU hold. '
            . 'Only whoami answers that. Comparing this list with your brief will show '
            . 'differences in both directions and means nothing.',
        scope => {
            # SM910 WK3: the capability was wrong here, and three published
            # statements disagreed about one PUT. lazysite-dav.pl:1495 gates
            # lazysite/nav.conf on manage_nav, and a partner holding manage_nav
            # and NOT manage_config wrote it (204) on the reported host. Named
            # from the code rather than from memory.
            webdav =>
                'content, assets, layout/theme files under lazysite/layouts/ (with manage_themes or manage_layouts), and lazysite/nav.conf (with manage_nav)',
            control_api =>
                'config keys, theme/layout activation, HTML-cache clear (manage_config / manage_themes / manage_layouts)',
            analytics =>
                'read-only visitor-log analysis via the analyse_visitors MCP tool - sanitised + IP-anonymised, never the raw log or a path. Off by default; explicit grant. Raw logs under lazysite/logs/ stay denied.',
            audit =>
                'read the audit trail (in-page Audit view + control-API audit action). A separate capability from analytics; off by default.',
            deny => [
                '/cgi-bin/',                     '/manager/',
                '/lazysite/auth/',               '/lazysite/forms/smtp.conf',
                '/lazysite/forms/handlers.conf', '/lazysite/forms/submissions/',
                '/lazysite/cache/',              '/lazysite/logs/',
                '/lazysite/manager/',            '/lazysite/templates/',
                '/lazysite/lazysite.conf',       '*.pl',
            ],

            # SM421: A DENY ENTRY THAT IS NOT ABSOLUTE SAYS SO.
            #
            # The submission store is listed above and WebDAV really does
            # refuse it for everyone - but MCP and the control API treat it as
            # a capability-gated carve-out, reachable to a grant holding
            # read_submissions or manage_forms. That is deliberate (it is what
            # the read_submissions capability and the read_form_submissions
            # tool are FOR), but a sysop reading a flat deny list - or
            # testing it by listing the directory, which is refused - concludes
            # the store is unreachable to partners. That conclusion is wrong,
            # and the list is what made it.
            #
            # The entry stays, because WebDAV enforces it. The qualifier sits
            # beside it so the list describes its real reachability.
            deny_notes => {
                '/lazysite/forms/submissions/' =>
                    'Withheld over WebDAV for every grant. On MCP and the '
                    . 'control API this is a capability-gated carve-out: a '
                    . 'grant holding read_submissions or manage_forms can '
                    . 'read submissions there. Listing the directory is '
                    . 'refused on every surface.',
            },
        },
        docs => [
            map { "$base/$_" } qw(
                docs/ai-briefing-building-sites docs/ai-briefing-publishing
                docs/reference docs/ai-briefing-authoring docs/ai-briefing-configuration
                docs/ai-briefing-layouts docs/ai-briefing-stats docs/ai-connector-tools llms.txt
            )
        ],
    };
}

# SM253: the content root for THIS request, for callers that run outside the
# render path. The render path publishes $REQUEST_CROOT after confining it; a 404
# can be reached before that happens, so fall back to resolving it the same way
# rather than silently using the docroot - which is the bug this fixes.
sub _request_croot {
    return $REQUEST_CROOT if defined $REQUEST_CROOT && length $REQUEST_CROOT;
    my %sv = resolve_site_vars();
    if ( defined $sv{content_root} && length $sv{content_root} ) {
        my $c = confine_content_root( $DOCROOT, $sv{content_root} );
        return $c if defined $c;
    }
    return $DOCROOT;
}

# SM355: strip the canonical an ERROR PAGE must not carry, and add the robots
# directive it must. Applied to the served body AND written back to the cache
# file, which the front end serves directly.
#
# SM371 widened it from 404 to 402 and 403. The reasoning was never
# 404-specific - an error page is not the canonical version of anything - but it
# was only ever CALLED from not_found(). serve_402 and serve_403 render through
# process_md into $DOCROOT/402.html and 403.html, files the front end then
# serves at 200, and kept whatever canonical the layout emitted.
#
# The 402 case is the worse of the two: a canonical on a payment-required page
# points at content the visitor was just refused, and the field report found one
# carrying an arbitrary ?v= query into the bargain.
#
# Idempotent by construction - it removes a tag and adds one that is only added
# when absent - so it runs on every 404 without accumulating anything.
sub _sanitise_not_found {
    my ($html) = @_;
    return $html unless defined $html && length $html;

    # A 404 has no canonical URL. Not "the requested path" either: that would
    # assert a missing page is the canonical version of itself.
    $html =~ s{\n?\s*<link\s+rel=["']canonical["'][^>]*>}{}gi;

    unless ( $html =~ /<meta\s+name=["']robots["']/i ) {
        $html =~ s{(<head[^>]*>)}{$1\n    <meta name="robots" content="noindex">}i;
    }
    return $html;
}

# Write only when the content actually differs. A 404 is the most-requested
# response on a site under scan, and rewriting the file on every one of them
# would turn a cache into a write amplifier.
sub _rewrite_if_changed {
    my ( $path, $content ) = @_;
    return if _draft_requested();    # SM1030: a draft render writes nothing
    my $current = eval { read_file($path) };
    return if defined $current && $current eq $content;

    # SM381: THE CHECKED WRITE THE MAIN CACHE WRITER DOCUMENTS 300 LINES ABOVE.
    #
    # This is the writer for the cached 404/402/403 files and it checked neither
    # print nor close before renaming into place - the SM020 torn-page defect
    # that writer guards against, in the same file, on the response most likely
    # to be reached by a scanner. A disk-full mid-write renamed a TRUNCATED
    # error page into place, and it was then served from cache.
    #
    # It also omitted _cache_umask(), so a rewritten error page landed
    # non-group-writable in the mixed www-data/site-user case and the other
    # identity could not manage it afterwards.
    my $old_umask = _cache_umask();
    my $tmp       = "$path.tmp.$$";
    open my $fh, '>:utf8', $tmp or do {
        umask $old_umask;
        return;
    };
    my $wrote = print {$fh} $content;
    umask $old_umask;
    unless ( close($fh) && $wrote ) {
        unlink $tmp;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'error page write failed; keeping the previous cache',
            path => $path );
        return;
    }
    rename $tmp, $path or unlink $tmp;
    return;
}

sub not_found {
    my ($uri) = @_;
    $ACCESS_REC{s} //= 404;    # SM140

    # SM253: resolve through the DOMAIN's content root. _system_page_md has
    # always taken a content root and this call site never gave it one, so the
    # first of its three tiers collapsed into the second and a secondary domain
    # served the primary's 404 - the primary's branding and navigation shown to a
    # visitor who mistyped a URL on someone else's site. The cache slot has to
    # move with it, or one domain's rendered 404 is served to another.
    my $croot     = _request_croot();
    my $md_path   = _system_page_md( '404', $croot ) // "$DOCROOT/404.md";
    my $html_path = "$croot/404.html";

    if ( -f $md_path ) {
        my $page = is_fresh( $html_path, $md_path )
            ? read_file($html_path)
            : process_md( $md_path, $html_path );

        # SM355: A MISSING PAGE HAS NO CANONICAL URL, and this one was claiming
        # somebody else's.
        #
        # The rendered 404 is cached as a FILE, and the render injects a
        # canonical derived from the request being served at that moment
        # (_inject_canonical reads REDIRECT_URL). So the FIRST request to any
        # missing URL baked its own path into the file every later 404 is served
        # from. Measured in the field: every 404 on the instrument declared
        # `/feed.xml` as its canonical, because a request for /feed.xml happened
        # to be the first one to miss.
        #
        # That is remotely influenceable. An anonymous visitor who is first to
        # request a missing URL after a cache clear chooses what every 404 on
        # the site canonicalises to. Same-origin, so it cannot point elsewhere -
        # but every missing page then tells crawlers the real page is a URL a
        # stranger picked.
        #
        # And the cached file lives in the SERVED tree, so the front end answers
        # /404.html directly with 200 - an indexable soft 404 carrying that same
        # canonical. Hence noindex: it is the only part of this that reaches a
        # response the engine never sees.
        $page = _sanitise_not_found($page);

        # Keep the cache honest too. The file is what the front end serves at
        # /404.html without ever consulting us, so cleaning only the response
        # would fix the path we control and leave the one we do not.
        _rewrite_if_changed( $html_path, $page )
            if -f $html_path;
        # SM253: through output_page, so a 404 carries the same baseline security
        # headers as every other response. It used to print its own status line
        # and content type, which made the one response most likely to be reached
        # by a scanner or a crawler the only one served without them - and left
        # $ACCESS_REC{b} unset, so the analytics record had no byte count.
        return output_page( $page, 'text/html; charset=utf-8', undef, 0,
            '404 Not Found' );
    }

    # Bare fallback if no 404.md exists yet. chrome_string HTML-escapes $uri (it
    # was interpolated raw before - a reflected-markup vector on the 404 path).
    return output_page( '<p>' . _chrome( 'notfound.body', $uri ) . "</p>\n",
        'text/html; charset=utf-8', undef, 0, '404 Not Found' );
}

1;

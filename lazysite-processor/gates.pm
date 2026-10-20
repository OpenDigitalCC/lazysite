package main;

# lazysite-processor/gates.pm - the processor's payment, preview and maintenance gates.
#
# HOLDS   _maintenance_gate($uri) (SM1118): a site in maintenance (the
#         `maintenance` switch, per domain or for the instance) sends a page
#         request to its maintenance page - a 302, no-store - unless the request's
#         verified identity holds `maintenance_access`; the page itself, the
#         sign-in pages and their assets stay reachable, and the maintenance page
#         answers 503 with Retry-After (output_page reads %MAINT). A request that
#         is not a GET or HEAD is refused 503, not redirected. Lazysite::Maintenance
#         is the decision, loaded only when lazysite.conf carries the key.
#         peek_payment($path), check_payment($uri, $meta, $auth, $vars) and
#         serve_402($result): a page whose front matter says `payment: required`
#         is served 402 with an x402 X-Payment-Response unless the caller is in
#         a bypass group or the front end set the verified header; the SM071
#         preview cookie: check_preview() verifies lzs_preview (HMAC under the
#         auth secret, unexpired, a well-formed layout/theme) with
#         read_request_cookie, load_preview_secret and preview_const_eq.
# OWNS    the 402 response; what a valid preview cookie overrides.
# CALLS   _peek_md, _request_croot, _system_page_md, process_md,
#         _sanitise_not_found, _rewrite_if_changed, output_page
#         (lazysite-processor.pl); encode_json, hmac_sha256_hex (imported by
#         the script's `use`).
# READS   $DOCROOT, %PAYMENT_CONTEXT, $PREVIEW_COOKIE, $LAZYSITE_DIR (the
#         script's, declared `our` there; %PAYMENT_CONTEXT and %PREVIEW_CONTEXT
#         stay declared in the script's Payment section, which main() and
#         render_content() read).
#
# Both gates run from main() AFTER the auth gate (t/integration/52 holds the
# order for the preview): a preview cookie changes how a page renders, never
# who may read it.
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S7). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $CONF_FILE, $PREVIEW_COOKIE, %PAYMENT_CONTEXT, %MAINT, %ACCESS_REC );

# SM1118 (ruled 2026-10-20, #338): the maintenance gate. See the header.
#
# WHY HERE. Every way a page request reaches the engine ends in main(): the plain
# CGI behind the auth wrapper, the split FastCGI templates (a signed-in request
# through the wrapper, an anonymous one straight to this program) and the one-rule
# pool (the worker's held identity). The identity this asks is the one reader
# every other gate asks, so the check holds on all three without a copy in each
# front end. Returns 1 when the request has been answered.
sub _maintenance_gate {
    my ($uri) = @_;
    my %sv    = resolve_site_vars();
    my $sw    = $sv{maintenance};
    return 0 if !defined $sw || $sw =~ /\A\s*(?:off|disabled|false|no|0)\s*\z/i;

    _lazy_lib('Lazysite::Maintenance');
    my $st = Lazysite::Maintenance::status(
        conf_text => ( -f $CONF_FILE ? read_file($CONF_FILE) : '' ),
        host      => _request_host() );
    return 0 unless $st->{on};
    %MAINT = ( on => 1, state => $st );

    # Who gets through: the verified identity, and only the capability.
    my $ident = _request_identity( conf => \%sv );
    if ( length( $ident->{user} // '' )
        && _groups_grant_cap( 'maintenance_access', _cap_groups( @{ $ident->{groups} || [] } ) ) )
    {
        $MAINT{holder} = 1;
        return 0;
    }

    ( my $path = $uri // '/' ) =~ s/\?.*\z//s;
    if ( Lazysite::Maintenance::exempt( $path, $st, $sv{auth_redirect} ) ) {
        $MAINT{page} = 1 if Lazysite::Maintenance::is_page( $path, $st );
        return 0;
    }

    my $method = uc( $ENV{REQUEST_METHOD} // 'GET' );
    my $retry  = Lazysite::Maintenance::retry_after($st);
    if ( $method ne 'GET' && $method ne 'HEAD' ) {
        $ACCESS_REC{s} = 503;
        output_page( Lazysite::Maintenance::message($st) . "\n",
            'text/plain; charset=utf-8', undef, 1, '503 Service Unavailable',
            ["Retry-After: $retry"] );
        return 1;
    }

    my $page = $st->{page};
    my $to = $page . ( index( $page, '?' ) >= 0 ? '&' : '?' ) . 'from=' . uri_encode($path);
    $ACCESS_REC{s} = 302;
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "$_\r\n" for _security_headers();
    print "Content-Type: text/html; charset=utf-8\r\n";
    print "Cache-Control: no-store\r\n";
    print "Location: $to\r\n\r\n";
    return 1;
}

sub peek_payment {
    my ($path) = @_;
    my $m = _peek_md($path);
    my %out;
    for my $k ( qw(payment payment_amount payment_currency
        payment_network payment_address
        payment_asset payment_description) ) {
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
        amount           => $payment_meta->{payment_amount}      // '0',
        currency         => $payment_meta->{payment_currency}    // 'USD',
        network          => $payment_meta->{payment_network}     // 'base',
        address          => $payment_meta->{payment_address}     // '',
        asset            => $payment_meta->{payment_asset}       // '',
        description      => $payment_meta->{payment_description} // '',
    };
}

sub serve_402 {
    my ($payment_result) = @_;

    # Build x402 payment response header
    # Assumption: amount is in human-readable decimal (e.g. 0.01 USD)
    # Convert to smallest unit assuming USDC (6 decimals)
    my $amount_raw = int( ( $payment_result->{amount} // 0 ) * 1_000_000 );
    my $network    = $payment_result->{network} || 'base';
    my $address    = $payment_result->{address} || '';
    my $asset      = $payment_result->{asset}   || '';

    my $x_payment = encode_json( {
            version => '1.0',
            accepts => [ {
                    scheme            => 'exact',
                    network           => $network,
                    maxAmountRequired => "$amount_raw",
                    to                => $address,
                    asset             => $asset,
                    extra             => {
                        name    => $payment_result->{currency} || 'USDC',
                        version => '1',
                    },
            } ],
    } );

    binmode( STDOUT, ':utf8' );

    # SM381: the domain's content root, as SM253 did for the 404. Called with no
    # root, the first of _system_page_md's three tiers collapsed into the second
    # and a secondary domain rendered its 402 into the PRIMARY's docroot.
    my $croot   = _request_croot();
    my $md_path = _system_page_md( '402', $croot ) // "$DOCROOT/402.md";    # SM201
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
        my $html_path = "$croot/402.html";
        my $page      = process_md( $md_path, $html_path, ( stat($md_path) )[9], {} );

        # SM371: the worse of the two. A canonical here points at content the
        # visitor was just REFUSED - the field report found one aimed at a
        # payment-gated page, carrying an arbitrary ?v= query picked up from
        # somebody's cache-buster. Whatever put the query there, the tag has no
        # business on this page at all.
        $page = _sanitise_not_found($page);
        _rewrite_if_changed( $html_path, $page ) if -f $html_path;

        # SM381: through output_page, so the baseline header set reaches the
        # response a payment-gated visitor actually receives.
        return output_page( $page, 'text/html; charset=utf-8', undef, 1,
            '402 Payment Required', ["X-Payment-Response: $x_payment"] );
    }

    my $body
        = '<!DOCTYPE html><html><head><title>Payment Required</title></head><body>'
        . '<h1>Payment Required</h1>'
        . '<p>This content requires payment of '
        . ( ( $payment_result->{amount} // '0' ) . ' '
            . ( $payment_result->{currency} // 'USD' ) )
        . '.</p></body></html>';
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '402 Payment Required', ["X-Payment-Response: $x_payment"] );
}

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

1;

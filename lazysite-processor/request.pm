package main;

# lazysite-processor/request.pm - who is asking, and on which host.
#
# HOLDS   _request_host(): the request's Host header sanitised to the DNS
#         alphabet (SM110; the copy t/lint/203 pins to Lazysite::Util);
#         _request_address($spec): the visitor's address, walking
#         X-Forwarded-For from the right only through trusted proxies (SM929),
#         with _trusted_proxy_spec (the conf reader that tells an empty
#         `trusted_proxies:` from an absent one), _trusted_proxy_default,
#         _parse_trusted_proxies, _packed_address, _text_address and
#         _address_in_set (the copies t/lint/205 pins line for line);
#         _instance_id(), the SM156 per-install identifier, which sits among
#         them.
# OWNS    the request's identity facts: its host and its address.
# CALLS   realpath, hmac_sha256_hex, inet_pton, inet_ntop and the Socket
#         AF_INET/AF_INET6 constants (imported by the script's `use`, before its
#         parts load; the constants written as calls, so the part compiles alone).
# READS   $DOCROOT, $CONF_FILE (the script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S13). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $CONF_FILE );

# SM110: the request's Host header, sanitised for alias matching: lowercased,
# port stripped, trailing dot dropped, validated against the DNS hostname
# alphabet. Anything malformed returns '' and the request renders with the
# base conf, exactly like the primary host. Note HTTP_HOST stays EXCLUDED
# from ${VAR} conf interpolation (%ENV_ALLOWLIST) - here its sanitised value
# is only COMPARED against the operator-declared alias list, never emitted
# into output, so a hostile Host header can at worst select a rendering the
# operator explicitly configured.
# SM156: a stable, non-sensitive per-install identifier. One-way over the
# realpath of the docroot, so every host of the same install returns the same
# value and two installs on one server differ. Not derived from any secret, so
# publishing it via the instance marker leaks nothing usable. manager-api
# computes the identical value (same docroot) to compare a check result against.
sub _instance_id {
    my $base = realpath($DOCROOT) // $DOCROOT;
    return substr( hmac_sha256_hex( $base, 'lazysite-instance' ), 0, 32 );
}

sub _request_host {
    my $host = lc( $ENV{HTTP_HOST} // q{} );
    $host =~ s/:\d+\z//;    # strip port
    $host =~ s/\.\z//;      # trailing dot (FQDN form)
    return q{} if length $host > 253;
    return q{}
        unless $host =~ /\A [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )?
                         (?: \. [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )? )* \z/x;
    return $host;
}

# SM929: ONE DEFINITION OF THE REQUEST ADDRESS - the render path's PINNED COPY.
#
# ADR 0001 keeps this file module-free, so it cannot call Lazysite::Util's and
# carries its own. That is the same trade t/lint/198 makes for `_cannot_read`, 202
# for the env allowlist and 203 for the request host, and t/lint/205 is the brake:
# the four subs below must say the same thing as the module's, line for line.
#
# WHY THE RENDER PATH NEEDS IT AT ALL. `client_ip` took the FIRST hop of
# X-Forwarded-For whenever the header was present, with no trust check - measured
# forgeable on a live site 2026-10-01, where `X-Forwarded-For: 203.0.113.7` made
# the page say 203.0.113.7. The reasoning for the rightmost-hop walk and for
# refusing a zero-length prefix is written once, in Lazysite::Util.
#
# The spec READER is deliberately NOT shared with resolve_site_vars: its
# `^(\w+)\h*:\h*(.+)$` needs a value after the colon, so it cannot tell an EMPTY
# `trusted_proxies:` (trust nothing) from an absent one (the default). Those are
# different states and t/unit/processor/84 holds the two readers to the same four.
sub _trusted_proxy_spec {
    return undef unless -f $CONF_FILE;
    open my $fh, '<:utf8', $CONF_FILE or return undef;
    my $spec;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^trusted_proxies\s*:\s*(.*?)\s*$/;
        $spec = $1;
        last;
    }
    close $fh;
    return $spec;
}

sub _trusted_proxy_default {
    # A SUB, NOT A PACKAGE ARRAY: in the processor a file-scoped `our` below the
    # main body is EMPTY when a request is served (t/lint/39 names exactly this),
    # which would have left the render path trusting nothing and silently reading
    # the peer. A sub is initialised at call time and cannot be too early.
    return ( '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' );
}

sub _parse_trusted_proxies {
    my ($spec) = @_;
    $spec = '' unless defined $spec;
    $spec =~ s/\A\s+//;
    $spec =~ s/\s+\z//;
    my @words;
    # ABSENT AND EMPTY ARE THE SAME ANSWER, deliberately, and `none` is how an
    # operator says no. The Config page ships this field EMPTY and pressing Save
    # writes an empty value - SM782 names the same shape for backup_retention - so
    # reading empty as "trust nothing" would turn the feature off for any site
    # whose operator merely saved the page, silently, and put the proxy's address
    # back on every submission.
    if    ( !length $spec )       { @words = _trusted_proxy_default() }
    elsif ( lc($spec) eq 'none' ) { return ( [], [] ) }
    else                          { @words = split /[\s,]+/, $spec }
    my ( @set, @rejected );
    for my $w (@words) {
        my ( $addr, $bits ) = split m{/}, $w, 2;
        my $packed = _packed_address( $addr // '' );
        if ( !length $packed ) { push @rejected, $w; next }
        my $width = length($packed) * 8;
        $bits = $width if !defined $bits || !length $bits;
        if ( $bits !~ /\A[0-9]+\z/ || $bits + 0 > $width || $bits + 0 == 0 ) {
            push @rejected, $w;
            next;
        }
        push @set, [ $packed, $bits + 0 ];
    }
    return ( \@set, \@rejected );
}

sub _packed_address {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    return '' if $text =~ /[^0-9A-Fa-f:.]/;
    my $family = ( index( $text, ':' ) >= 0 ) ? AF_INET6() : AF_INET();
    my $packed = eval { inet_pton( $family, $text ) };
    return ( defined $packed && length $packed ) ? $packed : '';
}

sub _text_address {
    my ($packed) = @_;
    my $family   = length($packed) == 4 ? AF_INET() : AF_INET6();
    my $text     = eval { inet_ntop( $family, $packed ) };
    return defined $text ? $text : '';
}

sub _address_in_set {
    my ( $packed, $set ) = @_;
    return 0 unless defined $packed && length $packed;
    for my $entry ( @{$set} ) {
        my ( $net, $bits ) = @{$entry};
        next unless length($net) == length($packed);
        my $whole = int( $bits / 8 );
        my $rest  = $bits % 8;
        next if $whole && substr( $packed, 0, $whole ) ne substr( $net, 0, $whole );
        if ($rest) {
            my $mask = 0xFF & ( 0xFF << ( 8 - $rest ) );
            next
                if ( ord( substr $packed, $whole, 1 ) & $mask )
                != ( ord( substr $net, $whole, 1 ) & $mask );
        }
        return 1;
    }
    return 0;
}

sub _request_address {
    my ($spec) = @_;
    my $peer   = $ENV{REMOTE_ADDR} // '';
    my ($set)  = _parse_trusted_proxies($spec);
    return $peer unless @{$set};
    return $peer unless _address_in_set( _packed_address($peer), $set );
    my @chain = split /,/, ( $ENV{HTTP_X_FORWARDED_FOR} // '' );
    for my $hop ( reverse @chain ) {
        $hop =~ s/\A\s+//;
        $hop =~ s/\s+\z//;
        my $packed = _packed_address($hop);
        return $peer                  unless length $packed;
        return _text_address($packed) unless _address_in_set( $packed, $set );
    }
    return $peer;
}

1;

package main;

# lazysite-processor/remap.pm - the processor's URL remapper and alias lookup.
#
# HOLDS   _remap_redirect(): answers a request a remap rule matches with its 301
#         or 302 and returns 1, else 0; _remap_parse($text), the marked copy of
#         Lazysite::Remap's parser (t/lint/129 holds the two to one meaning);
#         _alias_lookup(): [canonical URL, code] for the requested path from the
#         served site's aliases map, or undef.
# OWNS    which requests the remap rules and the alias map redirect, and where.
# CALLS   _unit_enabled, _request_host, _esc_html, _security_headers,
#         resolve_site_vars, log_event (lazysite-processor.pl); decode_json
#         (JSON::PP, imported into main by the script before its parts load).
# READS   $LAZYSITE_DIR; WRITES %ACCESS_REC (the script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S4). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $LAZYSITE_DIR, %ACCESS_REC );

# --- SM802: the URL remapper, on the render path --------------------------------
# A MARKED COPY of Lazysite::Remap::parse_rules and match_rule, by the ADR 0001
# convention for this module-free file. t/lint/129 runs both parsers over the
# same text and fails if they accept different rules - the point being that the
# rules a save accepted are exactly the rules a request honours.
#
# The destination comes from lazysite/remap/rules.conf and NEVER from the request.
sub _remap_parse {
    my ($text) = @_;
    my ( @rules, %seen );
    for my $raw ( split /\r?\n/, ( $text // '' ) ) {
        ( my $l = $raw ) =~ s/#.*\z//;
        $l =~ s/^\s+|\s+$//g;
        next unless length $l;
        my @f = split /\s+/, $l;
        next if @f < 3 || @f > 4;
        my ( $host, $prefix, $dest, $code ) = @f;
        $host = lc $host;
        $code //= 302;
        next unless $host =~ /\A [a-z0-9] (?:[a-z0-9-]*[a-z0-9])? (?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)* \z/x;
        next unless $prefix =~ m{\A/};
        next if $prefix =~ /[\s?#"'<>\\]/ || $prefix =~ m{(?:\A|/)\.\.(?:/|\z)} || $prefix =~ m{//};
        next if $dest =~ /[\s"'<>\\]/;
        next unless $dest =~ m{\Ahttps?://[A-Za-z0-9.-]+(?::\d{1,5})?(?:[/?].*)?\z}
            || $dest =~ m{\A/(?!/)};
        next unless $code =~ /\A30[12]\z/;
        $prefix =~ s{(?<=.)/\z}{};
        next if $seen{"$host $prefix"}++;
        push @rules, { host => $host, prefix => $prefix, dest => $dest, code => $code + 0 };
    }
    return \@rules;
}

sub _remap_redirect {
    return 0 unless _unit_enabled('plugins/remap.pl');
    my $file = "$LAZYSITE_DIR/remap/rules.conf";
    return 0 unless -f $file;
    open my $fh, '<:utf8', $file or return 0;
    my $text = do { local $/; <$fh> };
    close $fh;
    my $rules = _remap_parse($text);
    return 0 unless @$rules;

    my $host = _request_host();
    return 0 unless length $host;
    ( my $path = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '' ) =~ s/\?.*//s;
    return 0 unless length $path;

    for my $r (@$rules) {
        next unless $r->{host} eq $host;
        my $p = $r->{prefix};
        my $rest;
        if    ( $p eq '/' )                  { $rest = $path }
        elsif ( $path eq $p )                { $rest = '' }
        elsif ( index( $path, "$p/" ) == 0 ) { $rest = substr( $path, length $p ) }
        else                                 { next }

        ( my $base = $r->{dest} ) =~ s{/\z}{};
        my ( $dpath, $dq ) = split /\?/, $base, 2;
        my $loc = $dpath . $rest;
        my @q   = grep { defined && length } ( $dq, $ENV{QUERY_STRING} );
        $loc .= '?' . join( '&', @q ) if @q;
        $loc =~ s/[\r\n]//g;

        # Recorded, with the rule named, because the counts and the last-used
        # date are DERIVED from this log (ruled 2026-09-09) - one source, no
        # second store, and no extra write on the request path.
        $ACCESS_REC{s}  = $r->{code};
        $ACCESS_REC{rr} = $p;
        log_event( 'INFO', $path, 'remap redirect', host => $host, to => $loc,
            code => $r->{code} );

        my $phrase = $r->{code} == 301 ? 'Moved Permanently' : 'Found';
        my $loc_h  = _esc_html($loc);
        print "Status: $r->{code} $phrase\r\n";
        print "$_\r\n" for _security_headers();
        print "Location: $loc\r\n";
        print "Content-Type: text/html; charset=utf-8\r\n\r\n";
        print qq(<!DOCTYPE html><html><body>Moved to <a href="$loc_h">$loc_h</a></body></html>\n);
        return 1;
    }
    return 0;
}

# Inline alias lookup for the 404 path: read lazysite/aliases.json and return
# [canonical URL, redirect code] for the requested path, or undef. Kept inline (no
# module load on the miss path); the map is written by Lazysite::Aliases on
# save/delete/move/copy. Schema (keep in sync with Lazysite::Aliases): a plain
# string value is a 301 target (the 0.6.1 format); { target, code } carries a 302.
# Anything else, or an unknown code, reads as 301.
sub _alias_lookup {
    # SM440: read the map belonging to the site being SERVED, not the
    # instance's. One shared map meant an alias declared by one domain
    # answered on every other - field-confirmed: a content-root site's
    # /thesis 301'd and SERVED that site's page under a neighbour's domain,
    # 200, at a URL the neighbour never defined.
    #
    # The docroot keeps the original path, so a single-site instance and the
    # primary read exactly the file they always did.
    my %sv = resolve_site_vars();
    my $f  = "$LAZYSITE_DIR/aliases.json";
    if ( defined $sv{content_root} && length $sv{content_root} ) {
        ( my $key = $sv{content_root} ) =~ s{^/+|/+$}{}g;
        $key =~ s{[^A-Za-z0-9._-]+}{_}g;
        $f = "$LAZYSITE_DIR/aliases/$key.json" if length $key;
    }
    return undef unless -f $f;
    my $req = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '';
    $req =~ s/\?.*\z//;                      # drop any query string
    return undef unless length $req && $req =~ m{^/};
    $req =~ s{/+\z}{} unless $req eq '/';    # normalise trailing slash
    open my $fh, '<', $f or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $map = eval { decode_json( $raw // '{}' ) };
    return undef unless ref $map eq 'HASH';
    my $entry = $map->{$req};
    my ( $canon, $code ) =
        ref $entry eq 'HASH' ? ( $entry->{target}, $entry->{code} ) : ( $entry, 301 );
    $code = ( defined $code && $code =~ /\A302\z/ ) ? 302 : 301;
    # The target is our own canonical URL; still refuse anything not a clean
    # site-local path (defence in depth against a hand-edited map).
    return undef unless defined $canon && $canon =~ m{^/} && $canon !~ m{^//};
    return undef if $canon =~ /[\0\r\n]/;
    return [ $canon, $code ];
}

1;

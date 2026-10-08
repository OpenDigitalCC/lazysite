package main;

# lazysite-processor/access-log.pm - the processor's access log and unit registry.
#
# HOLDS   _access_record(): the SM140 first-party access log, one anonymised JSON
#         line per request in lazysite/logs/access-YYYYMMDD.jsonl from what the
#         emitters left in %ACCESS_REC, with _access_conf (stats.conf),
#         _visitor_key (a daily-salted keyed hash, never the address),
#         _access_salt, _access_field and _access_prune (retention);
#         _unit_enabled($entry) and _reset_units(): the SM222 L0 marked copy of
#         the `plugins:` registry read, memoised per request in a bare block.
# OWNS    what a request leaves in the access log; whether a unit is listed.
# CALLS   _request_address, _trusted_proxy_spec, _request_host, _cannot_read,
#         _json_str, log_event (lazysite-processor.pl); make_path,
#         hmac_sha256_hex and the Fcntl O_* constants (imported by the script's
#         `use`, before its parts load).
# READS   $LAZYSITE_DIR, %ACCESS_REC (the script's, declared `our` there).
#
# THE ONE FILE-SCOPE STATE HERE is `my $_UNITS;` in _unit_enabled's bare block.
# It has no initialiser: the block's statement runs inside the loader's BEGIN,
# where in the script it ran after the request, and neither run assigns the
# variable the two subs closed over at compile time, so it is undef until the
# first lookup either way. An initialiser added there would run before any
# request (and before the script's own state is set); keep it a sub's job.
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S8). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $LAZYSITE_DIR, %ACCESS_REC );

# --- SM140: first-party access log -------------------------------------------
# The processor records its own traffic - one JSON line per request under
# lazysite/logs/access-YYYYMMDD.jsonl - so visitor analytics need no access to
# the web server's logs (which are root-owned on panel hosts and undercount
# behind an nginx front). ALWAYS anonymised at write: the visitor key is a
# daily-salted keyed hash, never the IP. Emitters fill %ACCESS_REC; the main
# wrapper records once per request. Module-free per ADR 0001; stats.pl
# aggregates the files.

# --- SM222 L0: the unit registry, read from the render path -------------------
# `plugins:` in lazysite.conf IS the registry, and until now nothing on the
# request path read it. Enablement was consulted at fourteen sites in nine files
# across the manager tree and at ZERO sites here, so a unit switched off in the
# manager went on doing its work inside an ordinary page render. Truly-off has to
# hold where the work happens, and for an embedded unit that is here.
#
# A MARKED COPY, by the convention ADR 0001 sets for the capability gate: this
# render path is deliberately module-free, so it cannot call
# Lazysite::Manager::Plugins::plugin_enabled. What is copied is a five-line list
# scan rather than a semantic, which is the cheapest kind of copy to keep honest,
# and t/lint/125 asserts the two readers agree on the same conf rather than
# trusting this comment.
#
# Memoised per request and cleared by handle_one_request: an FCGI worker serves
# many requests and must not answer from a map read before the operator's toggle.
{
    my $_UNITS;

    sub _unit_enabled {
        my ($entry) = @_;
        if ( !$_UNITS ) {
            $_UNITS = {};
            if ( open my $fh, '<:utf8', "$LAZYSITE_DIR/lazysite.conf" ) {
                my $in_plugins = 0;
                while ( my $l = <$fh> ) {
                    chomp $l;
                    # SM817: both spellings open the one registry.
                    if ( $l =~ /^(?:extensions|plugins)\s*:\s*$/ ) {
                        $in_plugins = 1;
                        next;
                    }
                    if ( $in_plugins && $l =~ /^\s+-\s+(.+?)\s*$/ ) {
                        $_UNITS->{$1} = 1;
                        next;
                    }
                    $in_plugins = 0 if $in_plugins && $l !~ /^\s/;
                }
                close $fh;
            }
        }
        return $_UNITS->{$entry} ? 1 : 0;
    }

    sub _reset_units { $_UNITS = undef; return }
}

# stats.conf knobs the recorder honours (shared with the stats plugin).
sub _access_conf {
    my %c = ( first_party => 1, retention_days => 90 );
    if ( open my $fh, '<', "$LAZYSITE_DIR/stats.conf" ) {
        while ( my $l = <$fh> ) {
            $c{first_party}    = 0      if $l =~ /^first_party\s*:\s*(?:off|false|0)\b/i;
            $c{retention_days} = $1 + 0 if $l =~ /^retention_days\s*:\s*(\d+)/;
        }
        close $fh;
    }
    $c{retention_days} = 90 if $c{retention_days} < 1;
    return \%c;
}

# Daily-salted visitor key: same visitor+day -> same key (distinct daily
# visitors), never reversible to the IP (keyed on the site secret). On an
# auth-less site there is no .secret, and an unkeyed hash of ymd|ip would be
# IPv4-brute-forceable (2026-07-10 review, D6) - mint a dedicated salt once
# and key on that instead.
sub _visitor_key {
    my ($ymd) = @_;
    # SM929: the VISITOR, not the proxy. Keyed on REMOTE_ADDR, every visitor behind
    # a front proxy hashed to one key per day, so "distinct daily visitors" counted
    # the proxy once however many people called.
    my $ip = _request_address( _trusted_proxy_spec() );
    return '' unless length $ip;
    my $secret = '';
    # SM917: the fallback below is BY DESIGN for a site with no secret, and was
    # also what happened when the secret existed and could not be read - so an
    # unreadable secret silently re-keyed every visitor token. Nothing failed and
    # nothing was logged; the only symptom is that returning visitors start
    # counting as new ones, which looks like traffic rather than a fault.
    #
    # Absent still falls through silently, because that IS the secret-less site
    # this fallback was written for. Unreadable now says so.
    if ( open my $sf, '<', "$LAZYSITE_DIR/auth/.secret" ) {
        local $/;
        $secret = <$sf> // '';
        close $sf;
    }
    else { _cannot_read( 'the auth secret', "$LAZYSITE_DIR/auth/.secret" ) }
    $secret = _access_salt() unless length $secret;
    return substr( hmac_sha256_hex( "$ymd|$ip", $secret ), 0, 16 );
}

# Persistent random salt for the visitor key on secret-less sites. Minted
# once under logs/ (the recorder's own directory); losing it only re-keys
# the visitor tokens - it can never identify anyone.
sub _access_salt {
    my $path = "$LAZYSITE_DIR/logs/.access-salt";
    if ( open my $fh, '<', $path ) {
        local $/;
        my $s = <$fh> // '';
        close $fh;
        return $s if length $s;
    }
    my $salt = hmac_sha256_hex( join( '|', time, $$, rand, rand ), $LAZYSITE_DIR );
    if ( sysopen( my $fh, $path, O_WRONLY() | O_CREAT(), 0660 ) ) {
        # sysopen's mode is umask-filtered - re-assert 0660 so BOTH identities
        # (site-user CLI/dev-server and the www-data CGI) can rewrite it.
        chmod 0660, $path;
        syswrite( $fh, $salt );
        close $fh;
    }
    return $salt;
}

# Attacker-controlled field -> safe JSON string content (control chars
# stripped against log injection, length-capped, JSON-escaped).
sub _access_field {
    my ( $s, $cap ) = @_;
    $s //= '';
    $s =~ s/[\x00-\x1f\x7f]//g;
    $s = substr( $s, 0, $cap ) if length($s) > $cap;
    return _json_str($s);
}

# Record the request outcome. No-op when no emitter ran (redirects), when the
# stats unit is switched off (SM222 L0), when first_party: off, or on any
# internal failure - recording must never break serving. One O_APPEND write; lines are far below PIPE_BUF, so concurrent
# CGI appends cannot interleave.
sub _access_record {
    return unless defined $ACCESS_REC{s};
    my $ok = eval {
        # SM222 L0: DELIBERATELY NOT GATED ON THE REGISTRY YET, and the reason
        # is a ruling rather than an oversight.
        #
        # `_unit_enabled` exists below and reads `plugins:` correctly. Gating
        # here was built, tested and reverted, because plugins/stats.pl declares
        # no `contract` key and is therefore a LEGACY descriptor. SM409 / ADR
        # 0009 carry the release manager's ruling for those: a legacy plugin
        # keeps running exactly as it always has until its own migration SM
        # enables it explicitly to replicate its current effective state, so
        # that nothing in the field changes behaviour on upgrade. Gating on the
        # list stops recording for every site that never listed stats - which is
        # every site that never had a reason to.
        #
        # AND ABSENCE IS NOT A DECISION. `plugins:` can say a unit is ON by
        # listing it; it has no way to say a unit is OFF. So "absent" means both
        # "the operator switched it off" and "nobody has ever been asked", and
        # nothing here can tell those apart. Truly-off for a legacy unit needs
        # the migration to exist first; it is not reachable by reading harder.
        #
        # first_party remains the switch that works today, and it is this
        # design's RUNTIME axis under another name: the unit offered, not
        # currently recording.
        my $conf = _access_conf();
        return 1 unless $conf->{first_party};
        my @t   = gmtime;
        my $ymd = sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3];
        my $dir = "$LAZYSITE_DIR/logs";
        eval { make_path($dir) } unless -d $dir;
        my $file   = "$dir/access-$ymd.jsonl";
        my $is_new = !-e $file;
        ( my $path = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '' ) =~ s/\?.*//s;
        my $line = '{"t":' . time()
            . ',"p":"' . _access_field( $path, 200 ) . '"'
            . ',"s":' .   ( $ACCESS_REC{s} + 0 )
            . ',"ch":"' . ( $ACCESS_REC{ch} // 'page' ) . '"'
            . ',"v":"' . _visitor_key($ymd) . '"'
            . ',"ua":"' . _access_field( $ENV{HTTP_USER_AGENT}, 160 ) . '"';
        my $ref = $ENV{HTTP_REFERER} // '';
        $line .= ',"r":"' . _access_field( $ref, 200 ) . '"' if length $ref;
        $line .= ',"c":1'                                    if $ACCESS_REC{c};
        # SM223: this request was refused by an ACCESS decision rather than by
        # being missing or broken. Recorded as its own flag because the status
        # alone cannot carry it: the anonymous refusal is a 302 to the login
        # page, indistinguishable in the log from every other redirect.
        #
        # This is the upgrade safeguard the operator asked for. Extending the
        # ACL's `read` list to the public path means an entry written to keep
        # other EDITORS out now also refuses anonymous visitors, and a public
        # asset can go dark without anyone being told. A per-path refusal report
        # makes that visible whenever it happens, rather than only to sysops
        # who read one particular release's notes in one particular week.
        $line .= ',"ar":1' if $ACCESS_REC{ar};
        # SM802: the remap rule that answered, so its count is derived here.
        $line .= ',"rr":"' . _access_field( $ACCESS_REC{rr}, 200 ) . '"'
            if defined $ACCESS_REC{rr};
        $line .= ',"b":' . ( $ACCESS_REC{b} + 0 ) if defined $ACCESS_REC{b};
        # SM151: the sanitised request Host, so multi-site (many domains under
        # one docroot) can split visitor stats per domain later. DNS-shaped and
        # capped; empty (primary / malformed Host) is simply omitted.
        my $host = _request_host();
        $line .= ',"h":"' . _access_field( $host, 253 ) . '"' if length $host;
        $line .= "}\n";
        sysopen( my $fh, $file, O_WRONLY() | O_APPEND() | O_CREAT(), 0664 )
            or return 1;    # silent: lazysite-check owns the writability story
        binmode $fh;
        syswrite( $fh, $line );
        close $fh;
        _access_prune( $dir, $conf->{retention_days} ) if $is_new;
        return 1;
    };
    log_event( 'WARN', '-', 'access record failed', error => "$@" )
        if !$ok && $@;
    return;
}

# Retention: on the first request of a new day, drop day-files older than the
# window. Filename-dated, so no stat storm; runs once per day per site.
sub _access_prune {
    my ( $dir, $days ) = @_;
    my @c      = gmtime( time() - $days * 86400 );
    my $cutoff = sprintf '%04d%02d%02d', $c[5] + 1900, $c[4] + 1, $c[3];
    opendir my $dh, $dir or return;
    for my $e ( readdir $dh ) {
        next unless $e =~ /^access-(\d{8})\.jsonl$/;
        unlink "$dir/$e" if $1 lt $cutoff;
    }
    closedir $dh;
    return;
}

1;

package Lazysite::BadUrl;

# Bad-URL auto-blocker (SM128). Recognises the steady stream of
# vulnerability-scanner probes, counts them per source IP in a rolling window,
# and blocks an IP after a threshold. Enforcement lives in the auth wrapper
# (lazysite-auth.pl), which is in the request path for auth-wrapped sites; the
# block-check is deliberately cheap (a bare -f when nothing is blocked) so the
# common case adds almost nothing.
#
# Two small JSON stores under lazysite/cache/:
#   bad-url-blocked.json : { ip => { since, count, path } }  (created on 1st block)
#   bad-url-hits.json    : { ip => [ epoch, ... ] }          (rolling-window counters)

use strict;
use warnings;
use Lazysite::Paths ();
use JSON::PP        ();
use Fcntl           qw(:flock);
use Exporter 'import';
our @EXPORT_OK = qw(guard is_bad_url is_blocked exempt exempt_names validate_exempt site_has_file record_and_check list_blocks block unblock);

# SM128 / SM1181 S1: THE GUARD, one function for every caller in the request path.
#
# It was lazysite-auth.pl's _bad_url_guard; the pool's front door runs the same
# guard in its worker (SM1181 S3), so it moved here and the wrapper calls it.
#
#   guard( docroot => $d, path => $request_path, ip => $visitor,
#          conf_lines => \@lazysite_conf_lines )  -> 1 refuse, 0 carry on
#
# conf_lines are lazysite.conf's lines as the caller already holds them; the
# bad_url_* keys are LAST match wins (FDO-2: the wrapper's rule, kept). The
# blocker is on unless bad_url_block says disabled. `ip` is THE visitor address
# (SM929: request_address under trusted_proxies, never the front proxy's), and no
# address is never refused. A refused request is the caller's to answer (the CGI
# prints a 403 and exits; a worker must not exit): this decides, and writes the
# audit row and the log line when THIS request is the one that trips a block.
#
# SM1321 (ruling 48, T-03): TWO THINGS ARE NEVER COUNTED. A path that resolves to a
# file the site really has is not a probe, whatever it looks like: `vendor/` is a
# probe pattern and also where a theme keeps its scripts, and counting a site's own
# assets blocked 127.0.0.1 - every visitor behind the front proxy - for 1h44m. And
# an exempt address - loopback always (ruling 83), and the address lists
# `bad_url_exempt` names - is never counted and never refused, a block already on
# file included.
sub guard {
    my (%o) = @_;
    my %c;
    for my $line ( @{ $o{conf_lines} || [] } ) {
        if ( $line =~ /^\s*(bad_url_\w+)\s*:\s*(.+?)\s*$/ ) { $c{$1} = $2 }
    }
    return 0 if ( $c{bad_url_block} // 'enabled' ) eq 'disabled';
    my $ip = $o{ip};
    return 0 unless defined $ip && length $ip;
    my ( $docroot, $path ) = ( $o{docroot}, $o{path} );

    # The exemption is asked only when it would change the answer: a blocked
    # address, or a probe about to be counted. The common request asks nothing.
    return 1 if is_blocked( $docroot, $ip ) && !exempt( $docroot, $ip, $c{bad_url_exempt} );

    my @extra = grep { length } map { s/^\s+|\s+$//gr } split /,/, ( $c{bad_url_extra} // '' );
    return 0 unless is_bad_url( $path, \@extra );
    return 0 if site_has_file( $docroot, $path );
    return 0 if exempt( $docroot, $ip, $c{bad_url_exempt} );

    my $threshold = ( $c{bad_url_threshold} || 10 ) + 0;
    my $window    = ( $c{bad_url_window}    || 3600 ) + 0;
    return 0 unless record_and_check( $docroot, $ip, $path, threshold => $threshold, window => $window );

    # The row the wrapper has always written: the pseudo-actor `system`, the site's
    # Host as the target, origin `auth`.
    require Lazysite::Audit;
    require Lazysite::Util;
    my $host = lc( $ENV{HTTP_HOST} // '' );
    $host =~ s/:\d+\z//;
    $host =~ s/[^a-z0-9.-]//g;
    Lazysite::Audit::audit_log( 'system', 'ip-auto-blocked', $host, $ip, 'ok', 'auth',
        'path=' . substr( $path, 0, 120 ) );
    Lazysite::Util::log_event( 'WARN', '-', 'IP auto-blocked (bad-url scanner)', ip => $ip );
    return 1;
}

# Built-in probe patterns. A lazysite site serves no PHP, so any .php is a probe.
# Mirrors the stats extension's noise set (kept in sync by t/unit/lib/12-bad-url.t).
my $BAD_RE = qr{
    (?: ^ | / )
    (?: wp-login\.php | wp-admin | wp-includes | wp-content | xmlrpc\.php
      | phpmyadmin | \bpma\b | \.env | \.git | \.aws | \.ssh
      | vendor/ | boaform | eval-stdin | HNAP1 | setup\.cgi
      | owa/ | autodiscover | actuator | console/ )
  | \.php (?: $ | [?/] )
}xi;

my $BLOCK_CAP = 10_000;    # keep the blocked store bounded (drop oldest over this)
my $HIT_CAP   = 20_000;    # keep the hit store bounded (drop oldest IPs over this)

# SM1321 (ruling 83): loopback is ALWAYS exempt. It is the front proxy and the
# machine's own checks; blocking it refuses everyone at once. Only the value `none`
# takes it away.
our $LOOPBACK = '127.0.0.0/8, ::1';

# SM1321: IS THIS ADDRESS EXEMPT FROM THE BLOCKER? Loopback is (above), and so is an
# address in an address list `bad_url_exempt` (lazysite.conf) names: a comma list of
# list NAMES only (ruling 84; SM1138 lists, membership only, so either kind). No
# address or range is written in the key - an exemption is a list the Access pages
# show. The value `none` exempts nothing, loopback included (ruling 83).
#
# An item that names no list in the store exempts nobody and is never silent:
# AddressLists logs it once, validate_exempt refuses it at save, and `lazysite check`
# names it (AddressRefs reads this key). An unreadable store exempts nobody but
# loopback (fails toward counting, never toward letting a scanner through).
#
# THE ONE PLACE THE BLOCKER TOUCHES ADDRESS LISTS (rulings 56-58 rename them address
# profiles): exempt_names, exempt and validate_exempt here, and AddressRefs' line for
# the key.
#
# exempt_names($spec) -> ( $loopback, @names )
sub exempt_names {
    my ($spec) = @_;
    return (1) unless defined $spec && $spec =~ /\S/;
    ( my $v = $spec ) =~ s/\A\s+|\s+\z//g;
    return (0) if lc $v eq 'none';
    return ( 1, grep { length && lc ne 'none' } map { s/\A\s+|\s+\z//gr } split /,/, $v );
}

sub exempt {
    my ( $docroot, $ip, $spec ) = @_;
    return 0 unless defined $ip && length $ip;
    my ( $loopback, @names ) = exempt_names($spec);
    if ($loopback) {
        require Lazysite::Util;
        my ($set) = Lazysite::Util::parse_trusted_proxies($LOOPBACK);
        my $p = Lazysite::Util::_packed_address($ip); ## no critic (Subroutines::ProtectPrivateSubs)
        return 1 if length $p && Lazysite::Util::_address_in_set( $p, $set ); ## no critic (Subroutines::ProtectPrivateSubs)
    }
    return 0 unless @names;
    my $lz = Lazysite::Paths::lazysite_dir($docroot);
    return 0 unless defined $lz;
    require Lazysite::Auth::AddressLists;
    no warnings 'once';
    local $Lazysite::Auth::AddressLists::AUTH_DIR = "$lz/auth";
    for my $n (@names) { return 1 if Lazysite::Auth::AddressLists::in_list( $ip, $n ) }
    return 0;
}

# SM1321 (ruling 84): the Config page's save-time check of `bad_url_exempt` (the
# descriptor names it; Manager::Plugins calls it with the lazysite dir). '' when the
# value may be stored, else why not: an item that is not a list name (an address or
# a range among them: the key names lists only), a name the store does not hold, and
# `none` beside names (it is the whole value or nothing).
sub validate_exempt {
    my ( $value, $lz ) = @_;
    return '' unless defined $value && $value =~ /\S/;
    ( my $v = $value ) =~ s/\A\s+|\s+\z//g;
    return '' if lc $v eq 'none';
    my @items = grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $v;
    require Lazysite::Auth::AddressLists;
    no warnings 'once';
    local $Lazysite::Auth::AddressLists::AUTH_DIR = defined $lz ? "$lz/auth" : undef;
    my %have  = map { $_ => 1 } Lazysite::Auth::AddressLists::list_names();
    my $fault = Lazysite::Auth::AddressLists::store_fault();
    my @why;
    for my $i (@items) {
        if ( lc $i eq 'none' ) {
            push @why, "'none' is the whole value (it turns off loopback's exemption too) and cannot stand beside list names";
        }
        elsif ( !Lazysite::Auth::AddressLists::valid_name($i) ) {
            push @why, "'$i' is not an address list name (this key names address lists only; loopback is always exempt)";
        }
        elsif ( !$fault && !$have{$i} ) {
            push @why, "'$i' is not an address list (make it under Access -> Address lists first)";
        }
    }
    return join '; ', @why;
}

# SM1321: DOES THIS REQUEST PATH NAME A FILE THE SITE HAS? Then it is the site's own
# asset and not a probe. Resolved without trusting the path: the query goes, it is
# percent-decoded once, and it must be plain segments under the docroot - a `.` or
# `..` segment, a NUL or a backslash is not a file of the site's. Each step is
# lstat'd from the docroot down, every folder a real folder and the last a regular
# file, so a symbolic link anywhere on the way does not count (it could point out of
# the site). A dot segment does not count either (`.env`, `.git/config` are exactly
# what a scanner asks for, and a site serves none), nor does the engine tree under
# the docroot (lazysite/, which the web server refuses).
sub site_has_file {
    my ( $docroot, $path ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $path;
    ( my $p = $path ) =~ s/[?#].*\z//s;
    $p                =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return 0 if $p    =~ /[\0\\]/;
    my @seg = grep { length } split m{/}, $p;
    return 0 unless @seg;
    return 0 if grep { /\A\./ } @seg;                   # `.`, `..` and every hidden name
    return 0 if $seg[0] eq $Lazysite::Paths::DIRNAME;
    ( my $at = $docroot ) =~ s{/+\z}{};
    for my $i ( 0 .. $#seg ) {
        $at .= "/$seg[$i]";
        lstat $at or return 0;
        return 0 if -l _;
        if   ( $i < $#seg ) { return 0 unless -d _ }
        else                { return 0 unless -f _ }
    }
    return 1;
}

sub _blocked_path { return Lazysite::Paths::lazysite_dir( $_[0] ) . "/cache/bad-url-blocked.json" }
sub _hits_path { return Lazysite::Paths::lazysite_dir( $_[0] ) . "/cache/bad-url-hits.json" }

# Does this request path look like a scanner probe? $extra is an optional arrayref
# of sysop-added substrings.
sub is_bad_url {
    my ( $path, $extra ) = @_;
    return 0 unless defined $path && length $path;
    return 1 if $path =~ $BAD_RE;
    if ( ref $extra eq 'ARRAY' ) {
        for my $p ( @{$extra} ) {
            next unless defined $p && length $p;
            return 1 if index( $path, $p ) >= 0;
        }
    }
    return 0;
}

# Cheap: no blocked store on disk means nothing is blocked.
sub is_blocked {
    my ( $docroot, $ip ) = @_;
    return 0 unless defined $ip && length $ip;
    my $f = _blocked_path($docroot);
    return 0 unless -f $f;
    my $b = _read_json($f);
    return ( ref $b eq 'HASH' && $b->{$ip} ) ? 1 : 0;
}

# Record one bad-URL hit for $ip and decide whether it is now blocked. Returns 1
# if the IP is blocked (freshly or already), 0 otherwise. Window/threshold come
# from %opt (defaults: 10 hits in 3600s). Atomic under flock.
sub record_and_check {
    my ( $docroot, $ip, $path, %opt ) = @_;
    return 0 unless defined $ip && length $ip;
    my $threshold = $opt{threshold} || 10;
    my $window    = $opt{window}    || 3600;
    my $now       = $opt{now}       || time();

    my $cache = Lazysite::Paths::lazysite_dir($docroot) . "/cache";
    return 0 unless -d $cache || mkdir $cache;

    # --- rolling-window hit counter (locked, atomic read-modify-write) ---
    my $count = 0;
    _locked_rmw( $docroot, _hits_path($docroot), sub {
            my ($hits) = @_;
            my @recent = grep { $_ > $now - $window } @{ $hits->{$ip} || [] };
            push @recent, $now;
            $hits->{$ip} = \@recent;
            $count = scalar @recent;

            # Bound the store: drop IPs whose most-recent hit is oldest.
            if ( keys %{$hits} > $HIT_CAP ) {
                my @by_age = sort { ( $hits->{$b}[-1] || 0 ) <=> ( $hits->{$a}[-1] || 0 ) } keys %{$hits};
                delete $hits->{$_} for @by_age[ $HIT_CAP .. $#by_age ];
            }
            return $hits;
    } );

    return 0 if $count < $threshold;

    # --- threshold reached: block the IP ---
    _update_blocked( $docroot, sub {
            my ($blk) = @_;
            $blk->{$ip} ||= { since => $now, count => $count, path => substr( $path // '', 0, 200 ) };
            $blk->{$ip}{count} = $count;
            if ( keys %{$blk} > $BLOCK_CAP ) {
                my @old = sort { ( $blk->{$a}{since} || 0 ) <=> ( $blk->{$b}{since} || 0 ) } keys %{$blk};
                delete $blk->{$_} for @old[ $BLOCK_CAP .. $#old ];
            }
            return $blk;
    } );
    return 1;
}

sub list_blocks {
    my ($docroot) = @_;
    my $b = _read_json( _blocked_path($docroot) );
    return {} unless ref $b eq 'HASH';
    return $b;
}

# SM704: block an address the operator names, rather than only one the
# threshold caught. An operator watching a probe in the access log should not
# have to wait for it to trip a counter.
#
# The shape matches what record_and_check writes, so the listing, the guard and
# unblock all treat a manual entry exactly like an automatic one - a manual
# block that needed its own handling everywhere would be a second kind of block.
# `by` records who, because "why is this address blocked" is the question asked
# later, and an automatic entry answers it with the path that tripped it.
sub block {
    my ( $docroot, $ip, %opt ) = @_;
    return 0 unless defined $ip && length $ip;
    return 0 if $ip =~ /[^0-9a-fA-F:.]/;    # an address, not a pattern
    my $added = 0;
    _update_blocked( $docroot, sub {
            my ($blk) = @_;
            return $blk if $blk->{$ip};     # already blocked; not an error
            $blk->{$ip} = {
                since => time,
                count => 0,
                path  => '(added by hand)',
                by    => ( defined $opt{by} ? $opt{by} : '' ),
            };
            $added = 1;
            return $blk;
    } );
    return $added;
}

sub unblock {
    my ( $docroot, $ip ) = @_;
    return 0 unless defined $ip && length $ip;
    my $removed = 0;
    _update_blocked( $docroot, sub {
            my ($blk) = @_;
            $removed = delete $blk->{$ip} ? 1 : 0;
            return $blk;
    } );
    return $removed;
}

# --- helpers ---------------------------------------------------------------

sub _read_json {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : undef;
}

# Locked read-modify-write of the blocked store via a callback.
sub _update_blocked {
    my ( $docroot, $mutate ) = @_;
    return _locked_rmw( $docroot, _blocked_path($docroot), $mutate );
}

# Serialised, atomic read-modify-write of a cache JSON store. The exclusive lock
# lives on a stable sidecar lockfile (NOT the data file) so it still serialises
# writers across the temp+rename - flock on the data file itself would not,
# because rename swaps the inode out from under the lock. temp+rename means a
# lock-free reader (_read_json) never catches a half-written store, and a crash
# mid-write leaves the previous store intact rather than truncated. $mutate gets
# the decoded hashref (or {}) and returns the hashref to persist.
sub _locked_rmw {
    my ( $docroot, $data, $mutate ) = @_;
    my $cache = Lazysite::Paths::lazysite_dir($docroot) . "/cache";
    return unless -d $cache || mkdir $cache;
    open my $lk, '>', "$cache/.bad-url.lock" or return;
    flock $lk, LOCK_EX or do { close $lk; return };

    my $cur = _read_json($data);
    $cur = {} unless ref $cur eq 'HASH';
    my $new = $mutate->($cur);

    my $tmp = "$data.tmp.$$";
    if ( open my $fh, '>', $tmp ) {
        print {$fh} JSON::PP::encode_json($new);
        if ( close $fh ) { rename $tmp, $data or unlink $tmp }
        else             { unlink $tmp }
    }
    close $lk;    # release after the rename, so the RMW is fully serialised
    return $new;
}

1;

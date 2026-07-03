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
use JSON::PP ();
use Fcntl    qw(:flock SEEK_SET);
use Exporter 'import';
our @EXPORT_OK = qw(is_bad_url is_blocked record_and_check list_blocks unblock);

# Built-in probe patterns. A lazysite site serves no PHP, so any .php is a probe.
# Mirrors the stats plugin's noise set (kept in sync by t/unit/lib/12-bad-url.t).
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

sub _blocked_path { return "$_[0]/lazysite/cache/bad-url-blocked.json" }
sub _hits_path    { return "$_[0]/lazysite/cache/bad-url-hits.json" }

# Does this request path look like a scanner probe? $extra is an optional arrayref
# of operator-added substrings.
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

    my $cache = "$docroot/lazysite/cache";
    return 0 unless -d $cache || mkdir $cache;

    # --- rolling-window hit counter (locked read-modify-write) ---
    my $hf = _hits_path($docroot);
    open my $fh, '+>>', $hf or return 0;
    flock $fh, LOCK_EX or do { close $fh; return 0 };
    seek $fh, 0, SEEK_SET;
    my $raw  = do { local $/; <$fh> };
    my $hits = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
    $hits = {} unless ref $hits eq 'HASH';

    my @recent = grep { $_ > $now - $window } @{ $hits->{$ip} || [] };
    push @recent, $now;
    $hits->{$ip} = \@recent;
    my $count = scalar @recent;

    # Bound the store: drop IPs whose most-recent hit is oldest.
    if ( keys %{$hits} > $HIT_CAP ) {
        my @by_age = sort { ( $hits->{$b}[-1] || 0 ) <=> ( $hits->{$a}[-1] || 0 ) } keys %{$hits};
        delete $hits->{$_} for @by_age[ $HIT_CAP .. $#by_age ];
    }

    seek $fh, 0, SEEK_SET;
    truncate $fh, 0;
    print {$fh} JSON::PP::encode_json($hits);
    close $fh;

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
    my $cache = "$docroot/lazysite/cache";
    return unless -d $cache || mkdir $cache;
    my $f = _blocked_path($docroot);
    open my $fh, '+>>', $f or return;
    flock $fh, LOCK_EX or do { close $fh; return };
    seek $fh, 0, SEEK_SET;
    my $raw = do { local $/; <$fh> };
    my $b   = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
    $b = {} unless ref $b eq 'HASH';
    $b = $mutate->($b);
    seek $fh, 0, SEEK_SET;
    truncate $fh, 0;
    print {$fh} JSON::PP::encode_json($b);
    close $fh;
    return;
}

1;

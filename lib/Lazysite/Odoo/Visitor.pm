package Lazysite::Odoo::Visitor;

# SM747 CU / Q1 (ruled 2026-10-12): WHO AN ANONYMOUS VISITOR IS, FOR AN ODOO
# BINDING - and why they can only ever reach their own basket.
#
# The ruling's use case is a basket: a visitor adds to it and Odoo holds it as
# a quotation. Several visitors share one connection user, so Odoo cannot tell
# them apart; lazysite has to, and has to do it without trusting anything the
# visitor sends. So:
#
#   * THE KEY IS MINTED HERE, never accepted from outside: 256 bits from
#     /dev/urandom, carried in a cookie SIGNED with the extension's own secret.
#     A cookie this server did not mint fails the signature and is treated as
#     no visitor at all - so a guessed, copied-from-a-URL or enumerated key
#     names nothing.
#   * THE COOKIE IS HttpOnly AND SameSite=Strict: page script cannot read it,
#     and a cross-site POST arrives WITHOUT it, so another site cannot make a
#     visitor's browser act on their basket.
#   * THE CSRF TOKEN IS BOUND TO THE KEY (an HMAC of it under the same secret),
#     and a state-changing POST needs both: the cookie the browser holds and the
#     token only a same-origin page could have fetched.
#   * IN EVERY RECORD THE VISITOR IS A HASH OF THE KEY, never the key: the key
#     is a bearer secret, and the call record and the audit trail are read by
#     operators.
#
# The extension's secret is its own file, not the auth secret: a visitor key is
# not a login, and the two are rotated for different reasons.
use strict;
use warnings;
use Digest::SHA     qw(hmac_sha256_hex sha256_hex);
use File::Path      qw(make_path);
use Lazysite::Util  qw(cannot_read const_eq);
use Lazysite::Paths ();

our $DOCROOT = '';
our $COOKIE  = 'lzs_odoo_visitor';
our $MAX_AGE = 30 * 86400;

sub _secret_file { return Lazysite::Paths::lazysite_dir($DOCROOT) . '/odoo/visitor.secret' }

# The extension's visitor secret: read, or minted once. undef when it exists and
# cannot be read - a SECOND secret would orphan every basket in the field, so an
# unreadable one is a refusal, never a reason to mint.
sub _secret {
    my $p = _secret_file();
    if ( open my $fh, '<', $p ) {
        chomp( my $s = <$fh> // '' );
        close $fh;
        return $s if length $s >= 32;
        return undef;
    }
    if ( !$!{ENOENT} ) { cannot_read( 'the Odoo visitor secret', $p ); return undef }
    my $s = random_hex(32) // return undef;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    eval { make_path( $dir, { mode => 0700 } ) unless -d $dir; 1 } or return undef;
    my $old = umask 077;
    my $ok  = open my $w, '>', "$p.tmp.$$";
    umask $old;
    return undef unless $ok;
    print {$w} "$s\n";
    close $w;
    # Two first requests at once: the first rename wins and the second reads
    # the winner's, so both answer with the secret that is on disk.
    link "$p.tmp.$$", $p;
    unlink "$p.tmp.$$";
    open my $r, '<', $p or return undef;
    chomp( my $got = <$r> // '' );
    close $r;
    return length $got >= 32 ? $got : undef;
}

# The extension's secret, for the signed cookies that share it (the Odoo session
# cookie signs under a label of its own). undef when it cannot be read or made.
sub secret { return _secret() }

sub random_hex {
    my ($bytes) = @_;
    open my $u, '<:raw', '/dev/urandom' or return undef;
    my $raw = '';
    my $got = read $u, $raw, $bytes;
    close $u;
    return undef unless defined $got && $got == $bytes;
    return unpack 'H*', $raw;
}

# A new key and the cookie value carrying it. ( key, cookie ) or () when no
# CSPRNG or no secret - the caller refuses rather than inventing a weaker key.
sub mint {
    my $secret = _secret()      // return ();
    my $key    = random_hex(32) // return ();
    return ( $key, "$key." . hmac_sha256_hex( "visitor|$key", $secret ) );
}

# The key a request's Cookie header carries, if this server minted it; undef
# otherwise. Constant-time comparison, so the signature cannot be found a byte
# at a time.
sub key_from_cookie {
    my ($header) = @_;
    return undef unless defined $header && length $header;
    my ($v) = $header =~ /(?:\A|;\s*)\Q$COOKIE\E=([0-9a-f]{64}\.[0-9a-f]{64})(?:;|\z)/;
    return undef unless defined $v;
    my ( $key, $sig ) = split /\./, $v, 2;
    my $secret = _secret() // return undef;
    return const_eq( $sig, hmac_sha256_hex( "visitor|$key", $secret ) ) ? $key : undef;
}

# What a record names the visitor by: a hash, never the key.
sub visitor_id {
    my ($key) = @_;
    return '' unless defined $key && length $key;
    return substr( sha256_hex("visitor-id|$key"), 0, 16 );
}

sub csrf_token {
    my ($key) = @_;
    my $secret = _secret() // return undef;
    return hmac_sha256_hex( "csrf|$key", $secret );
}

sub verify_csrf {
    my ( $token, $key ) = @_;
    return 0 unless defined $token && length $token && defined $key && length $key;
    my $want = csrf_token($key) // return 0;
    return const_eq( $token, $want ) ? 1 : 0;
}

sub set_cookie_header {
    my ( $cookie, %o ) = @_;
    return "Set-Cookie: $COOKIE=$cookie; Path=/; HttpOnly; SameSite=Strict; Max-Age=$MAX_AGE"
        . ( $o{secure} ? '; Secure' : '' );
}

1;

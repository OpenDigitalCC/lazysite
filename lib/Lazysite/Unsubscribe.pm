package Lazysite::Unsubscribe;

# SM1073 (SM1010 R4): ONE-CLICK UNSUBSCRIBE FROM A NOTIFICATION RULE.
#
# Ruled 2026-10-12 (SM1010), "Per rule, default on": each rule's messages carry
# an unsubscribe link and a List-Unsubscribe header unless the rule turns it
# off. Phase 1 pointed both at a page the operator had to provide, and nothing
# in the engine recorded a refusal. This is the engine's half: a link that
# stops ONE rule writing to ONE recipient, in one click, without a sign-in
# (RFC 8058), and the suppression store the outbox job consults.
#
# THE LINK ACTS WITHOUT A SESSION, so the token is the whole of its authority:
#
#   * UNGUESSABLE. v1.<rule>.<recipient>.<mac>: the rule id, the recipient as
#     the 24-hex hash the ledger already keys it by (never an address or an
#     account name), and an HMAC-SHA256 over both under a key only the site
#     holds (notify/.unsubscribe.key, 256 random bits), cut to 128 bits.
#   * ITS OWN RULE AND RECIPIENT ONLY. The MAC covers both, so changing either
#     makes another token that does not verify; nothing in a request names
#     anything else.
#   * IDEMPOTENT. Recording a pair that is already recorded changes nothing and
#     says "already".
#   * AUDITED by the endpoint (lazysite-auth.pl, action=unsubscribe): every
#     effective stop, every repeat, and every refused token.
#
# No expiry, deliberately: the same link is in every message of the rule, and a
# recipient may act on a message months old. Rotating the key (deleting the
# file) voids every link that was sent.
#
# THE STORE, notify/suppressed.jsonl: one line per stopped (rule, recipient
# hash), never an address. A store that exists and will not open is reported as
# such (undef), and the job then sends nothing - "could not tell who said stop"
# is not "nobody did".
use strict;
use warnings;
use Digest::SHA     qw(hmac_sha256_hex);
use Fcntl           qw(:flock O_WRONLY O_CREAT O_EXCL);
use File::Path      qw(make_path);
use File::Basename  qw(dirname);
use JSON::PP        ();
use Lazysite::Util  qw(cannot_read const_eq secure_write_perms);
use Lazysite::Paths ();

our $VERSION = '1.0';

my $RULE_RE = qr/[A-Za-z0-9][A-Za-z0-9_-]{0,63}/;
my $P_RE    = qr/[0-9a-f]{24}/;

sub _lz        { return Lazysite::Paths::lazysite_dir( $_[0] ) }
sub key_file   { return _lz( $_[0] ) . '/notify/.unsubscribe.key' }
sub store_file { return _lz( $_[0] ) . '/notify/suppressed.jsonl' }

# The site's key: ( $key ) or ( undef, $why ). With create => 1 (the outbox job)
# a missing key is made, once, exclusively; the endpoint never makes one, so a
# site that has sent no link verifies none.
sub key {
    my ( $docroot, %o ) = @_;
    my $f = key_file($docroot);
    for my $try ( 1 .. 2 ) {
        if ( open my $fh, '<:raw', $f ) {
            my $k = <$fh>;
            close $fh;
            $k = '' unless defined $k;
            $k =~ s/\s+\z//;
            return ($k) if $k =~ /\A[0-9a-f]{64}\z/;
            return ( undef, 'the unsubscribe key is not in the shape it is written in' );
        }
        return ( undef, 'the unsubscribe key exists and could not be read' ) unless $!{ENOENT};
        return ( undef, 'no unsubscribe key: no link has been sent' ) unless $o{create};
        eval { make_path( dirname($f) ) unless -d dirname($f); 1 }
            or return ( undef, 'cannot create the notify directory for the unsubscribe key' );
        require Lazysite::Auth::Credential;
        my $k = Lazysite::Auth::Credential::generate_random_hex(32);
        if ( sysopen my $wh, $f, O_WRONLY | O_CREAT | O_EXCL, 0660 ) {
            my $ok = print {$wh} "$k\n";
            close $wh or $ok = 0;
            return ( undef, 'the unsubscribe key could not be written' ) unless $ok;
            secure_write_perms( $f, 0660 );
            return ($k);
        }
        return ( undef, "the unsubscribe key could not be created: $!" ) unless $!{EEXIST};
        # Another process made it between the open and the create: read theirs.
    }
    return ( undef, 'the unsubscribe key could not be settled' );
}

sub _mac {
    my ( $key, $rule, $p ) = @_;
    return substr( hmac_sha256_hex( "lazysite-unsubscribe\0v1\0$rule\0$p", $key ), 0, 32 );
}

# The token for one rule and one recipient hash: ( $token ) or ( undef, $why ).
sub token {
    my ( $docroot, $rule, $p ) = @_;
    return ( undef, 'not a rule id' ) unless defined $rule     && $rule =~ /\A$RULE_RE\z/;
    return ( undef, 'not a recipient hash' ) unless defined $p && $p    =~ /\A$P_RE\z/;
    my ( $key, $why ) = key( $docroot, create => 1 );
    return ( undef, $why ) unless defined $key;
    return ( "v1.$rule.$p." . _mac( $key, $rule, $p ) );
}

# ( $rule, $p ) for a token this site issued, or ( undef ) - never a reason a
# caller could use to tell a near miss from a wild guess.
sub verify {
    my ( $docroot, $token ) = @_;
    return unless defined $token && !ref $token;
    my ( $rule, $p, $mac ) = $token =~ /\Av1\.($RULE_RE)\.($P_RE)\.([0-9a-f]{32})\z/ or return;
    my ($key) = key($docroot);
    return unless defined $key;
    # Compared in constant time: the answer must not say how much of it matched.
    return const_eq( _mac( $key, $rule, $p ), $mac ) ? ( $rule, $p ) : ();
}

# { "rule\0p" => 1 } for every stopped pair, {} when nothing was ever stopped,
# undef when the store exists and will not open.
sub suppressed {
    my ($docroot) = @_;
    my $f = store_file($docroot);
    open my $fh, '<:raw', $f or return $!{ENOENT} ? {} : cannot_read( 'the unsubscribe store', $f );
    my %s;
    while ( my $line = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($line) } or next;
        $s{"$r->{r}\0$r->{p}"} = 1 if ref $r eq 'HASH' && defined $r->{r} && defined $r->{p};
    }
    close $fh;
    return \%s;
}

# Record that this recipient stopped this rule: ( 'added' ), ( 'already' ) or
# ( undef, $why ). Under an exclusive lock, so two clicks record one line.
sub record {
    my ( $docroot, $rule, $p, $now ) = @_;
    return ( undef, 'not a rule and recipient' )
        unless defined $rule && $rule =~ /\A$RULE_RE\z/ && defined $p && $p =~ /\A$P_RE\z/;
    my $f = store_file($docroot);
    eval { make_path( dirname($f) ) unless -d dirname($f); 1 } or return ( undef, 'cannot create the notify directory' );
    open my $fh, '+>>:raw', $f or return ( undef, "the unsubscribe store could not be opened: $!" );
    flock $fh, LOCK_EX or return ( undef, 'the unsubscribe store could not be locked' );
    seek $fh, 0, 0;
    while ( my $line = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($line) } or next;
        next unless ref $r eq 'HASH';
        if ( ( $r->{r} // '' ) eq $rule && ( $r->{p} // '' ) eq $p ) { close $fh; return ('already') }
    }
    seek $fh, 0, 2;
    my $ok = print {$fh} JSON::PP->new->canonical->encode( { r => $rule, p => $p, t => $now // time } ) . "\n";
    close $fh or $ok = 0;
    return $ok ? ('added') : ( undef, 'the unsubscribe store could not be written' );
}

1;

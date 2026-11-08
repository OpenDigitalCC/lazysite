package Lazysite::Endpoint;

# SM1369 X5, H-4 (ruling 55): THE REQUEST KIT AN EXTENSION'S ENDPOINT USES.
#
# An extension that answers a browser directly - a CGI it declares in
# `owns.endpoints` and in `hooks.endpoints` - reads its body, and checks the
# token of a POST, through this module and through nothing of its own. What it
# gives:
#
#   * THE BODY, CAPPED BEFORE IT IS READ (read_body): a declared length over the
#     cap is refused 413 and not a byte is read; a body shorter than it said is
#     refused. The endpoint names its cap (64 KB, or a larger one it has decided
#     from the query before the body - an Odoo binding's declared budget); the
#     kit holds every read to it.
#   * THE VISITOR, for a caller with no account (visitor_*). Moved here from the
#     Odoo extension (SM747 CU / Q1, ruled 2026-10-12): a 256-bit key minted
#     here, never accepted from outside, in a cookie SIGNED with the extension's
#     own secret, HttpOnly and SameSite=Strict, so a cross-site POST arrives
#     without it; a CSRF token bound to the key; and in every record a hash of
#     the key, never the key. Each extension has its own secret
#     (lazysite/<id>/visitor.secret) and cookie (lzs_<id>_visitor): the names
#     the Odoo extension's cookie and secret always had, so no basket in the
#     field is orphaned by the move.
#   * THE TOKEN OF A POST, checked BEFORE THE EXTENSION'S CODE (post_guard,
#     G-4): a POST carries the session's CSRF token for the account it is
#     signed in as, or the visitor token bound to the visitor cookie it carries,
#     or it is refused 403 kind csrf with nothing of the extension run. An
#     endpoint may then ask for the one token its operation needs (session or
#     visitor, through session_token_ok and verify_visitor_token) - it may be
#     stricter than the kit, never weaker.
#
# RATE CAPS AND THE AUDIT LINE are core's already and the kit adds nothing to
# them: Lazysite::Egress::may_invoke and within_caps (E-8 - the extension
# counts its own records and core says whether a cap is reached, refusing when
# the count could not be taken), and Lazysite::Audit::audit_log, one line per
# call with the extension's id as its origin.
#
# t/lint/351 holds every declared endpoint to the kit: it reads no body of its
# own, makes no token of its own, and every body it reads is guarded before
# anything else of it runs.
use strict;
use warnings;
use Exporter 'import';
use Digest::SHA     qw(hmac_sha256_hex sha256_hex);
use File::Path      qw(make_path);
use Lazysite::Util  qw(cannot_read const_eq);
use Lazysite::Paths ();

our @EXPORT_OK = qw(read_body multipart_boundary parse_multipart post_guard csrf_refusal session_token_ok visitor_cookie_name
    visitor_secret visitor_mint visitor_key visitor_id visitor_token verify_visitor_token
    visitor_cookie_header random_hex);

our $VISITOR_MAX_AGE = 30 * 86400;

my $ID = qr/\A[a-z][a-z0-9-]{0,31}\z/;

# ---- the body ----

# ( $raw, undef ) or ( undef, [ status, data ] ). $len is the declared
# CONTENT_LENGTH, $cap the most this endpoint takes. Nothing is read when the
# declaration is over the cap; what is read is exactly $len bytes or a refusal.
sub read_body {
    my ( $len, $cap ) = @_;
    $len = 0 unless defined $len && $len =~ /\A\d+\z/;
    return ( undef, [ '413 Payload Too Large', { ok => 0, kind => 'too-large', error => 'body too large' } ] )
        if !defined $cap || $len > $cap;
    return ( '', undef ) unless $len;
    binmode STDIN;
    my ( $body, $got ) = ( '', 0 );
    while ( $got < $len ) {
        my $r = read( STDIN, $body, $len - $got, $got );
        last unless $r;
        $got += $r;
    }
    return ( undef, [ '400 Bad Request',
            { ok => 0, kind => 'invalid', error => "the body is $got bytes where Content-Length said $len" } ] )
        unless $got == $len;
    return ( $body, undef );
}

# THE BODY OF A multipart/form-data POST, so the tokens its `json` part carries
# are read by the kit before the extension sees the request (moved here from
# the Odoo extension's upload module, SM1162). multipart_boundary( $content_type )
# -> the boundary or undef.
sub multipart_boundary {
    my ($ct) = @_;
    return undef unless defined $ct && $ct =~ m{\Amultipart/form-data\b}i;
    my ( $q, $u ) = $ct =~ m{;\s*boundary=(?:"([^"]{1,70})"|([^\s;"]{1,70}))}i;
    my $bnd = $q // $u;
    return ( defined $bnd && length $bnd ) ? $bnd : undef;
}

# parse_multipart( $body, $boundary, json_limit => N, max_parts => N )
#   -> ( { json => $text, files => { field => [ {name, bytes, claimed} ] } }, '' ) or ( undef, why )
# Strict: the body is exactly --B CRLF headers CRLF CRLF content CRLF ... --B--.
# One part named json, a plain value; every other part a file with a name and a
# file name. A part that is not understood is refused, not ignored: what is
# ignored is what nobody checked.
sub parse_multipart {
    my ( $body, $bnd, %o ) = @_;
    my $json_limit = $o{json_limit} // 64 * 1024;
    my $max_parts  = $o{max_parts}  // 12;
    my $dash       = "--$bnd";
    my $start      = index( $body, "$dash\r\n" );
    return ( undef, 'the body is not multipart/form-data (no opening boundary)' ) unless $start == 0;
    my $end  = "\r\n$dash--";
    my $stop = rindex( $body, $end );
    return ( undef, 'the body is cut short (no closing boundary)' ) if $stop < 0;
    my $inner = substr( $body, length($dash) + 2, $stop - length($dash) - 2 ); # parts only
    my @raw   = _split_on( $inner, "\r\n$dash\r\n" );
    return ( undef, "a request holds at most $max_parts parts" ) if @raw > $max_parts;
    my ( $json, %files );
    for my $part (@raw) {
        my $sep = index( $part, "\r\n\r\n" );
        return ( undef, 'a part has no header block' ) if $sep < 0;
        my $head    = substr( $part, 0, $sep );
        my $content = substr( $part, $sep + 4 );
        my ($disp)  = $head =~ /^Content-Disposition:[ \t]*(.*)$/mi;
        return ( undef, 'a part has no Content-Disposition' ) unless defined $disp && $disp =~ /\Aform-data\b/i;
        my ($name) = $disp =~ /;\s*name="([^"]*)"/;
        return ( undef, 'a part has no name' ) unless defined $name && length $name;
        my ($file) = $disp =~ /;\s*filename="([^"]*)"/;
        my ($type) = $head =~ /^Content-Type:[ \t]*([^\r\n;]+)/mi;
        if ( !defined $file ) {
            return ( undef, "the part '$name' is not a file: send plain values in the part named json" )
                unless $name eq 'json';
            return ( undef, 'the json part is sent twice' ) if defined $json;
            return ( undef, "the json part is longer than $json_limit bytes" ) if length $content > $json_limit;
            $json = $content;
            next;
        }
        return ( undef, 'the part named json is a body, not a file' ) if $name eq 'json';
        return ( undef, "the file field '$name' is not a name" ) unless $name =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z/;
        my $fname = $file;
        utf8::decode($fname) or $fname =~ s/[^\x20-\x7e]/_/g;
        return ( undef, "the file field '$name' has no file name" ) unless length $fname;
        push @{ $files{$name} }, { name => $fname, bytes => $content, claimed => $type };
    }
    return ( { json => $json, files => \%files }, '' );
}

# Splits on a literal separator, without a regex on binary content.
sub _split_on {
    my ( $s, $sep ) = @_;
    my @out;
    my $pos = 0;
    while ( ( my $i = index( $s, $sep, $pos ) ) >= 0 ) {
        push @out, substr( $s, $pos, $i - $pos );
        $pos = $i + length $sep;
    }
    push @out, substr( $s, $pos );
    return @out;
}

# ---- the token of a POST ----

# The session's CSRF token, from the X-CSRF-Token header or the body's `token`,
# for the account the request is verified as. 0 for no account.
sub session_token_ok {
    my ( $user, $req ) = @_;
    return 0 unless defined $user && length $user;
    my $t = $ENV{HTTP_X_CSRF_TOKEN} // ( ref $req eq 'HASH' ? $req->{token} : undef ) // '';
    require Lazysite::Auth::Session;
    return Lazysite::Auth::Session::verify_csrf_token( $t, $user ) ? 1 : 0;
}

# The refusal a POST without its token gets: ( status, data ). `no_key` when
# the caller has neither an account nor a visitor cookie, so the answer says
# what to fetch first.
sub csrf_refusal {
    my (%o) = @_;
    return ( '403 Forbidden',
        { ok => 0, kind => 'csrf',
            error => $o{no_key}
            ? 'no visitor key on this request - fetch tokens from ?csrf=1 first'
            : 'missing or stale token - fetch fresh ones from ?csrf=1 and retry' } );
}

# THE KIT'S CHECK OF A POST (G-4), run on the parsed body before the endpoint
# does anything with it: undef when the request carries a token it may carry -
# the session's for the verified account (`user`), or the visitor token bound
# to the visitor key its cookie carries (`visitor`) - else the refusal, as
# [ status, data ].
#   %a: docroot, id (the extension's), req (the body), user, visitor
sub post_guard {
    my (%a) = @_;
    my $req = ref $a{req} eq 'HASH' ? $a{req} : {};
    return undef if session_token_ok( $a{user}, $req );
    return undef
        if verify_visitor_token( $a{docroot}, $a{id}, $req->{visitor_token}, $a{visitor} );
    my $no_key = !( defined $a{user} && length $a{user} ) && !( defined $a{visitor} && length $a{visitor} );
    return [ csrf_refusal( no_key => $no_key ) ];
}

# ---- the visitor ----

sub visitor_cookie_name {
    my ($id) = @_;
    return undef unless defined $id && $id =~ $ID;
    return "lzs_${id}_visitor";
}

sub _visitor_secret_file {
    my ( $docroot, $id ) = @_;
    return undef unless defined $id && $id =~ $ID && defined $docroot && length $docroot;
    return Lazysite::Paths::lazysite_dir($docroot) . "/$id/visitor.secret";
}

sub random_hex {
    my ($bytes) = @_;
    open my $u, '<:raw', '/dev/urandom' or return undef;
    my $raw = '';
    my $got = read $u, $raw, $bytes;
    close $u;
    return undef unless defined $got && $got == $bytes;
    return unpack 'H*', $raw;
}

# The extension's visitor secret: read, or minted once. undef when it exists and
# cannot be read - a SECOND secret would orphan every visitor in the field, so
# an unreadable one is a refusal, never a reason to mint.
sub visitor_secret {
    my ( $docroot, $id ) = @_;
    my $p = _visitor_secret_file( $docroot, $id ) // return undef;
    if ( open my $fh, '<', $p ) {
        chomp( my $s = <$fh> // '' );
        close $fh;
        return $s if length $s >= 32;
        return undef;
    }
    if ( !$!{ENOENT} ) { cannot_read( "the $id visitor secret", $p ); return undef }
    my $s = random_hex(32) // return undef;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    eval { make_path( $dir, { mode => 0700 } ) unless -d $dir; 1 } or return undef;
    my $old = umask 077;
    my $ok  = open my $w, '>', "$p.tmp.$$";
    umask $old;
    return undef unless $ok;
    print {$w} "$s\n";
    close $w;
    # Two first requests at once: the first link wins and the second reads the
    # winner's, so both answer with the secret that is on disk.
    link "$p.tmp.$$", $p;
    unlink "$p.tmp.$$";
    open my $r, '<', $p or return undef;
    chomp( my $got = <$r> // '' );
    close $r;
    return length $got >= 32 ? $got : undef;
}

# A new key and the cookie value carrying it: ( key, cookie ), or () with no
# CSPRNG or no secret - the caller refuses rather than inventing a weaker key.
sub visitor_mint {
    my ( $docroot, $id ) = @_;
    my $secret = visitor_secret( $docroot, $id ) // return ();
    my $key    = random_hex(32)                  // return ();
    return ( $key, "$key." . hmac_sha256_hex( "visitor|$key", $secret ) );
}

# The key a request's Cookie header carries, if this server minted it; undef
# otherwise. Constant-time, so the signature cannot be found a byte at a time.
sub visitor_key {
    my ( $docroot, $id, $header, $cookie ) = @_;
    return undef unless defined $header && length $header;
    $cookie //= visitor_cookie_name($id) // return undef;
    my ($v) = $header =~ /(?:\A|;\s*)\Q$cookie\E=([0-9a-f]{64}\.[0-9a-f]{64})(?:;|\z)/;
    return undef unless defined $v;
    my ( $key, $sig ) = split /\./, $v, 2;
    my $secret = visitor_secret( $docroot, $id ) // return undef;
    return const_eq( $sig, hmac_sha256_hex( "visitor|$key", $secret ) ) ? $key : undef;
}

# What a record names the visitor by: a hash, never the key.
sub visitor_id {
    my ($key) = @_;
    return '' unless defined $key && length $key;
    return substr( sha256_hex("visitor-id|$key"), 0, 16 );
}

sub visitor_token {
    my ( $docroot, $id, $key ) = @_;
    return undef unless defined $key && length $key;
    my $secret = visitor_secret( $docroot, $id ) // return undef;
    return hmac_sha256_hex( "csrf|$key", $secret );
}

sub verify_visitor_token {
    my ( $docroot, $id, $token, $key ) = @_;
    return 0 unless defined $token && !ref $token && length $token && defined $key && length $key;
    my $want = visitor_token( $docroot, $id, $key ) // return 0;
    return const_eq( $token, $want ) ? 1 : 0;
}

sub visitor_cookie_header {
    my ( $id, $cookie, %o ) = @_;
    my $name = $o{name} // visitor_cookie_name($id) // return undef;
    return "Set-Cookie: $name=$cookie; Path=/; HttpOnly; SameSite=Strict; Max-Age=$VISITOR_MAX_AGE"
        . ( $o{secure} ? '; Secure' : '' );
}

1;

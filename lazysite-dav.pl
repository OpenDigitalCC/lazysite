#!/usr/bin/perl
# lazysite-dav.pl - WebDAV (class 1 + 2) publishing endpoint for
# lazysite. Self-contained CGI per the project's no-shared-modules
# policy: helpers shared in spirit with lazysite-auth.pl and
# lazysite-manager-api.pl (log_event, const_eq, verify_password,
# settings reader, blocked-path checks, cache invalidation, lock
# store) are duplicated here by convention - see
# docs/architecture/code-quality.md.
#
# Reached directly under /dav (its own ScriptAlias), NOT through
# lazysite-auth.pl: it performs its own HTTP Basic authentication and
# never reads cookies or X-Remote-* headers. Credentials are verified
# against lazysite/auth/users; access is governed by per-user
# settings in lazysite/auth/user-settings.json (webdav flag, dav_scope
# path restriction). See docs/feature-requests/SM070-webdav-publishing.md.
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use Digest::SHA qw(sha256_hex);
use Cwd qw(realpath);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX qw(strftime);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). No configuration needed.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util qw(log_event const_eq);
use Lazysite::Audit qw(audit_log);
use Lazysite::Auth::Acl qw(_acl_allows);
use Lazysite::Auth::Credential qw(verify_password);
use Lazysite::Auth::Settings qw(read_settings);
$Lazysite::Util::COMPONENT = 'dav';

my $DOCROOT = $ENV{DOCUMENT_ROOT} // $ENV{REDIRECT_DOCUMENT_ROOT};
my $LAZYSITE_DIR = defined $DOCROOT ? "$DOCROOT/lazysite" : undef;
$Lazysite::Audit::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Auth::Acl::DOCROOT  = $DOCROOT;
my $AUTH_DIR     = defined $DOCROOT ? "$LAZYSITE_DIR/auth" : undef;
my $LOCK_DIR     = defined $DOCROOT ? "$LAZYSITE_DIR/manager/locks" : undef;
my $DAV_RATE_DB  = defined $DOCROOT ? "$AUTH_DIR/.dav-rate.db" : undef;
$Lazysite::Auth::Settings::AUTH_DIR = $AUTH_DIR;

# Failed-auth rate limit (per IP), mirroring the login limiter (H-3).
my $RATE_MAX    = 5;       # failures per window
my $RATE_WINDOW = 300;     # seconds
my $FAIL_DELAY  = defined $ENV{LAZYSITE_DAV_FAIL_DELAY}
                  ? $ENV{LAZYSITE_DAV_FAIL_DELAY} : 2;

# Lock parameters.
my $LOCK_DEFAULT     = 300;     # seconds, when client asks for none
my $LOCK_MAX         = 3600;    # ceiling on any grant
my $MAX_LOCKS_USER   = 100;     # concurrent dav locks per user
my $OWNER_MAX        = 1024;    # bytes of client owner XML retained

my $PUT_CHUNK = 65536;

# SM019 download Content-Type table (duplicated from the manager API).
my %CONTENT_TYPE_MAP = (
    md    => 'text/plain; charset=utf-8',
    txt   => 'text/plain; charset=utf-8',
    html  => 'text/html; charset=utf-8',
    htm   => 'text/html; charset=utf-8',
    css   => 'text/css; charset=utf-8',
    js    => 'text/javascript; charset=utf-8',
    json  => 'application/json; charset=utf-8',
    jsonl => 'application/jsonl; charset=utf-8',
    xml   => 'application/xml; charset=utf-8',
    yaml  => 'text/yaml; charset=utf-8',
    yml   => 'text/yaml; charset=utf-8',
    csv   => 'text/csv; charset=utf-8',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    svg   => 'image/svg+xml',
    ico   => 'image/vnd.microsoft.icon',
    pdf   => 'application/pdf',
    zip   => 'application/zip',
);

my %REASON = (
    200 => 'OK', 201 => 'Created', 204 => 'No Content',
    207 => 'Multi-Status', 400 => 'Bad Request', 401 => 'Unauthorized',
    403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
    409 => 'Conflict', 412 => 'Precondition Failed',
    413 => 'Payload Too Large', 415 => 'Unsupported Media Type',
    423 => 'Locked', 429 => 'Too Many Requests',
    500 => 'Internal Server Error', 502 => 'Bad Gateway',
    503 => 'Service Unavailable', 507 => 'Insufficient Storage',
);

# Unit-test hook: a `do "lazysite-dav.pl"` with this set returns after
# the lexicals and subs are in place but before any request handling,
# so tests can call helpers (sanitise_path, parse_if_tokens, etc.)
# directly. No effect in normal CGI use.
return 1 if $ENV{LAZYSITE_DAV_LOAD_ONLY};

main();
exit 0;

# ---------------------------------------------------------------------
# Main request pipeline
# ---------------------------------------------------------------------

sub main {
    my $method = uc( $ENV{REQUEST_METHOD} // 'GET' );
    my $ip     = $ENV{REMOTE_ADDR} // '';

    unless ( defined $DOCROOT && length $DOCROOT ) {
        return send_status( 500, body => "DOCUMENT_ROOT not set\n" );
    }

    my $conf = read_conf();

    # 1. Site gate - feature off => the endpoint does not exist.
    unless ( is_truthy( $conf->{webdav_enabled} ) ) {
        return send_status( 404, body => "Not found\n" );
    }

    # 2. Transport gate - never accept Basic credentials over plaintext.
    my $loopback = ( $ip eq '127.0.0.1' || $ip eq '::1' );
    unless ( $ENV{HTTPS} || $loopback || is_truthy( $conf->{dav_allow_insecure} ) ) {
        log_event( 'WARN', '-', 'dav over plaintext refused', ip => $ip );
        return send_status( 403, body => "HTTPS required\n" );
    }

    # 3. Authentication (Basic), with a per-IP failed-attempt limiter.
    if ( dav_rate_blocked($ip) ) {
        log_event( 'WARN', '-', 'dav auth rate limit exceeded', ip => $ip );
        return send_status( 429, body => "Too many failed attempts\n" );
    }
    my ( $user, $pass ) = parse_basic_auth();
    unless ( defined $user ) {
        # No / malformed credentials: challenge, no rate penalty (this
        # is the normal first probe of any DAV client).
        return send_status( 401,
            headers => ['WWW-Authenticate: Basic realm="lazysite-dav"'],
            body    => "Authentication required\n" );
    }
    my $users = load_users();
    my $stored = $users->{$user};
    unless ( defined $stored && length $stored && verify_password( $pass, $stored ) ) {
        dav_rate_record($ip);
        sleep $FAIL_DELAY if $FAIL_DELAY;
        log_event( 'WARN', $user, 'dav auth failed', ip => $ip );
        return send_status( 401,
            headers => ['WWW-Authenticate: Basic realm="lazysite-dav"'],
            body    => "Authentication failed\n" );
    }

    # SM071 Phase 2: a disabled account is denied outright, ahead of the
    # mechanism gate.
    if ( disabled_for($user) ) {
        log_event( 'WARN', $user, 'dav access denied (account disabled)', ip => $ip );
        return send_status( 403, body => "Account disabled\n" );
    }

    # SM071 Phase 2: an expired access token must be rotated/re-exchanged.
    if ( token_expired($user) ) {
        log_event( 'WARN', $user, 'dav access denied (credential expired)', ip => $ip );
        return send_status( 401,
            headers => ['WWW-Authenticate: Basic realm="lazysite-dav"'],
            body    => "Credential expired\n" );
    }

    # 4. Mechanism gate - WebDAV must be enabled for this user.
    unless ( webdav_enabled_for($user) ) {
        log_event( 'WARN', $user, 'dav access denied (mechanism off)', ip => $ip );
        return send_status( 403, body => "WebDAV not enabled for this account\n" );
    }

    # OPTIONS advertises capabilities and touches no files.
    if ( $method eq 'OPTIONS' ) {
        return do_options();
    }

    # 5. Path resolution and authorisation.
    my $rel = sanitise_path( $ENV{PATH_INFO} // '' );
    unless ( defined $rel ) {
        return send_status( 400, body => "Bad request path\n" );
    }
    my $scope    = scope_for($user);
    my $is_write = ( $method =~ /^(?:PUT|DELETE|MKCOL|MOVE|COPY|LOCK)$/ );
    if ( my $code = authorise( $rel, $scope, $is_write, $conf, $user ) ) {
        log_event( 'WARN', $user, 'dav path denied', path => $rel, status => $code );
        return send_status( $code, body => "Forbidden\n" );
    }

    # SM071 Phase 3 (P3.6): per-token volume throttle on writes (a deploy
    # is many PUTs). 429 + Retry-After per the retry contract.
    if ($is_write) {
        my $rl = _rate_ok($user);
        unless ( $rl->{ok} ) {
            log_event( 'WARN', $user, 'dav rate limited', ip => $ip );
            return send_status( 429,
                headers => ["Retry-After: $rl->{retry_after}"],
                body    => "Rate limit exceeded\n" );
        }
    }

    # 6. Dispatch. Read methods return directly; state-changing methods have
    # their outcome captured and recorded to the shared audit trail (origin =
    # dav) so a partner's WebDAV writes are visible alongside the manager UI /
    # control-API entries.
    my %args = ( rel => $rel, user => $user, conf => $conf, scope => $scope, ip => $ip );
    if    ( $method eq 'PROPFIND' )  { return do_propfind(%args) }
    elsif ( $method eq 'PROPPATCH' ) { return do_proppatch(%args) }
    elsif ( $method eq 'GET' )       { return do_get( %args, head => 0 ) }
    elsif ( $method eq 'HEAD' )      { return do_get( %args, head => 1 ) }

    my $code;
    if    ( $method eq 'PUT' )    { $code = do_put(%args) }
    elsif ( $method eq 'MKCOL' )  { $code = do_mkcol(%args) }
    elsif ( $method eq 'DELETE' ) { $code = do_delete(%args) }
    elsif ( $method eq 'COPY' )   { $code = do_copy_move( %args, move => 0 ) }
    elsif ( $method eq 'MOVE' )   { $code = do_copy_move( %args, move => 1 ) }
    elsif ( $method eq 'LOCK' )   { return do_lock(%args) }
    elsif ( $method eq 'UNLOCK' ) { return do_unlock(%args) }
    else {
        return send_status( 405,
            headers => [ allow_header() ],
            body    => "Method not allowed\n" );
    }

    my $target = $rel;
    if ( $method eq 'MOVE' || $method eq 'COPY' ) {
        my $dest = destination_rel();
        $target .= ' -> ' . $dest if defined $dest;
    }
    audit_log( $user, lc($method), $target, $ip,
        ( defined $code && $code < 400 ? 'ok' : 'fail' ), 'dav' );
    return $code;
}

# ---------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------

sub do_options {
    send_response(
        200,
        headers => [
            'DAV: 1, 2',
            'MS-Author-Via: DAV',
            allow_header(),
            'Content-Length: 0',
        ],
    );
}

sub allow_header {
    return 'Allow: OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, '
         . 'MKCOL, COPY, MOVE, LOCK, UNLOCK';
}

sub do_propfind {
    my (%a) = @_;
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 404, body => "Not found\n" )
        if !$r->{parent_ok} || !-e $r->{abs};

    my $depth = $ENV{HTTP_DEPTH};
    $depth = '1' unless defined $depth;
    $depth =~ s/^\s+|\s+$//g;
    if ( lc($depth) eq 'infinity' ) {
        return send_status( 403, body => "Depth infinity not supported\n" );
    }
    $depth = ( $depth eq '0' ) ? 0 : 1;

    # P-perf: the lzs:sha256 live property means hashing each file, which is
    # expensive on a directory listing. Compute it only when the client asks
    # for it by name. Vanilla clients (davfs2, Finder, ...) send allprop /
    # propname and never request it, so they skip the hashing entirely - and
    # a custom dead property need not appear under allprop (RFC 4918).
    my $want_sha = ( read_request_body() =~ /sha256/ ) ? 1 : 0;

    my @blocks = prop_response( $a{rel}, $r->{abs}, $want_sha );
    if ( $depth == 1 && -d $r->{abs} ) {
        if ( opendir my $dh, $r->{abs} ) {
            my @kids = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;
            for my $kid (@kids) {
                my $krel = length $a{rel} ? "$a{rel}/$kid" : $kid;
                push @blocks, prop_response( $krel, "$r->{abs}/$kid", $want_sha );
            }
        }
    }

    my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n}
            . qq{<D:multistatus xmlns:D="DAV:" xmlns:lzs="urn:lazysite:dav">\n}
            . join( '', @blocks )
            . qq{</D:multistatus>\n};
    send_response( 207, type => 'application/xml; charset=utf-8', body => $xml );
}

# A single <D:response> for one resource.
sub prop_response {
    my ( $rel, $abs, $want_sha ) = @_;
    my @st = stat $abs;
    my $is_dir = -d _;
    my $href = href_for( $rel, $is_dir );
    my $name = xml_escape( length $rel ? ( split m{/}, $rel )[-1] : '' );
    my $mtime = $st[9] // 0;
    my $lastmod = strftime( '%a, %d %b %Y %H:%M:%S GMT', gmtime($mtime) );

    my $props = "        <D:displayname>$name</D:displayname>\n";
    if ($is_dir) {
        $props .= "        <D:resourcetype><D:collection/></D:resourcetype>\n";
    }
    else {
        my $size = $st[7] // 0;
        my $ct   = xml_escape( content_type_for($rel) );
        my $etag = etag_for( \@st );
        $props .= "        <D:resourcetype/>\n";
        $props .= "        <D:getcontentlength>$size</D:getcontentlength>\n";
        $props .= "        <D:getcontenttype>$ct</D:getcontenttype>\n";
        $props .= "        <D:getetag>$etag</D:getetag>\n";
        # SM071 Phase 3: content-hash manifest. A custom live property
        # gives a vanilla DAV client a content identity (not the weak
        # dev-ino-mtime-size ETag) for drift detection. Scoped to the
        # layouts subtree so content PROPFINDs are not made to hash files.
        if ( $want_sha && $rel =~ m{^lazysite/layouts/} ) {
            my $sha = file_sha256($abs);
            $props .= "        <lzs:sha256>$sha</lzs:sha256>\n" if defined $sha;
        }
    }
    $props .= "        <D:getlastmodified>$lastmod</D:getlastmodified>\n";
    $props .= "        <D:supportedlock>\n"
            . "          <D:lockentry><D:lockscope><D:exclusive/></D:lockscope>"
            . "<D:locktype><D:write/></D:locktype></D:lockentry>\n"
            . "        </D:supportedlock>\n";
    $props .= lockdiscovery_xml( read_lock($rel) );

    return "  <D:response>\n"
         . "    <D:href>$href</D:href>\n"
         . "    <D:propstat>\n"
         . "      <D:prop>\n"
         . $props
         . "      </D:prop>\n"
         . "      <D:status>HTTP/1.1 200 OK</D:status>\n"
         . "    </D:propstat>\n"
         . "  </D:response>\n";
}

sub do_proppatch {
    my (%a) = @_;
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 404, body => "Not found\n" )
        if !$r->{parent_ok} || !-e $r->{abs};

    # SM070 scope exclusion 3: no dead-property store. Property writes
    # are refused, spec-compliantly, with a per-property 403.
    my $href = href_for( $a{rel}, -d $r->{abs} );
    my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n}
            . qq{<D:multistatus xmlns:D="DAV:">\n}
            . "  <D:response>\n"
            . "    <D:href>$href</D:href>\n"
            . "    <D:propstat>\n"
            . "      <D:prop/>\n"
            . "      <D:status>HTTP/1.1 403 Forbidden</D:status>\n"
            . "    </D:propstat>\n"
            . "  </D:response>\n"
            . qq{</D:multistatus>\n};
    send_response( 207, type => 'application/xml; charset=utf-8', body => $xml );
}

sub do_get {
    my (%a) = @_;
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 404, body => "Not found\n" )
        if !$r->{parent_ok} || !-e $r->{abs};
    return send_status( 403, body => "Is a collection\n" ) if -d $r->{abs};

    open my $fh, '<:raw', $r->{abs}
        or return send_status( 404, body => "Not found\n" );
    my @st = stat $r->{abs};
    my $lastmod = strftime( '%a, %d %b %Y %H:%M:%S GMT', gmtime( $st[9] // 0 ) );
    print "Status: 200 OK\r\n";
    print "Content-Type: " . content_type_for( $a{rel} ) . "\r\n";
    print "Content-Length: " . ( $st[7] // 0 ) . "\r\n";
    print "ETag: " . etag_for( \@st ) . "\r\n";
    print "Last-Modified: $lastmod\r\n";
    print "\r\n";
    unless ( $a{head} ) {
        binmode STDOUT;
        my $buf;
        print $buf while read( $fh, $buf, $PUT_CHUNK );
    }
    close $fh;
}

sub do_put {
    my (%a) = @_;
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 409, body => "Parent collection missing\n" )
        unless $r->{parent_ok};
    return send_status( 405, body => "Cannot PUT a collection\n" )
        if -d $r->{abs};

    my $exists = -e $r->{abs};
    if ( my $code = check_conditionals( \@_, $r->{abs}, $exists, $a{rel} ) ) {
        return send_status( $code, body => "Precondition failed\n" );
    }
    if ( my $code = lock_blocks( $a{rel}, $a{user} ) ) {
        return send_status( $code, body => "Locked\n" );
    }

    # Size gate before reading the body.
    my $max = max_bytes( $a{conf} );
    my $clen = $ENV{CONTENT_LENGTH};
    if ( defined $clen && $clen =~ /^\d+$/ && $clen > $max ) {
        return send_status( 413, body => "Payload too large\n" );
    }

    my $tmp = "$r->{abs}.tmp.$$";
    open my $out, '>:raw', $tmp
        or return send_status( 500, body => "Cannot write\n" );
    binmode STDIN;
    my $written = 0;
    my $buf;
    my $remaining = ( defined $clen && $clen =~ /^\d+$/ ) ? $clen : undef;
    while ( 1 ) {
        my $want = $PUT_CHUNK;
        $want = $remaining if defined $remaining && $remaining < $want;
        last if defined $remaining && $remaining <= 0;
        my $n = read( STDIN, $buf, $want );
        last unless $n;
        $written += $n;
        if ( $written > $max ) {
            close $out; unlink $tmp;
            return send_status( 413, body => "Payload too large\n" );
        }
        print {$out} $buf;
        $remaining -= $n if defined $remaining;
    }
    unless ( close $out ) {
        unlink $tmp;
        return send_status( 500, body => "Write failed\n" );
    }
    unless ( rename $tmp, $r->{abs} ) {
        unlink $tmp;
        return send_status( 500, body => "Rename failed\n" );
    }

    invalidate_cache( $r->{abs} );
    log_event( 'INFO', $a{user}, 'dav put',
        path => $a{rel}, bytes => $written,
        status => ( $exists ? 204 : 201 ) );
    send_status( $exists ? 204 : 201 );
}

sub do_mkcol {
    my (%a) = @_;
    # A body on MKCOL is unsupported (no extended-mkcol).
    my $clen = $ENV{CONTENT_LENGTH} // 0;
    return send_status( 415, body => "Body not supported\n" )
        if $clen =~ /^\d+$/ && $clen > 0;

    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 409, body => "Parent collection missing\n" )
        unless $r->{parent_ok};
    return send_status( 405, body => "Already exists\n" ) if -e $r->{abs};

    unless ( mkdir $r->{abs} ) {
        return send_status( 409, body => "Cannot create collection\n" );
    }
    log_event( 'INFO', $a{user}, 'dav mkcol', path => $a{rel}, status => 201 );
    send_status(201);
}

sub do_delete {
    my (%a) = @_;
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    return send_status( 404, body => "Not found\n" )
        if !$r->{parent_ok} || !-e $r->{abs};

    if ( my $code = check_conditionals( \@_, $r->{abs}, 1, $a{rel} ) ) {
        return send_status( $code, body => "Precondition failed\n" );
    }
    if ( my $code = lock_blocks( $a{rel}, $a{user} ) ) {
        return send_status( $code, body => "Locked\n" );
    }

    my $ok;
    if ( -d $r->{abs} ) {
        remove_tree( $r->{abs}, { safe => 1, error => \my $err } );
        $ok = !-e $r->{abs};
    }
    else {
        $ok = unlink $r->{abs};
    }
    return send_status( 500, body => "Delete failed\n" ) unless $ok;

    remove_lock( $a{rel} );
    invalidate_cache( $r->{abs} );
    log_event( 'INFO', $a{user}, 'dav delete', path => $a{rel}, status => 204 );
    send_status(204);
}

sub do_copy_move {
    my (%a) = @_;
    my $move = $a{move};
    my $src  = resolve_under_docroot( $a{rel} );
    return send_status( $src->{err}, body => "Error\n" ) if $src->{err};
    return send_status( 404, body => "Not found\n" )
        if !$src->{parent_ok} || !-e $src->{abs};

    my $drel = destination_rel();
    return send_status( 400, body => "Bad Destination\n" ) unless defined $drel;

    # Destination passes the full authorisation chain too.
    if ( my $code = authorise( $drel, $a{scope}, 1, $a{conf}, $a{user} ) ) {
        return send_status( $code, body => "Forbidden destination\n" );
    }
    my $dst = resolve_under_docroot($drel);
    return send_status( $dst->{err}, body => "Error\n" ) if $dst->{err};
    return send_status( 409, body => "Destination parent missing\n" )
        unless $dst->{parent_ok};

    my $dst_exists = -e $dst->{abs};
    my $overwrite = $ENV{HTTP_OVERWRITE} // 'T';
    if ( $dst_exists && uc($overwrite) eq 'F' ) {
        return send_status( 412, body => "Destination exists\n" );
    }

    # Lock checks: destination is written by both; source is removed by MOVE.
    if ( my $code = lock_blocks( $drel, $a{user} ) ) {
        return send_status( $code, body => "Destination locked\n" );
    }
    if ( $move && ( my $code = lock_blocks( $a{rel}, $a{user} ) ) ) {
        return send_status( $code, body => "Source locked\n" );
    }

    if ( $dst_exists ) {
        if ( -d $dst->{abs} ) { remove_tree( $dst->{abs}, { safe => 1 } ) }
        else                  { unlink $dst->{abs} }
    }

    my $ok;
    if ($move) {
        $ok = rename( $src->{abs}, $dst->{abs} );
        if ( !$ok ) {    # cross-device: copy then remove
            $ok = copy_tree( $src->{abs}, $dst->{abs} );
            if ($ok) {
                if ( -d $src->{abs} ) { remove_tree( $src->{abs}, { safe => 1 } ) }
                else                  { unlink $src->{abs} }
            }
        }
        remove_lock( $a{rel} ) if $ok;
    }
    else {
        $ok = copy_tree( $src->{abs}, $dst->{abs} );
    }
    return send_status( 500, body => "Operation failed\n" ) unless $ok;

    invalidate_cache( $src->{abs} ) if $move;
    invalidate_cache( $dst->{abs} );
    log_event( 'INFO', $a{user}, ( $move ? 'dav move' : 'dav copy' ),
        path => $a{rel}, dest => $drel,
        status => ( $dst_exists ? 204 : 201 ) );
    send_status( $dst_exists ? 204 : 201 );
}

# ---------------------------------------------------------------------
# Locking (class 2)
# ---------------------------------------------------------------------

sub do_lock {
    my (%a) = @_;
    my $depth = $ENV{HTTP_DEPTH};
    $depth = '0' unless defined $depth;
    $depth =~ s/^\s+|\s+$//g;
    return send_status( 403, body => "Only Depth 0 locks supported\n" )
        if lc($depth) eq 'infinity' || $depth eq '1';

    my $body = read_request_body();
    my $existing = read_lock( $a{rel} );

    # Refresh: empty body + an If header carrying the current token.
    if ( !length $body ) {
        return send_status( 400, body => "Missing lock body\n" )
            unless $existing;
        my @tokens = parse_if_tokens( $ENV{HTTP_IF} // '' );
        unless ( $existing->{origin} eq 'dav'
                 && grep { $_ eq $existing->{token} } @tokens ) {
            return send_status( 423, body => "Lock token required to refresh\n" );
        }
        $existing->{at}      = time();
        $existing->{timeout} = grant_timeout();
        write_lock( $a{rel}, $existing );
        return lock_ok( $a{rel}, $existing );
    }

    return send_status( 403, body => "Only exclusive locks supported\n" )
        if $body =~ /<\s*(?:\w+:)?shared\b/i;

    # A live lock held by someone else (or a manager session) blocks.
    if ($existing) {
        my @tokens = parse_if_tokens( $ENV{HTTP_IF} // '' );
        my $own = ( $existing->{origin} eq 'dav'
                    && $existing->{user} eq $a{user}
                    && grep { $_ eq $existing->{token} } @tokens );
        return send_status( 423, body => "Already locked\n" ) unless $own;
    }

    # Per-user lock flood guard.
    if ( !$existing && count_user_locks( $a{user} ) >= $MAX_LOCKS_USER ) {
        log_event( 'WARN', $a{user}, 'dav lock flood guard', path => $a{rel} );
        return send_status( 503, body => "Too many locks\n" );
    }

    # LOCK on an unmapped URL creates an empty resource, after the full
    # write-path authorisation already run in main().
    my $r = resolve_under_docroot( $a{rel} );
    return send_status( $r->{err}, body => "Error\n" ) if $r->{err};
    my $created = 0;
    unless ( -e $r->{abs} ) {
        return send_status( 409, body => "Parent collection missing\n" )
            unless $r->{parent_ok};
        open my $fh, '>:raw', $r->{abs}
            or return send_status( 500, body => "Cannot create\n" );
        close $fh;
        $created = 1;
    }

    my $owner = extract_owner($body);
    my $rec = {
        user    => $a{user},
        at      => time(),
        origin  => 'dav',
        token   => 'opaquelocktoken:' . make_uuid(),
        timeout => grant_timeout(),
        owner   => $owner,
    };
    write_lock( $a{rel}, $rec );
    log_event( 'INFO', $a{user}, 'dav lock', path => $a{rel} );
    lock_ok( $a{rel}, $rec, created => $created );
}

sub do_unlock {
    my (%a) = @_;
    my $hdr = $ENV{HTTP_LOCK_TOKEN} // '';
    my ($token) = $hdr =~ /<([^>]+)>/;
    return send_status( 400, body => "Missing Lock-Token\n" )
        unless defined $token && length $token;

    my $lock = read_lock( $a{rel} );
    return send_status( 409, body => "No such lock\n" )
        unless $lock && $lock->{origin} eq 'dav' && $lock->{token} eq $token;
    return send_status( 403, body => "Not the lock owner\n" )
        unless $lock->{user} eq $a{user};

    remove_lock( $a{rel} );
    log_event( 'INFO', $a{user}, 'dav unlock', path => $a{rel} );
    send_status(204);
}

# Does a live lock block a write to $rel by $user? Returns 423 or undef.
sub lock_blocks {
    my ( $rel, $user ) = @_;
    my $lock = read_lock($rel);
    return undef unless $lock;                       # unlocked
    return 423 if $lock->{origin} ne 'dav';          # manager lock: opaque
    my @tokens = parse_if_tokens( $ENV{HTTP_IF} // '' );
    return undef if grep { $_ eq $lock->{token} } @tokens;
    return 423;
}

sub lock_ok {
    my ( $rel, $rec, %o ) = @_;
    my $body = qq{<?xml version="1.0" encoding="utf-8"?>\n}
             . qq{<D:prop xmlns:D="DAV:">\n}
             . "  <D:lockdiscovery>\n"
             . activelock_xml($rec)
             . "  </D:lockdiscovery>\n"
             . qq{</D:prop>\n};
    send_response(
        ( $o{created} ? 201 : 200 ),
        type    => 'application/xml; charset=utf-8',
        headers => [ "Lock-Token: <$rec->{token}>" ],
        body    => $body,
    );
}

sub lockdiscovery_xml {
    my ($rec) = @_;
    return "        <D:lockdiscovery/>\n" unless $rec;
    return "        <D:lockdiscovery>\n"
         . activelock_xml($rec)
         . "        </D:lockdiscovery>\n";
}

sub activelock_xml {
    my ($rec) = @_;
    my $owner = defined $rec->{owner} && length $rec->{owner}
        ? "      <D:owner>" . xml_escape( $rec->{owner} ) . "</D:owner>\n" : '';
    my $remain = ( $rec->{at} + $rec->{timeout} ) - time();
    $remain = 0 if $remain < 0;
    return "    <D:activelock>\n"
         . "      <D:locktype><D:write/></D:locktype>\n"
         . "      <D:lockscope><D:exclusive/></D:lockscope>\n"
         . "      <D:depth>0</D:depth>\n"
         . $owner
         . "      <D:timeout>Second-$remain</D:timeout>\n"
         . "      <D:locktoken><D:href>" . xml_escape( $rec->{token} )
         . "</D:href></D:locktoken>\n"
         . "    </D:activelock>\n";
}

sub grant_timeout {
    my $req = $ENV{HTTP_TIMEOUT} // '';
    for my $part ( split /\s*,\s*/, $req ) {
        if ( $part =~ /^Second-(\d+)$/i ) {
            my $s = $1;
            return $s > $LOCK_MAX ? $LOCK_MAX : $s;
        }
        return $LOCK_MAX if $part =~ /^Infinite$/i;
    }
    return $LOCK_DEFAULT;
}

sub extract_owner {
    my ($body) = @_;
    return '' unless $body =~ m{<\s*(?:\w+:)?owner\b[^>]*>(.*?)</\s*(?:\w+:)?owner\s*>}is;
    my $owner = $1;
    $owner = substr( $owner, 0, $OWNER_MAX ) if length $owner > $OWNER_MAX;
    return $owner;
}

sub make_uuid {
    my @b = unpack( 'C16', random_bytes(16) );
    $b[6] = ( $b[6] & 0x0f ) | 0x40;    # version 4
    $b[8] = ( $b[8] & 0x3f ) | 0x80;    # RFC 4122 variant
    my $h = unpack( 'H*', pack( 'C16', @b ) );
    return join '-', substr( $h, 0, 8 ), substr( $h, 8, 4 ),
        substr( $h, 12, 4 ), substr( $h, 16, 4 ), substr( $h, 20, 12 );
}

# ---------------------------------------------------------------------
# Lock store (shared format with lazysite-manager-api.pl)
# ---------------------------------------------------------------------
#
# One file per resource at $LOCK_DIR/<key>.lock, key = rel with '/'
# replaced by ':'. Content is a JSON record:
#   {"user","at","origin":"dav"|"manager","token","timeout","owner"}
# A legacy single-line "user epoch" file (pre-SM070 manager locks) is
# read as an origin=manager record with the default timeout.

sub lock_file_for {
    my ($rel) = @_;
    ( my $key = $rel ) =~ s{/}{:}g;
    return "$LOCK_DIR/$key.lock";
}

sub read_lock {
    my ($rel) = @_;
    my $file = lock_file_for($rel);
    return undef unless -f $file;
    open my $fh, '<', $file or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $rec = parse_lock_record($raw);
    return undef unless $rec;
    my $age = time() - ( $rec->{at} // 0 );
    if ( $age >= ( $rec->{timeout} // $LOCK_DEFAULT ) ) {
        unlink $file;    # expired: opportunistic sweep
        return undef;
    }
    return $rec;
}

sub parse_lock_record {
    my ($raw) = @_;
    return undef unless defined $raw;
    $raw =~ s/^\s+//;
    if ( $raw =~ /^\{/ ) {
        require JSON::PP;
        my $rec = eval { JSON::PP::decode_json($raw) };
        return undef unless ref $rec eq 'HASH';
        $rec->{origin}  ||= 'manager';
        $rec->{timeout} ||= $LOCK_DEFAULT;
        return $rec;
    }
    # Legacy "user epoch" line.
    my ( $user, $at ) = split /\s+/, $raw, 2;
    return undef unless defined $user;
    $at //= 0;
    $at =~ s/\D.*$//;
    return { user => $user, at => ( $at || 0 ), origin => 'manager',
             timeout => $LOCK_DEFAULT, token => undef, owner => '' };
}

sub write_lock {
    my ( $rel, $rec ) = @_;
    make_path($LOCK_DIR) unless -d $LOCK_DIR;
    require JSON::PP;
    my $file = lock_file_for($rel);
    my $tmp  = "$file.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print $fh JSON::PP->new->canonical->encode($rec);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $file;
}

sub remove_lock {
    my ($rel) = @_;
    my $file = lock_file_for($rel);
    unlink $file if -f $file;
}

sub count_user_locks {
    my ($user) = @_;
    return 0 unless -d $LOCK_DIR;
    opendir my $dh, $LOCK_DIR or return 0;
    my @files = grep { /\.lock$/ } readdir $dh;
    closedir $dh;
    my $n = 0;
    for my $f (@files) {
        open my $fh, '<', "$LOCK_DIR/$f" or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $rec = parse_lock_record($raw) or next;
        next unless ( $rec->{origin} // '' ) eq 'dav'
                 && ( $rec->{user} // '' ) eq $user;
        next if time() - ( $rec->{at} // 0 ) >= ( $rec->{timeout} // $LOCK_DEFAULT );
        $n++;
    }
    return $n;
}

# ---------------------------------------------------------------------
# Conditionals
# ---------------------------------------------------------------------

sub check_conditionals {
    my ( undef, $abs, $exists, $rel ) = @_;
    my $im  = $ENV{HTTP_IF_MATCH};
    my $inm = $ENV{HTTP_IF_NONE_MATCH};
    my $etag = $exists && -f $abs ? etag_for( [ stat $abs ] ) : undef;

    if ( defined $im ) {
        $im =~ s/^\s+|\s+$//g;
        if ( $im eq '*' ) { return 412 unless $exists }
        else {
            return 412 unless defined $etag && etag_in_list( $etag, $im );
        }
    }
    if ( defined $inm ) {
        $inm =~ s/^\s+|\s+$//g;
        if ( $inm eq '*' ) { return 412 if $exists }
        else {
            return 412 if defined $etag && etag_in_list( $etag, $inm );
        }
    }
    return undef;
}

sub etag_in_list {
    my ( $etag, $list ) = @_;
    for my $t ( split /\s*,\s*/, $list ) {
        $t =~ s/^\s+|\s+$//g;
        $t =~ s/^W\///;    # weak-tag marker, ignored
        return 1 if $t eq $etag;
    }
    return 0;
}

# ---------------------------------------------------------------------
# Authorisation chain
# ---------------------------------------------------------------------

# Clean PATH_INFO into a docroot-relative path with no leading slash.
# PATH_INFO arrives already %-decoded from the web server, so it is NOT
# decoded again here (double-decoding would re-open traversal). Returns
# undef on a rejected path.
sub sanitise_path {
    my ($path) = @_;
    $path = '' unless defined $path;
    return undef if $path =~ /\0/;            # null byte
    return undef if $path =~ /[\x00-\x1f]/;   # control chars
    $path =~ s{^/+}{};                        # strip leading slashes
    $path =~ s{/+$}{};                        # strip trailing slashes
    return '' if $path eq '';
    for my $seg ( split m{/}, $path ) {
        return undef if $seg eq '..';         # traversal
    }
    return $path;
}

# SM074/SM077: per-file ACLs live in lazysite/auth/acls.json (set through the
# control API, never a raw PUT; the dav only reads). The owner/allowlist + the
# @group rules are delegated to the shared Lazysite::Auth::Acl so WebDAV
# enforces exactly what the manager and MCP do - previously a private copy here
# silently ignored @group entries.

# The user's group memberships, read from lazysite/auth/groups (for @group
# ACLs). WebDAV has no X-Remote-Groups, so it resolves them from the store.
sub user_groups_for {
    my ($user) = @_;
    return () unless defined $user && defined $LAZYSITE_DIR;
    my $gf = "$LAZYSITE_DIR/auth/groups";
    return () unless -f $gf;
    open my $fh, '<', $gf or return ();
    my @groups;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $g, $members ) = split /:\s*/, $_, 2;
        next unless defined $members;
        for my $m ( split /,/, $members ) {
            $m =~ s/^\s+|\s+$//g;
            push @groups, $g if $m eq $user;
        }
    }
    close $fh;
    return @groups;
}

# 1 if $user may access $rel in $mode ('read'|'write'); delegates to the shared
# allow check with the user's groups in scope (so @group entries match).
sub acl_allows {
    my ( $rel, $mode, $user ) = @_;
    local @Lazysite::Auth::Acl::user_groups = user_groups_for($user);
    return _acl_allows( $rel, $mode, $user ) ? 1 : 0;
}

# Returns an HTTP error code if denied, or undef if allowed.
sub authorise {
    my ( $rel, $scope, $is_write, $conf, $user ) = @_;

    # SM072: lazysite/nav.conf is agent-editable over WebDAV, gated by
    # manage_config. Nav is benign structure - no more powerful than the
    # content pages a webdav account can already publish - and carries no
    # privilege-escalation keys, unlike lazysite.conf which stays denied.
    if ( $rel eq 'lazysite/nav.conf' ) {
        return manage_config_for($user) ? undef : 403;
    }

    # A per-form dispatch config (lazysite/forms/<name>.conf) is agent-editable
    # over WebDAV, gated by manage_config: it only names which operator-defined
    # handlers a form dispatches to, never credentials. The secret files -
    # smtp.conf (SMTP creds), handlers.conf (handler definitions, addresses,
    # webhook URLs), .smtp-password - and the submissions store stay denied,
    # so an agent can wire a form to file storage but cannot read creds, add
    # handlers, or read submissions.
    if ( $rel =~ m{^lazysite/forms/([A-Za-z0-9_-]+)\.conf$} ) {
        my $name = $1;
        return 403 if $name eq 'smtp' || $name eq 'handlers';
        return manage_config_for($user) ? undef : 403;
    }

    # SM071 Phase 3: the one carve-out from the whole-lazysite/ denial is
    # theme/layout authoring under lazysite/layouts/**, governed per object
    # by the manage_themes / manage_layouts capabilities and the active
    # pointers. Everything else under lazysite/ stays denied.
    if ( $rel eq 'lazysite' || $rel =~ m{^lazysite/} ) {
        return authorise_layout( $rel, $is_write, $conf, $user );
    }

    # Content namespace: scope confinement + write blocklist (unchanged).
    if ( defined $scope && length $scope ) {
        ( my $s = $scope ) =~ s{^/+|/+$}{}g;
        if ( length $s ) {
            return 403 unless $rel eq $s || index( $rel, "$s/" ) == 0;
        }
    }

    # Apply the blocklist on READS as well as writes - otherwise an unscoped
    # account could GET the source of cgi-bin/*.pl (the blocklist's own
    # cgi-bin / manager entries imply these are meant to be unreachable).
    return 403 if is_blocked( $rel, $conf );

    # SM074: per-file ACLs (content namespace; the lazysite/ subtree returned
    # earlier). Ownership + read/write lists come from the central store.
    return 403
        unless acl_allows( $rel, ( $is_write ? 'write' : 'read' ), $user );

    return undef;
}

# SM071 Phase 3: per-object authorisation for the lazysite/layouts/** tree.
# Returns 403 (deny) or undef (allow). dav_scope is a content-namespace
# control and does not apply here - theme/layout reachability is governed
# solely by the capabilities and the active-pointer read-only rule.
sub authorise_layout {
    my ( $rel, $is_write, $conf, $user ) = @_;

    my $can_themes  = manage_themes_for($user);
    my $can_layouts = manage_layouts_for($user);
    return 403 unless $can_themes || $can_layouts;

    # Only the layouts subtree is reachable; the rest of lazysite/ is denied.
    return 403 unless $rel eq 'lazysite/layouts'
                   || $rel =~ m{^lazysite/layouts/};

    my $active_layout = $conf->{active_layout} // '';
    my $active_theme  = $conf->{active_theme}  // '';

    # The all-layouts container: read-only navigation with either capability.
    return ( $is_write ? 403 : undef ) if $rel eq 'lazysite/layouts';

    my ( $layout, $rest ) = $rel =~ m{^lazysite/layouts/([^/]+)(?:/(.*))?$};
    return 403 unless defined $layout;
    $rest //= '';

    # A theme path: lazysite/layouts/<L>/themes/<T>/...
    if ( $rest =~ m{^themes/([^/]+)} ) {
        my $theme = $1;
        return 403 unless $can_themes;
        return 403 if $is_write
                   && $layout eq $active_layout && $theme eq $active_theme;
        return undef;
    }

    # The layout dir or its themes/ container: structural. Readable with
    # either capability (navigation); writing structure needs manage_layouts
    # and the layout must not be the active one.
    if ( $rest eq '' || $rest eq 'themes' ) {
        return undef unless $is_write;
        return 403 unless $can_layouts;
        return 403 if $layout eq $active_layout;
        return undef;
    }

    # layout.tt and other layout-level assets.
    return 403 unless $can_layouts;
    return 403 if $is_write && $layout eq $active_layout;
    return undef;
}

sub manage_themes_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return ( ref $s eq 'HASH' && $s->{manage_themes} ) ? 1 : 0;
}

sub manage_layouts_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return ( ref $s eq 'HASH' && $s->{manage_layouts} ) ? 1 : 0;
}

sub manage_config_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return ( ref $s eq 'HASH' && $s->{manage_config} ) ? 1 : 0;
}

sub is_blocked {
    my ( $rel, $conf ) = @_;
    return 1 if $rel =~ /\.pl$/;    # is_blocked_path parity
    for my $p ( @{ $conf->{blocked_paths} || [] } ) {
        return 1 if $rel eq $p || index( $rel, "$p/" ) == 0;
    }
    my ($ext) = $rel =~ /\.([^.\/]+)$/;
    if ( defined $ext ) {
        $ext = lc $ext;
        for my $b ( @{ $conf->{blocked_extensions} || [] } ) {
            return 1 if $ext eq lc $b;
        }
    }
    return 0;
}

# ---------------------------------------------------------------------
# Filesystem resolution
# ---------------------------------------------------------------------

sub resolve_under_docroot {
    my ($rel) = @_;
    my $droot = realpath($DOCROOT);
    return { err => 500 } unless defined $droot;
    if ( !length $rel ) {
        return { abs => $droot, parent => $droot, parent_ok => 1 };
    }
    my $abs = "$droot/$rel";
    ( my $parent = $abs ) =~ s{/[^/]*$}{};
    my $base = ( split m{/}, $rel )[-1];
    my $rp = realpath($parent);
    # realpath() resolves the existing prefix and appends a missing
    # trailing component without erroring, so an existence check on the
    # resolved parent is required to detect a genuinely-missing parent.
    return { abs => $abs, parent => $parent, parent_ok => 0 }
        unless defined $rp && -d $rp;
    return { err => 403 }
        unless $rp eq $droot || index( $rp, "$droot/" ) == 0;
    my $full = "$rp/$base";
    if ( -e $full ) {
        my $tr = realpath($full);
        return { err => 403 }
            unless defined $tr && ( $tr eq $droot || index( $tr, "$droot/" ) == 0 );
        $full = $tr;
    }
    return { abs => $full, parent => $rp, parent_ok => 1 };
}

# Parse the Destination header (COPY/MOVE) into a docroot-relative path
# under our /dav mount, or undef. The header value IS url-encoded (it
# is a header, not server-decoded PATH_INFO), so it is decoded here.
sub destination_rel {
    my $dest = $ENV{HTTP_DESTINATION};
    return undef unless defined $dest && length $dest;
    $dest =~ s{^\s+|\s+$}{}g;
    $dest =~ s{^[a-zA-Z][\w+.-]*://[^/]+}{};    # strip scheme://host
    my $prefix = script_prefix();
    return undef unless $dest eq $prefix || index( $dest, "$prefix/" ) == 0;
    my $path = substr( $dest, length $prefix );
    $path =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;    # url-decode
    return sanitise_path($path);
}

# ---------------------------------------------------------------------
# Cache invalidation (mirrors action_save / action_delete)
# ---------------------------------------------------------------------

sub invalidate_cache {
    my ($abs) = @_;
    return unless $abs =~ /\.md$/;
    ( my $cache = $abs ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;
}

# ---------------------------------------------------------------------
# Authentication and per-user settings
# ---------------------------------------------------------------------

sub parse_basic_auth {
    my $h = $ENV{HTTP_AUTHORIZATION} // $ENV{REDIRECT_HTTP_AUTHORIZATION} // '';
    return ( undef, undef ) unless $h =~ /^Basic\s+(\S+)/i;
    my $decoded = eval { decode_base64($1) };
    return ( undef, undef ) unless defined $decoded && $decoded =~ /:/;
    my ( $user, $pass ) = split /:/, $decoded, 2;
    return ( undef, undef ) unless defined $user && length $user;
    return ( $user, $pass );
}

sub load_users {
    my $path = "$AUTH_DIR/users";
    my %users;
    return \%users unless -f $path;
    open my $fh, '<:utf8', $path or return \%users;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $u, $h ) = split /:/, $_, 2;
        $users{$u} = $h if defined $u && defined $h;
    }
    close $fh;
    return \%users;
}

# H-2 verify (duplicated): both salted-iterated and legacy formats.



sub webdav_enabled_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return ( ref $s eq 'HASH' && $s->{webdav} ) ? 1 : 0;
}

# SM071 Phase 3 (P3.6): per-token volume token-bucket, shared with the
# control API (same store + format under auth/, keyed by user). Defaults
# burst 200 / refill 20/s, env-overridable. Fails open on any IO error.
sub _rate_ok {
    my ($key) = @_;
    my $burst = defined $ENV{LAZYSITE_RATE_BURST}  ? $ENV{LAZYSITE_RATE_BURST}  : 200;
    my $rate  = defined $ENV{LAZYSITE_RATE_REFILL} ? $ENV{LAZYSITE_RATE_REFILL} : 20;
    return { ok => 1 } if $burst <= 0;
    my $path = "$AUTH_DIR/.token-rate.json";
    sysopen( my $fh, $path, O_RDWR | O_CREAT, 0600 ) or return { ok => 1 };
    flock( $fh, LOCK_EX );
    my $raw  = do { local $/; <$fh> };
    my $data = eval { JSON::PP::decode_json( $raw || '{}' ) };
    $data = {} unless ref $data eq 'HASH';
    my $now    = time();
    my $b      = $data->{$key} || { tokens => $burst, last => $now };
    my $tokens = $b->{tokens} + ( $now - ( $b->{last} // $now ) ) * $rate;
    $tokens = $burst if $tokens > $burst;
    my ( $allow, $retry ) = ( 0, 0 );
    if ( $tokens >= 1 ) { $tokens -= 1; $allow = 1 }
    else { $retry = $rate > 0 ? int( ( 1 - $tokens ) / $rate ) + 1 : 60 }
    $data->{$key} = { tokens => $tokens, last => $now };
    seek( $fh, 0, 0 ); truncate( $fh, 0 ); print $fh JSON::PP::encode_json($data);
    flock( $fh, LOCK_UN ); close $fh;
    return $allow ? { ok => 1 } : { ok => 0, retry_after => $retry };
}

# SM071 Phase 2: a disabled account fails all DAV access.
sub disabled_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return ( ref $s eq 'HASH' && $s->{disabled} ) ? 1 : 0;
}

# SM071 Phase 2: an access token past its expiry is invalid (a password
# or permanent credential has no token_expires_at, so this never trips).
sub token_expired {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return 0 unless ref $s eq 'HASH' && $s->{token_expires_at};
    return time() > $s->{token_expires_at} ? 1 : 0;
}

sub scope_for {
    my ($user) = @_;
    my $s = read_settings()->{$user};
    return undef unless ref $s eq 'HASH';
    my $scope = $s->{dav_scope};
    return ( defined $scope && length $scope ) ? $scope : undef;
}

# ---------------------------------------------------------------------
# Rate limiting (per IP, failed attempts), mirroring the H-3 limiter
# ---------------------------------------------------------------------

sub dav_rate_blocked {
    my ($ip) = @_;
    return 0 unless $ip;
    my %db;
    eval { require DB_File; 1 } or return 0;
    eval { tie %db, 'DB_File', $DAV_RATE_DB, O_CREAT | O_RDWR, 0o600 };
    return 0 if $@ || !tied %db;
    my $window = int( time() / $RATE_WINDOW );
    my $count = $db{"$ip:$window"} // 0;
    untie %db;
    return $count >= $RATE_MAX ? 1 : 0;
}

sub dav_rate_record {
    my ($ip) = @_;
    return unless $ip;
    my %db;
    eval { require DB_File; 1 } or return;
    eval { tie %db, 'DB_File', $DAV_RATE_DB, O_CREAT | O_RDWR, 0o600 };
    return if $@ || !tied %db;
    my $window = int( time() / $RATE_WINDOW );
    $db{"$ip:$window"} = ( $db{"$ip:$window"} // 0 ) + 1;
    for my $k ( keys %db ) {
        delete $db{$k} if $k =~ /:(\d+)\z/ && $1 < $window - 1;
    }
    untie %db;
}

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

sub read_conf {
    my %c = (
        webdav_enabled     => 0,
        dav_allow_insecure => 0,
        max_bytes          => 10 * 1024 * 1024,
        active_layout      => '',   # SM071 Phase 3: theme/layout pointers
        active_theme       => '',
        blocked_paths      => [ qw(
            lazysite/auth lazysite/forms lazysite/cache
            lazysite/manager cgi-bin manager
        ) ],
        blocked_extensions => [ qw(pl cgi) ],
    );
    my $path = "$LAZYSITE_DIR/lazysite.conf";
    return \%c unless -f $path;
    open my $fh, '<', $path or return \%c;
    while (<$fh>) {
        if    ( /^webdav_enabled\s*:\s*(\S+)/ )     { $c{webdav_enabled}     = $1 }
        elsif ( /^dav_allow_insecure\s*:\s*(\S+)/ ) { $c{dav_allow_insecure} = $1 }
        elsif ( /^layout\s*:\s*(\S+)/ )             { $c{active_layout}      = $1 }
        elsif ( /^theme\s*:\s*(\S+)/ )              { $c{active_theme}       = $1 }
        elsif ( /^manager_upload_max_mb\s*:\s*(\d+)/ && $1 > 0 ) {
            $c{max_bytes} = $1 * 1024 * 1024;
        }
        elsif ( /^manager_blocked_paths\s*:\s*(.+)/ ) {
            my $v = $1; $v =~ s/\s+$//;
            $c{blocked_paths} = [ map { s{^/+|/+$}{}gr } grep { length }
                split /\s*,\s*/, $v ] if length $v;
        }
        elsif ( /^manager_upload_blocked_extensions\s*:\s*(.+)/ ) {
            my $v = $1; $v =~ s/\s+$//;
            $c{blocked_extensions} = [ map { lc } grep { length }
                split /\s*,\s*/, $v ] if length $v;
        }
    }
    close $fh;
    return \%c;
}

sub max_bytes { return $_[0]->{max_bytes} }

sub is_truthy {
    my ($v) = @_;
    return 0 unless defined $v;
    $v = lc $v;
    return ( $v eq '1' || $v eq 'true' || $v eq 'yes'
          || $v eq 'on' || $v eq 'enabled' ) ? 1 : 0;
}

# ---------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------

sub random_bytes {
    my ($n) = @_;
    open my $fh, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom: $!\n";
    my $buf = '';
    my $got = read( $fh, $buf, $n );
    close $fh;
    die "Short read from /dev/urandom\n" unless defined $got && $got == $n;
    return $buf;
}

sub etag_for {
    my ($st) = @_;
    my ( $dev, $ino, $mtime, $size ) = ( $st->[0], $st->[1], $st->[9], $st->[7] );
    return sprintf( '"%x-%x-%x-%x"', $dev // 0, $ino // 0, $mtime // 0, $size // 0 );
}

# SM071 Phase 3: content SHA-256 of a file (the manifest identity).
sub file_sha256 {
    my ($abs) = @_;
    open my $fh, '<:raw', $abs or return undef;
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    close $fh;
    return $sha->hexdigest;
}

sub content_type_for {
    my ($rel) = @_;
    my ($ext) = $rel =~ /\.([^.\/]+)$/;
    $ext = lc( $ext // '' );
    return $CONTENT_TYPE_MAP{$ext} // 'application/octet-stream';
}

sub script_prefix {
    my $p = $ENV{SCRIPT_NAME} // '/dav';
    $p =~ s{/+$}{};
    $p = '/dav' unless length $p;
    return $p;
}

sub href_for {
    my ( $rel, $is_dir ) = @_;
    my $href = script_prefix();
    $href .= '/' . uri_escape_path($rel) if length $rel;
    $href .= '/' if $is_dir && $href !~ m{/$};
    return xml_escape($href);
}

sub uri_escape_path {
    my ($path) = @_;
    my @out;
    for my $seg ( split m{/}, $path, -1 ) {
        $seg =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;
        push @out, $seg;
    }
    return join '/', @out;
}

sub xml_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&apos;/g;
    return $s;
}

sub parse_if_tokens {
    my ($if) = @_;
    return () unless defined $if;
    my @tokens;
    push @tokens, $1 while $if =~ /<(opaquelocktoken:[^>]+)>/g;
    return @tokens;
}

sub read_request_body {
    my $len = $ENV{CONTENT_LENGTH};
    return '' unless defined $len && $len =~ /^\d+$/ && $len > 0;
    my $body = '';
    binmode STDIN;
    read( STDIN, $body, $len );
    return $body;
}

sub copy_tree {
    my ( $src, $dst ) = @_;
    if ( -d $src ) {
        make_path($dst) unless -d $dst;
        opendir my $dh, $src or return 0;
        my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $k (@kids) {
            copy_tree( "$src/$k", "$dst/$k" ) or return 0;
        }
        return 1;
    }
    return copy( $src, $dst );
}

# ---------------------------------------------------------------------
# Response emission
# ---------------------------------------------------------------------

sub send_status {
    my ( $code, %o ) = @_;
    send_response( $code, %o );
}

sub send_response {
    my ( $code, %o ) = @_;
    my $reason = $REASON{$code} // 'Status';
    binmode( STDOUT, ':utf8' );
    print "Status: $code $reason\r\n";
    # SM071 Phase 3 (P3.6): the retry contract - 423 (locked) and 429
    # (throttled) always carry a Retry-After so clients back off.
    my @headers = @{ $o{headers} || [] };
    if ( ( $code == 423 || $code == 429 )
         && !grep { /^Retry-After:/i } @headers ) {
        push @headers, 'Retry-After: 30';
    }
    for my $h (@headers) {
        print "$h\r\n";
    }
    if ( defined $o{body} ) {
        my $type = $o{type} // 'text/plain; charset=utf-8';
        print "Content-Type: $type\r\n";
        print "\r\n";
        print $o{body};
    }
    else {
        print "\r\n";
    }
    return $code;    # so main() can audit write outcomes
}

# ---------------------------------------------------------------------
# Logging (duplicated)
# ---------------------------------------------------------------------



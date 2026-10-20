package MaintenanceRig;

# SM1118: the site, the signed cookies and the response reader the maintenance
# tests share (t/integration/315-320).
#
# A real site on disk - accounts, groups, a secret, pages, the shipped system
# pages - and requests made the way a front end makes them: through the real
# auth wrapper (lazysite-auth.pl, which verifies the cookie and execs the
# processor), straight to the processor (what the split templates do for a
# visitor with no cookie), or to a one-rule pool worker over FastCGI. Nothing here
# stands in for the decision under test: who is let through is read from the
# groups store by the engine's own readers.
#
# THE ACCOUNTS
#   boss   holds maintenance_access (and `ui`): the operator
#   alice  a signed-in member holding other capabilities, not that one
#   bob    a signed-in member holding nothing
use strict;
use warnings;
use Exporter 'import';
use File::Path  qw(make_path);
use File::Copy  ();
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use TestHelper qw(repo_root site_tempdir grant_caps env_passthrough);
our @EXPORT_OK = qw(build_site cookie_for spit slurp conf_set parse_cgi via_wrapper via_processor);

our $SECRET = 'e' x 64;

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

# build_site( conf => "extra lazysite.conf lines" ) -> $docroot
sub build_site {
    my (%o)  = @_;
    my $root = repo_root();
    my $d    = site_tempdir();
    my $LZ   = "$d/lazysite";
    make_path( "$LZ/auth", "$LZ/templates/system", "$LZ/layouts/test" );
    spit( "$LZ/lazysite.conf",
        "site_name: T\nsite_url: http://site.test\nlayout: test\nmanager: enabled\nauth_redirect: /login\n" . ( $o{conf} // '' ) );
    spit( "$LZ/layouts/test/layout.tt",
        '<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>[% content %]</body></html>' );
    spit( "$LZ/auth/.secret", "$SECRET\n" );
    chmod 0600, "$LZ/auth/.secret";
    spit( "$LZ/auth/users", join '', map { "$_:x\n" } qw(boss alice bob) );
    spit( "$LZ/auth/groups", "members: alice, bob, boss\n" );
    grant_caps( $d, 'boss',  'ui',             'maintenance_access' );
    grant_caps( $d, 'alice', 'manage_content', 'analytics' );

    # The pages the engine ships for the sign-in flow and for maintenance: the
    # protected defaults a real install carries under lazysite/templates/system/.
    my $src = "$root/starter/lazysite/templates/system";
    opendir my $dh, $src or die "$src: $!";
    for my $f ( grep { /\.md\z/ } readdir $dh ) {
        File::Copy::copy( "$src/$f", "$LZ/templates/system/$f" ) or die "copy $f: $!";
    }
    closedir $dh;

    spit( "$d/index.md",  "---\ntitle: Home\n---\nHOME BODY\n" );
    spit( "$d/about.md",  "---\ntitle: About\n---\nABOUT BODY\n" );
    spit( "$d/closed.md", "---\ntitle: Closed\nauth: none\n---\nMY OWN CLOSED PAGE\n" );
    return $d;
}

# Append (or replace) a lazysite.conf line.
sub conf_set {
    my ( $d, $key, $val ) = @_;
    my $f = "$d/lazysite/lazysite.conf";
    my $t = slurp($f);
    $t =~ s/^\Q$key\E\s*:.*\n//mg;
    $t .= "$key: $val\n" if defined $val;
    spit( $f, $t );
    return;
}

# A session cookie for $user, signed with the site's secret, in the legacy
# three-field shape (user:ts:groups) that verifies without a registry entry. The
# groups it carries are never read: the verifier resolves them fresh.
sub cookie_for {
    my ( $user, %o ) = @_;
    my $payload = join ':', $user, time(), '';
    my $sig     = $o{bad_sig} ? ( 'f' x 64 ) : hmac_sha256_hex( $payload, $SECRET );
    return "lazysite_auth=$payload:$sig";
}

# One CGI response -> { status, code, headers (lc => value), body, raw }.
sub parse_cgi {
    my ($raw) = @_;
    $raw //= '';
    my ( $head, $body ) = split /\r?\n\r?\n/, $raw, 2;
    my %h;
    my ($status) = ( $head // '' ) =~ /^Status:\s*(.+?)\r?$/mi;
    for my $l ( split /\r?\n/, $head // '' ) {
        next unless $l =~ /^([^:]+):\s*(.*)$/;
        my ( $k, $v ) = ( lc $1, $2 );
        $h{$k} = exists $h{$k} ? "$h{$k}\n$v" : $v;
    }
    my ($code) = ( $status // '200' ) =~ /^(\d{3})/;
    return { status => $status // '200 OK', code => $code // 200, headers => \%h, body => $body // '', raw => $raw };
}

sub _run {
    my ( $script, $d, $env, $stdin ) = @_;
    require IPC::Open3;
    require Symbol;
    my $root = repo_root();
    local %ENV = ( env_passthrough(), PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, %$env );
    my ( $w, $r );
    my $e   = Symbol::gensym();
    my $pid = IPC::Open3::open3( $w, $r, $e, $^X, $script );
    print {$w} ( $stdin // '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my $res = parse_cgi($out);
    $res->{stderr} = $err // '';
    return $res;
}

# A page request through the REAL WRAPPER, which verifies the cookie and execs the
# processor. %o: uri, method, cookie, host, body, env => {...}
sub via_wrapper {
    my ( $d, %o ) = @_;
    my $root = repo_root();
    my ( $path, $q ) = split /\?/, ( $o{uri} // '/' ), 2;
    return _run( "$root/lazysite-auth.pl", $d, {
            REDIRECT_URL       => $path,
            REQUEST_URI        => $o{uri}    // '/',
            QUERY_STRING       => $q         // '',
            REQUEST_METHOD     => $o{method} // 'GET',
            REMOTE_ADDR        => '198.51.100.7',
            HTTP_HOST          => $o{host} // 'site.test',
            LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
            ( defined $o{cookie} ? ( HTTP_COOKIE    => $o{cookie} )      : () ),
            ( defined $o{body}   ? ( CONTENT_LENGTH => length $o{body} ) : () ),
            %{ $o{env} || {} },
    }, $o{body} );
}

# The same page request straight to the processor, as the split templates send a
# visitor with no cookie.
sub via_processor {
    my ( $d, %o ) = @_;
    my $root = repo_root();
    my ( $path, $q ) = split /\?/, ( $o{uri} // '/' ), 2;
    return _run( "$root/lazysite-processor.pl", $d, {
            REDIRECT_URL   => $path,
            REQUEST_URI    => $o{uri}    // '/',
            QUERY_STRING   => $q         // '',
            REQUEST_METHOD => $o{method} // 'GET',
            REMOTE_ADDR    => '198.51.100.7',
            HTTP_HOST      => $o{host} // 'site.test',
            %{ $o{env} || {} },
    }, $o{body} );
}

1;

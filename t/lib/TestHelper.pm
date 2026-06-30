package TestHelper;
# Shared setup + subprocess helpers for the lazysite test suite.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use FindBin;
use Exporter 'import';

our @EXPORT_OK = qw(
    repo_root processor_path
    load_processor silence_stdout
    setup_test_site setup_minimal_site setup_auth_site setup_search_site
    run_processor run_script run_dav
    setup_dav_site dav_users_tool
    grant_caps revoke_caps
);

# SM095: capabilities live on GROUPS now, not on accounts. Grant some to a user by
# putting them in a per-user role group carrying those caps; revoke by clearing
# them. Writes the auth files DIRECTLY (no users-tool subprocess) - the suite makes
# thousands of these, and forking the tool each time exhausts resources.
sub grant_caps {
    my ( $docroot, $user, @caps ) = @_;
    my $group = "role-$user";
    _gc_add_member( $docroot, $group, $user );
    _gc_set_caps( $docroot, $group, { map { $_ => 1 } @caps } );
    return $group;
}

sub revoke_caps {
    my ( $docroot, $user, @caps ) = @_;
    _gc_set_caps( $docroot, "role-$user", { map { $_ => 0 } @caps } );
    return;
}

sub _gc_groups_file { "$_[0]/lazysite/auth/groups" }
sub _gc_gs_file     { "$_[0]/lazysite/auth/groups-settings.json" }

sub _gc_read_groups {
    my ($docroot) = @_;
    my %g;
    open my $fh, '<', _gc_groups_file($docroot) or return %g;
    while (<$fh>) {
        chomp; s/^\s+|\s+$//g; next if /^#/ || !length;
        my ( $grp, $mem ) = split /:\s*/, $_, 2;
        next unless defined $mem;
        $g{$grp} = [ map { s/^\s+|\s+$//gr } split /,/, $mem ];
    }
    close $fh;
    return %g;
}

sub _gc_add_member {
    my ( $docroot, $group, $user ) = @_;
    my %g = _gc_read_groups($docroot);
    $g{$group} ||= [];
    push @{ $g{$group} }, $user unless grep { $_ eq $user } @{ $g{$group} };
    open my $w, '>', _gc_groups_file($docroot) or die "groups: $!";
    for my $grp ( sort keys %g ) {
        print {$w} "$grp: " . join( ', ', @{ $g{$grp} } ) . "\n" if @{ $g{$grp} };
    }
    close $w;
}

sub _gc_set_caps {
    my ( $docroot, $group, $caps ) = @_;
    require JSON::PP;
    my $f  = _gc_gs_file($docroot);
    my $gs = {};
    if ( open my $fh, '<', $f ) {
        local $/;
        $gs = eval { JSON::PP::decode_json( <$fh> ) } || {};
        close $fh;
    }
    $gs->{$group} ||= { label => $group };
    for my $k ( keys %$caps ) {
        if ( $caps->{$k} ) { $gs->{$group}{$k} = 1 }
        else               { delete $gs->{$group}{$k} }
    }
    open my $w, '>', $f or die "groups-settings: $!";
    print {$w} JSON::PP::encode_json($gs);
    close $w;
}

sub repo_root {
    my $bin = $FindBin::Bin;
    for my $up ( '.', '..', '../..', '../../..' ) {
        my $p = "$bin/$up/lazysite-processor.pl";
        if ( -f $p ) {
            my $r = "$bin/$up";
            require Cwd;
            return Cwd::abs_path($r);
        }
    }
    die "TestHelper: cannot find repo root from $bin\n";
}

sub processor_path {
    return repo_root() . "/lazysite-processor.pl";
}

# Load the processor into the current Perl process so its subs become
# callable as main::func(). The processor calls main() at the bottom,
# which will produce a 404 for the test URL - we silence STDOUT around
# the `do` so that noise doesn't pollute the TAP stream.
sub load_processor {
    my ($docroot) = @_;
    $ENV{DOCUMENT_ROOT} = $docroot;
    $ENV{REDIRECT_URL}  = '/__testhelper_nonexistent__';
    $ENV{REQUEST_METHOD} //= 'GET';
    $ENV{QUERY_STRING}   //= '';

    my $proc = processor_path();
    my $result;

    open( my $null, '>', '/dev/null' ) or die "open /dev/null: $!\n";
    # Save and redirect STDOUT/STDERR at the fd level so bare print and
    # log_event() inside the processor go to /dev/null during load.
    # Test::Builder stashes its own dup at import time and is unaffected.
    open( my $saved,  '>&', \*STDOUT ) or die "dup STDOUT: $!\n";
    open( my $savede, '>&', \*STDERR ) or die "dup STDERR: $!\n";
    open( STDOUT, '>&', $null ) or die "redir STDOUT: $!\n";
    open( STDERR, '>&', $null ) or die "redir STDERR: $!\n";

    {
        # `do` inherits the caller's package. The processor has no
        # `package` declaration of its own, so without this block its
        # subs would be defined in TestHelper::* instead of main::*.
        package main;
        $result = do $proc;
    }
    my $err = $@;

    open( STDOUT, '>&', $saved )  or warn "restore STDOUT: $!\n";
    open( STDERR, '>&', $savede ) or warn "restore STDERR: $!\n";
    close $saved;
    close $savede;
    close $null;

    die "TestHelper: processor load failed: $err\n" if $err;
    return 1;
}

sub silence_stdout(&) {
    my ($code) = @_;
    open( my $null, '>', '/dev/null' ) or die $!;
    open( my $saved, '>&', \*STDOUT )  or die $!;
    open( STDOUT, '>&', $null )        or die $!;
    my $r = eval { $code->() };
    my $e = $@;
    open( STDOUT, '>&', $saved );
    close $saved;
    close $null;
    die $e if $e;
    return $r;
}

# --- Fixture builders ---

sub setup_minimal_site {
    my ($docroot) = @_;
    make_path("$docroot/lazysite");

    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Test\nsite_url: http://localhost\n";
    close $cf;

    open my $idx, '>', "$docroot/index.md" or die $!;
    print $idx "---\ntitle: Home\n---\nHome page.\n";
    close $idx;

    open my $nf, '>', "$docroot/404.md" or die $!;
    print $nf "---\ntitle: Not Found\n---\nNot found.\n";
    close $nf;
}

sub setup_test_site {
    my ($docroot) = @_;
    make_path("$docroot/lazysite/cache");
    make_path("$docroot/lazysite/templates");
    # D013: layouts live at lazysite/layouts/NAME/layout.tt; write a
    # 'test' layout and point the conf at it. Themes are optional;
    # this fixture renders without a theme.
    make_path("$docroot/lazysite/layouts/test");

    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Test\nsite_url: http://localhost\nlayout: test\n";
    close $cf;

    open my $vf, '>', "$docroot/lazysite/layouts/test/layout.tt" or die $!;
    print $vf '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
           . '<body>[% content %]</body></html>';
    close $vf;

    open my $idx, '>', "$docroot/index.md" or die $!;
    print $idx "---\ntitle: Home\n---\nHome page.\n";
    close $idx;

    open my $nf, '>', "$docroot/404.md" or die $!;
    print $nf "---\ntitle: Not Found\n---\nNot found.\n";
    close $nf;

    open my $api, '>', "$docroot/api-test.md" or die $!;
    print $api "---\ntitle: API\napi: true\n---\n{\"status\": \"ok\"}\n";
    close $api;

    open my $raw, '>', "$docroot/raw-test.md" or die $!;
    print $raw "---\ntitle: Raw\nraw: true\n---\nRaw content.\n";
    close $raw;
}

sub setup_auth_site {
    my ($docroot) = @_;
    setup_test_site($docroot);
    make_path("$docroot/lazysite/auth");

    open my $uf, '>', "$docroot/lazysite/auth/users" or die $!;
    print $uf "alice:" . sha256_hex('password') . "\n";
    print $uf "bob:"   . sha256_hex('bobpass')  . "\n";
    close $uf;

    open my $gf, '>', "$docroot/lazysite/auth/groups" or die $!;
    print $gf "admins: alice\nmembers: alice, bob\n";
    close $gf;

    open my $pf, '>', "$docroot/protected.md" or die $!;
    print $pf "---\ntitle: Protected\nauth: required\n---\nProtected.\n";
    close $pf;

    open my $af, '>', "$docroot/admins-only.md" or die $!;
    print $af "---\ntitle: Admins\nauth: required\nauth_groups:\n  - admins\n---\nAdmin.\n";
    close $af;

    open my $lf, '>', "$docroot/login.md" or die $!;
    print $lf "---\ntitle: Login\nauth: none\n---\nLogin.\n";
    close $lf;

    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    # C-1 / D017: tests simulate an upstream auth proxy that sets
    # HTTP_X_REMOTE_* env vars. With auth_proxy_trusted: true the
    # processor trusts those without the LAZYSITE_AUTH_TRUSTED sentinel.
    print $cf "auth_redirect: /login\nauth_proxy_trusted: true\n";
    close $cf;
}

sub setup_search_site {
    my ($docroot) = @_;
    setup_test_site($docroot);
    make_path("$docroot/lazysite/templates/registries");

    # Writeable: generates a search-index.json-like array of pages.
    open my $tf, '>', "$docroot/lazysite/templates/registries/search-index" or die $!;
    print $tf <<'EOF';
[%- FOREACH p IN pages %]
[%- IF p.searchable -%]
{"title":"[% p.title %]","url":"[% p.url %]"}
[%- END -%]
[% END %]
EOF
    close $tf;

    open my $s1, '>', "$docroot/searchable.md" or die $!;
    print $s1 "---\ntitle: Searchable Post\nregister:\n  - search-index\nsearch: true\n---\nFindable.\n";
    close $s1;

    open my $s2, '>', "$docroot/hidden.md" or die $!;
    print $s2 "---\ntitle: Hidden Post\nregister:\n  - search-index\nsearch: false\n---\nHidden.\n";
    close $s2;
}

# Run the processor as a subprocess and capture CGI output (headers+body).
sub run_processor {
    my ( $docroot, $uri, %override ) = @_;
    my $proc = processor_path();
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $docroot;
    $ENV{REDIRECT_URL}  = $uri;
    $ENV{REQUEST_METHOD} = 'GET'  unless defined $ENV{REQUEST_METHOD};
    $ENV{QUERY_STRING}   = ''      unless defined $ENV{QUERY_STRING};
    # User overrides last
    for my $k ( keys %override ) {
        if ( defined $override{$k} ) {
            $ENV{$k} = $override{$k};
        } else {
            delete $ENV{$k};
        }
    }
    return qx($^X \Q$proc\E 2>/dev/null);
}

# Run any script at repo root (e.g. lazysite-manager-api.pl) as subprocess.
sub run_script {
    my ( $rel_script, %opts ) = @_;
    my $root   = repo_root();
    my $script = "$root/$rel_script";
    local %ENV = %ENV;
    for my $k ( keys %{ $opts{env} || {} } ) {
        $ENV{$k} = $opts{env}{$k};
    }
    my $stdin = $opts{stdin};
    if ( defined $stdin ) {
        require IPC::Open2;
        my ( $cout, $cin );
        my $pid = IPC::Open2::open2( $cout, $cin, $^X, $script );
        print $cin $stdin;
        close $cin;
        my $out = do { local $/; <$cout> };
        close $cout;
        waitpid $pid, 0;
        return $out;
    }
    return qx($^X \Q$script\E 2>/dev/null);
}

# SM070: drive lazysite-dav.pl as a CGI subprocess.
#   run_dav($docroot, $method, $path, %opt)
# %opt keys are passed through as CGI environment variables
# (HTTP_AUTHORIZATION, HTTP_DEPTH, HTTP_DESTINATION, REMOTE_ADDR, ...),
# except `body`, which is fed on STDIN. CONTENT_LENGTH is derived from
# the body unless given. The failed-auth sleep is disabled by default
# so the suite stays fast. Returns a hashref:
#   { code, headers (lc-keyed hashref), body, raw, stderr }
sub run_dav {
    my ( $docroot, $method, $path, %opt ) = @_;
    my $body = delete $opt{body};
    $body = '' unless defined $body;

    my $script = repo_root() . "/lazysite-dav.pl";
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REQUEST_METHOD} = $method;
    $ENV{PATH_INFO}      = $path;
    $ENV{SCRIPT_NAME}            = '/dav'      unless exists $opt{SCRIPT_NAME};
    $ENV{REMOTE_ADDR}           = '127.0.0.1' unless exists $opt{REMOTE_ADDR};
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0         unless exists $opt{LAZYSITE_DAV_FAIL_DELAY};
    $ENV{CONTENT_LENGTH} = length($body)
        if length($body) && !exists $opt{CONTENT_LENGTH};

    for my $k ( keys %opt ) {
        if ( defined $opt{$k} ) { $ENV{$k} = $opt{$k} }
        else                    { delete $ENV{$k} }
    }

    require IPC::Open3;
    require Symbol;
    my ( $wtr, $rdr );
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( $wtr, $rdr, $err, $^X, $script );
    binmode $wtr;
    print {$wtr} $body;
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    $out  //= '';
    $eout //= '';

    my ($code) = $out =~ /^Status:\s*(\d+)/;
    my ( $hblock, $rbody ) = split /\r\n\r\n/, $out, 2;
    my %headers;
    for my $line ( split /\r\n/, $hblock // '' ) {
        next unless $line =~ /^([^:]+):\s*(.*)$/;
        my ( $k, $v ) = ( lc $1, $2 );
        $headers{$k} = exists $headers{$k} ? "$headers{$k}\n$v" : $v;
    }
    return {
        code    => $code,
        headers => \%headers,
        body    => $rbody // '',
        raw     => $out,
        stderr  => $eout,
    };
}

# SM070: run tools/lazysite-users.pl quietly, returning its exit code.
sub dav_users_tool {
    my ( $docroot, @args ) = @_;
    require IPC::Open3;
    require Symbol;
    my $root = repo_root();
    my $err  = Symbol::gensym();
    my $pid  = IPC::Open3::open3( my $in, my $out, $err,
        $^X, "$root/tools/lazysite-users.pl", '--docroot', $docroot, @args );
    close $in;
    { local $/; my $o = <$out>; my $e = <$err>; }
    waitpid $pid, 0;
    return $? >> 8;
}

# SM070: build a docroot with WebDAV enabled and one webdav-capable
# user, returning { docroot, user, password, auth }. Options: user,
# password, webdav ('on'/'off'), scope, conf (full conf body), no_user.
sub setup_dav_site {
    my (%o) = @_;
    require MIME::Base64;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    make_path("$d/content");

    my $conf = defined $o{conf} ? $o{conf} : "webdav_enabled: true\n";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die "conf: $!";
    print $cf $conf;
    close $cf;

    my $user = defined $o{user}     ? $o{user}     : 'deploy';
    my $pass = defined $o{password} ? $o{password} : 'secret';
    unless ( $o{no_user} ) {
        dav_users_tool( $d, 'add', $user, $pass );
        # SM095: webdav is a group capability now. Default a content-publishing
        # role (webdav + content/nav/forms - the old webdav->content inheritance);
        # pass caps => [...] for a different set, or webdav => 'off' for none.
        if ( ( $o{webdav} // 'on' ) ne 'off' ) {
            my @caps = $o{caps} ? @{ $o{caps} }
                : qw(webdav manage_content manage_nav manage_forms);
            grant_caps( $d, $user, @caps );
        }
        dav_users_tool( $d, 'set', $user, 'dav_scope', $o{scope} )
            if defined $o{scope};
    }
    my $auth = 'Basic ' . MIME::Base64::encode_base64( "$user:$pass", '' );
    return { docroot => $d, user => $user, password => $pass, auth => $auth };
}

1;

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
    run_processor run_script
);

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

1;

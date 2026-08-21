package TestHelper;
# Shared setup + subprocess helpers for the lazysite test suite.
use strict;
use warnings;
use File::Temp  qw(tempdir);
use Fcntl       qw(:flock O_WRONLY O_CREAT);
use File::Path  qw(make_path);
use File::Copy  ();
use Digest::SHA qw(sha256_hex);
use FindBin;
use Exporter 'import';

our @EXPORT_OK = qw(
    repo_root processor_path
    load_processor silence_stdout
    setup_test_site setup_minimal_site setup_auth_site setup_search_site
    run_processor run_script run_dav
    setup_dav_site dav_users_tool setup_multi_domain_site
    grant_caps revoke_caps
    env_passthrough
    repo_manifest_guard repo_root_lock
    run_cmd
);

# Run a command and capture its output. LIST FORM - no shell, ever.
#
# WHY THIS EXISTS. Tests kept building a shell string and interpolating into it,
# which works until an argument contains a space and then fails in the most
# misleading way available: the command is silently re-split into different
# words, the tool under test receives nonsense, and EVERY assertion in the file
# fails at once. That reads exactly like the feature being broken.
#
# It has cost two debugging sessions in one day. `lazysite acl` looked entirely
# broken because "--docroot is required" came back for every call; the front
# door looked entirely broken because no route reached any surface. Both times
# the tool was fine and the harness was wrong, and both times the honest signal
# - "everything failed at once" - pointed at the product.
#
# Returns the combined stdout+stderr, with the exit status in $?, because a test
# that ignores stderr cannot tell a refusal from a crash.
sub run_cmd {
    my (@argv) = @_;
    my $pid    = open my $ph, '-|';
    die "run_cmd: cannot fork: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 127;
        exec @argv;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    return defined $out ? $out : '';
}

# SM269 phase 1: OWN the shared release-manifest.json, rather than lock beside
# six copies of its lifecycle.
#
# install.pl resolves its manifest as abs_path(dirname($0))/release-manifest.json
# - beside itself, by design, because that is where it sits in a release tarball.
# Six tests therefore need one at the repo root, and each had grown its own copy
# of the same three steps: build if absent, remember whether I built it, unlink
# at END if I did.
#
# Six copies of one lifecycle is what kept producing ordering bugs. A lock alone
# did not fix it: the lock serialises the tests, but each test still decides
# independently when to create and destroy a file they all share, and an END
# block firing at the wrong moment relative to another test's body is exactly the
# race the lock was supposed to remove. So the guard now owns all three steps.
#
# Hold it for as long as you need the manifest. It locks on construction, builds
# if absent, and removes at destruction ONLY if it was the one that built it - so
# an operator's own manifest is never deleted.
# The repo-root lock, on its own, for a test that DIRTIES THE SHARED REPO ROOT
# rather than building a manifest from it.
#
# WHY THIS IS SEPARATE AND EXPORTED. t/tools/01's SM271 subtest writes an
# deliberately-unclassified file into the real repo root to prove that
# build-manifest refuses it. While that file exists, EVERY concurrent
# build-manifest run over the same root refuses too - including the one inside
# repo_manifest_guard, which then dies before its caller has emitted any TAP at
# all. Under `prove -j4` over 427 files that surfaced as t/tools/03 exiting 2
# with no plan: a file that passes alone, passes in its own directory, and
# fails perhaps once in a full run.
#
# It was recorded as a suspected flake in t/tools/03 on 2026-08-14 and the note
# there says an unreproducible failure is an anecdote that decays. It was never
# flaky in the sense of "random": it failed whenever the two windows overlapped.
#
# The lock is the same one repo_manifest_guard takes, deliberately - a second
# lock would not exclude anything. Hold the returned guard for as long as the
# root is dirty, and let it go out of scope to release.
sub repo_root_lock {
    my $lock = repo_root() . '/.manifest-test.lock';
    ## no critic (RequireBriefOpen) - the handle IS the lock; it lives in the guard.
    open my $fh, '>>', $lock or die "cannot open $lock: $!";
    flock( $fh, LOCK_EX ) or die "cannot lock $lock: $!";
    return TestHelper::RootLock->new($fh);
}

{
    package TestHelper::RootLock;
    sub new { my ( $c, $fh ) = @_; return bless { fh => $fh }, $c; }
    sub DESTROY {
        my ($self) = @_;
        close $self->{fh} if $self->{fh};
        return;
    }
}

sub repo_manifest_guard {
    my $root = repo_root();
    my $lock = "$root/.manifest-test.lock";
    ## no critic (RequireBriefOpen) - the handle IS the lock; it lives in the guard.
    open my $fh, '>>', $lock or die "cannot open $lock: $!";
    flock( $fh, LOCK_EX ) or die "cannot lock $lock: $!";

    my $mf    = "$root/release-manifest.json";
    my $built = 0;

    # A PRE-EXISTING manifest is never trusted, and that is the whole fix.
    #
    # release-manifest.json is a gitignored BUILD artefact. It is left behind by
    # any local release build and by an earlier test run that died before its
    # guard could clean up, and its CONTENT can describe a tree that no longer
    # exists. Tests here compare files against it, so a stale one produces drift
    # that has nothing to do with what they are testing - which is exactly how
    # t/tools/03's deploy-gap assertion appeared to fail intermittently. It was
    # never intermittent: it failed whenever a stale manifest happened to be
    # lying around and passed whenever one did not.
    #
    # An mtime check is not good enough - the first attempt at this used one,
    # and `cp` of an old manifest gives it a new mtime with stale content, which
    # is precisely the case that arises when someone restores a backup. So: set
    # any existing manifest aside, ALWAYS build a fresh one, and put the
    # original back afterwards. Costs about a second per guard and removes the
    # entire class.
    my $saved;
    if ( -f $mf ) {
        # OUT of the repo: the manifest builder refuses any unclassified file
        # in the tree, so a set-aside copy beside it fails the very build we
        # are about to run.
        $saved = "/tmp/lazysite-manifest-saved-$$.json";
        # move(), not rename(): /tmp is a different filesystem from /srv on
        # this host, and rename() cannot cross one.
        File::Copy::move( $mf, $saved )
            or die "TestHelper: cannot set aside $mf: $!";
    }

    my $rc = system( $^X, "$root/tools/build-manifest.pl" );
    if ( $rc != 0 || !-f $mf ) {
        File::Copy::move( $saved, $mf ) if $saved && -f $saved;
        die "TestHelper: failed to build $mf (rc=$rc)\n";
    }
    $built = 1;

    return TestHelper::ManifestGuard->new( $fh, $mf, $built, $saved );
}

{
    package TestHelper::ManifestGuard;

    sub new {
        my ( $c, $fh, $mf, $built, $saved ) = @_;
        return bless { fh => $fh, mf => $mf, built => $built, saved => $saved },
            $c;
    }

    # The manifest path, for a test that wants to read it.
    sub path { return $_[0]->{mf} }

    sub DESTROY {
        my ($self) = @_;
        # Remove BEFORE releasing the lock, or the next waiter can see a file
        # that is about to vanish - which is the original race in miniature.
        unlink $self->{mf} if $self->{built} && -f $self->{mf};
        # Put the developer's own build artefact back, if we set one aside.
        File::Copy::move( $self->{saved}, $self->{mf} )
            if $self->{saved} && -f $self->{saved};
        close $self->{fh} if $self->{fh};    # flock releases on close
        return;
    }
}

# Coverage passthrough (review D3): a test that rebuilds %ENV from scratch for
# a CGI child drops PERL5OPT, so tools/coverage.sh's Devel::Cover
# instrumentation never reaches the child and the CGI reports "not measured".
# Splice this into the front of the rebuilt list:
#   local %ENV = ( env_passthrough(), DOCUMENT_ROOT => ..., ... );
# (The RHS is evaluated against the ORIGINAL %ENV before the assignment, so
# this is safe inside the `local %ENV = (...)` idiom.) Empty outside coverage
# runs, so normal prove behaviour is unchanged.
sub env_passthrough {
    return map { $_ => $ENV{$_} } grep { defined $ENV{$_} } qw(PERL5OPT PERL5LIB);
}

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
        $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
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
    open( STDOUT,     '>&', $null )    or die "redir STDOUT: $!\n";
    open( STDERR,     '>&', $null )    or die "redir STDERR: $!\n";

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
    open( my $null,  '>',  '/dev/null' ) or die $!;
    open( my $saved, '>&', \*STDOUT )    or die $!;
    open( STDOUT,    '>&', $null )       or die $!;
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
    print $uf "bob:" . sha256_hex('bobpass') . "\n";
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
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REDIRECT_URL}   = $uri;
    $ENV{REQUEST_METHOD} = 'GET' unless defined $ENV{REQUEST_METHOD};
    $ENV{QUERY_STRING}   = ''    unless defined $ENV{QUERY_STRING};
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
    $ENV{DOCUMENT_ROOT}           = $docroot;
    $ENV{REQUEST_METHOD}          = $method;
    $ENV{PATH_INFO}               = $path;
    $ENV{SCRIPT_NAME}             = '/dav'      unless exists $opt{SCRIPT_NAME};
    $ENV{REMOTE_ADDR}             = '127.0.0.1' unless exists $opt{REMOTE_ADDR};
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0 unless exists $opt{LAZYSITE_DAV_FAIL_DELAY};
    $ENV{CONTENT_LENGTH}          = length($body)
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
                :   qw(webdav manage_content manage_nav manage_forms);
            grant_caps( $d, $user, @caps );
        }
        # SM165: confinement is on the DOMAIN now. Register a domain rooted at the
        # requested content root and allowed to this user's role group, so the
        # member is confined to it (replaces the SM155 group dav_scope). The
        # scope value is normalised to a docroot-relative content root.
        if ( defined $o{scope} ) {
            ( my $cr = $o{scope} ) =~ s{^/+}{};
            $cr =~ s{/+$}{};
            open my $ap, '>>', "$d/lazysite/lazysite.conf" or die "conf: $!";
            print $ap "alias_hosts: scoped.test\n";
            print $ap "alias.scoped.test.content_root: $cr\n";
            print $ap "alias.scoped.test.allowed_groups: role-$user\n";
            close $ap;
        }
    }
    my $auth = 'Basic ' . MIME::Base64::encode_base64( "$user:$pass", '' );
    return { docroot => $d, user => $user, password => $pass, auth => $auth };
}

# ---------------------------------------------------------------------
# A MULTI-DOMAIN instance, because a single-site fixture cannot fail the
# way this software actually fails.
#
# Ten defects surfaced in one week of real multi-site use, every suite
# green throughout, and each needed TWO SITES ON ONE INSTANCE to appear:
#
#   SM436  a domain configured under a name no request carries served the
#          PRIMARY's site - needs a domain that is not the default
#   SM440  an alias 301'd into a 404 on its own host, and SERVED that
#          site's page under a NEIGHBOUR's domain - needs a neighbour
#   SM441  a page previewed in the default theme - needs a domain whose
#          presentation differs from the primary's
#   SM443  a per-domain nav save replaced the shared one - needs a domain
#          that inherits and one that does not
#
# On one site the docroot IS the content root, the Host always matches,
# and "the primary" and "this domain" are the same thing - so the bugs
# are unreachable and the tests pass truthfully while describing a shape
# the estate no longer has.
#
# SM440's filing puts the requirement plainly: the regression test has to
# be one a single-site instance CANNOT pass. This builds that instance.
#
# Returns { docroot, domains => { key => {host, root, ...} } }. Every
# domain gets a real content root with an index page, so a render or a
# walk finds something.
#
#   primary    the docroot itself - content root '', the default site
#   alpha      its own content root, its own layout/theme/nav
#   beta       its own content root, INHERITS presentation and nav
#   alpha_sub  content root NESTED inside alpha's, for longest-match
#   alpha_near an UNREGISTERED sibling whose name PREFIXES alpha's
#
# The last two are the ones that catch containment. A prefix sibling that
# is itself registered proves nothing: longest-match picks it whether the
# containment test is boundary-safe or not, which let a bare
# index($rel,$root)==0 sabotage pass three separate times in this repo
# before the fixtures were corrected. alpha_near is deliberately NOT a
# domain - only correct containment leaves it belonging to the primary.
sub setup_multi_domain_site {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite", "$d/lazysite/auth", "$d/lazysite/cache" );

    my %dom = (
        primary => { host => 'primary.test', root => '' },
        alpha   => { host => 'alpha.test',   root => 'sites/alpha',
            layout => 'alpha-layout', theme => 'alpha-theme',
            nav_file => 'lazysite/nav-alpha.conf' },
        beta      => { host => 'beta.test',  root => 'sites/beta' },
        alpha_sub => { host => 'sub.alpha.test', root => 'sites/alpha/inner' },
    );

    my $conf = "site_name: Primary\n"
        . "site_url: \${REQUEST_SCHEME}://\${SERVER_NAME}\n"
        . "layout: base\ntheme: base\n"
        . 'alias_hosts: '
        . join( ', ', map { $dom{$_}{host} } qw(alpha beta alpha_sub) ) . "\n";
    for my $k (qw(alpha beta alpha_sub)) {
        my $h = $dom{$k}{host};
        $conf .= "alias.$h.content_root: $dom{$k}{root}\n";
        $conf .= "alias.$h.site_url: https://$h\n";
        $conf .= "alias.$h.site_name: \u$k\n";
        for my $key (qw(layout theme nav_file)) {
            next unless defined $dom{$k}{$key};
            $conf .= "alias.$h.$key: $dom{$k}{$key}\n";
        }
    }
    $conf .= $o{extra_conf} if defined $o{extra_conf};

    open my $cf, '>', "$d/lazysite/lazysite.conf" or die "conf: $!";
    print {$cf} $conf;
    close $cf;

    open my $nv, '>', "$d/lazysite/nav.conf" or die "nav: $!";
    print {$nv} "Home | /\n";
    close $nv;

    # A content root per domain, plus the UNREGISTERED prefix sibling and a
    # page at the docroot, so containment has something to get wrong.
    for my $rel ( 'sites/alpha', 'sites/alpha/inner', 'sites/beta',
        'sites/alpha-near' )
    {
        make_path("$d/$rel");
        open my $ix, '>', "$d/$rel/index.md" or die "index: $!";
        print {$ix} "---\ntitle: $rel\n---\n\nbody\n";
        close $ix;
    }
    open my $ix, '>', "$d/index.md" or die "index: $!";
    print {$ix} "---\ntitle: Primary\n---\n\nbody\n";
    close $ix;

    $dom{alpha_near} = { host => undef, root => 'sites/alpha-near' };
    return { docroot => $d, domains => \%dom, conf => $conf };
}

1;

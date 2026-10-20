#!/usr/bin/perl
# SM1233: the Docker Compose package (installers/docker/). Ruled 2026-10-20 -
# "add to next release - a docker compose package": nginx and the one-rule
# FastCGI pool in the container, three volumes (the docroot, lazysite/, the
# private store), the engine in the image, no Odoo, built locally from the
# release tarball.
#
# None of this needs Docker. The compose file and the Dockerfile are read as
# text, the vhost's sed is run on the real template, the entrypoint is run
# against stubs, and the release's own manifest builder is run on the package.
# The one real build is a by-hand step at the end of the work, not a test.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);
use JSON::PP   ();
use POSIX      ();

my $root = repo_root();
my $pkg  = "$root/installers/docker";

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

# --- the package is there -----------------------------------------------------
for my $f (qw(Dockerfile Dockerfile.dockerignore compose.yaml entrypoint.sh nginx.conf README.md)) {
    ok( -f "$pkg/$f", "installers/docker/$f exists" );
}
ok( -x "$pkg/entrypoint.sh", 'the entrypoint is executable' );
ok( !-e "$pkg/.gitkeep",     'the placeholder is gone' );

my $compose = slurp("$pkg/compose.yaml");
my $docker  = slurp("$pkg/Dockerfile");
my $entry   = slurp("$pkg/entrypoint.sh");
my $nginx   = slurp("$pkg/nginx.conf");

# --- compose.yaml: the three volumes, and no Odoo -----------------------------
# A minimal reader: this file's shape is fixed, and the repo carries no YAML
# parser a host is guaranteed to have.
my ($top) = $compose =~ /^volumes:\n((?:[ ]+[\w-]+:[^\n]*\n|\s*#[^\n]*\n|\n)+)/m;
my @named = $top ? ( $top =~ /^[ ]+([\w-]+):/mg ) : ();
is_deeply( [ sort @named ], [qw(lazysite-docroot lazysite-private lazysite-settings)], 'three named volumes, no more' );

my %mount = $compose =~ m{^\s+-\s+([\w-]+):(/\S+)\s*$}mg;
is_deeply(
    \%mount,
    {
        'lazysite-docroot'  => '/srv/lazysite/html',
        'lazysite-settings' => '/srv/lazysite/html/lazysite',
        'lazysite-private'  => '/srv/lazysite/html-lazysite-private',
    },
    'the service mounts the docroot, lazysite/ and the private store'
);

# The private store is where the engine (and install.pl) put it: a sibling of
# the docroot named <docroot>-lazysite-private.
is( $mount{'lazysite-private'}, "$mount{'lazysite-docroot'}-lazysite-private", 'the private store is the docroot\'s sibling' );
is( $mount{'lazysite-settings'}, "$mount{'lazysite-docroot'}/lazysite", 'lazysite/ is inside the docroot, as install.pl lays it' );

my ($svc_block) = $compose =~ /^services:\n(.*?)^volumes:/ms;
my @services = $svc_block =~ /^  ([\w-]+):\s*$/mg;
is_deeply( \@services, ['lazysite'], 'one service' );

for my $pair ( [ compose => $compose ], [ Dockerfile => $docker ], [ entrypoint => $entry ], [ 'nginx.conf' => $nginx ] ) {
    ( my $code = $pair->[1] ) =~ s/^\s*#[^\n]*\n//mg;
    unlike( $code, qr/odoo|\boom\b|oomd/i, "$pair->[0] names no Odoo, OOM or oomd" );
}

like( $compose, qr{^\s+context:\s*\.\./\.\.\s*$}m, 'the build context is the unpacked tarball' );
like( $compose, qr{^\s+dockerfile:\s*installers/docker/Dockerfile\s*$}m, 'the Dockerfile is named from that context' );
ok( -f "$root/installers/docker/Dockerfile", 'and it is there' );
unlike( $compose, qr/^\s+(?:image:\s*\S*\/\S+|platform:)/m, 'no registry-qualified image' );
like( $compose, qr/^\s+healthcheck:\n(?:\s+.*\n)*?\s+test:.*curl.*127\.0\.0\.1:8080/m, 'a healthcheck that fetches /' );
like( $compose, qr/^\s+cap_drop:\n\s+- ALL/m,  'all capabilities dropped' );
like( $compose, qr/no-new-privileges:true/,    'no-new-privileges' );
like( $compose, qr/restart:\s*unless-stopped/, 'restarts unless stopped' );
like( $compose, qr/stop_grace_period:/,        'a stop grace period' );
like( $compose, qr/\$\{LAZYSITE_BIND:-127\.0\.0\.1\}/, 'published on loopback unless the operator says otherwise' );

# --- the Dockerfile ------------------------------------------------------------
like( $docker, qr/^FROM debian:trixie/m, 'Debian trixie, what the debs target' );
like( $docker, qr{^COPY \. /usr/share/lazysite$}m, 'the release (install.pl, the manifest, the payload) is copied to where the debs put the payload' );
unlike( $docker, qr/^RUN[^\n]*install\.pl/m, 'nothing is installed into the volumes at build time' );
like( $docker, qr/^USER www-data$/m, 'non-root' );
like( $docker, qr/^HEALTHCHECK /m,   'the image has a healthcheck' );
like( $docker, qr/^ENTRYPOINT \[/m,  'an entrypoint' );
unlike( $docker, qr/^VOLUME\b/m, 'no VOLUME line, which would add anonymous volumes beside the three' );
for my $p (qw(libfcgi-perl libfcgi-procmanager-perl libtemplate-perl libtext-multimarkdown-perl nginx)) {
    like( $docker, qr/\b\Q$p\E\b/, "the image installs $p" );
}
like( $docker, qr{mkdir -p[^\n]*/srv/lazysite/html/lazysite[^\n]*\\\n[^\n]*cgi-bin}, 'the mount points exist in the image, owned by the user, so a new volume takes that ownership' );

# The vhost: the Dockerfile's own sed, run on the real template.
my ($sed) = $docker =~ /(sed \\\n.*?)\n\s+> \/etc\/nginx\/conf\.d\/lazysite\.conf/s;
ok( $sed, 'the Dockerfile makes the vhost from the template with sed' ) or BAIL_OUT('the Dockerfile changed shape');
my $dir = site_tempdir();
( my $t = $dir ) =~ s{/site/public_html\z}{};
$sed             =~ s{/usr/share/lazysite/installers}{$root/installers};
$sed             =~ s{\\\n}{ }g;
spit( "$t/vhost.sh", "$sed\n" );
my $vhost = `bash '$t/vhost.sh' 2>&1`;
is( $?, 0, 'the sed runs' );
unlike( $vhost, qr/__[A-Z]+__/, 'no placeholder is left in the vhost' );
like( $vhost, qr/^\s*listen 8080;/m,             'it listens on 8080' );
like( $vhost, qr{^\s*root /srv/lazysite/html;}m, 'and serves the docroot volume' );
like( $vhost, qr{fastcgi_pass unix:/run/lazysite/lazysite\.sock;}, 'the one rule goes to the pool\'s socket' );
like( $vhost, qr{fastcgi_param DOCUMENT_ROOT /srv/lazysite/html;}, 'with the docroot' );
like( $vhost, qr{access_log /dev/stdout;}m, 'the access log is the container\'s' );
like( $vhost, qr{error_log\s+stderr;}m,     'and so is the error log' );
my $rules = () = $vhost =~ /^\s*location\b/mg;
is( $rules, 1, 'one rule, as the template has it' );
unlike( $nginx, qr/^\s*user\s/m, 'nginx.conf sets no user: it is started as one' );
like( $nginx, qr{^pid /tmp/}m, 'and keeps its pid where that user can write' );
like( $docker, qr{chmod 2775 /srv/lazysite/html /srv/lazysite/html/lazysite}, 'the docroot and lazysite/ are 2775, which the install\'s health check requires' );

# --- the entrypoint, against stubs --------------------------------------------
{
    my $eng  = "$t/engine";
    my $site = "$t/srv";
    mkdir $eng; mkdir "$eng/tools"; mkdir $site; mkdir "$site/html"; mkdir "$site/html/lazysite";

    spit( "$eng/VERSION",               "9.9.9\n" );
    spit( "$eng/release-manifest.json", qq({"version":"9.9.9"}) );

    # install.pl stand-in: records its arguments and writes the state a real
    # one would, at the version it was given.
    spit( "$eng/install.pl", <<'STUB' );
use strict; use warnings;
open my $l, '>>', "$ENV{STUB_LOG}" or die; print {$l} "install @ARGV\n"; close $l;
exit $ENV{STUB_INSTALL_RC} if $ENV{STUB_INSTALL_RC};
my ($d) = grep { $ARGV[$_] eq '--docroot' } 0 .. $#ARGV;
my $doc = $ARGV[ $d + 1 ];
open my $s, '>', "$doc/lazysite/.install-state.json" or die; print {$s} qq({"version":"9.9.9"}); close $s;
mkdir "$ENV{STUB_SITE}/tools"; open my $u, '>', "$ENV{STUB_SITE}/tools/lazysite-users.pl" or die; close $u;
STUB

    my $log = "$t/stub.log";
    my %env = (
        LAZYSITE_ENGINE => $eng, LAZYSITE_SITE_ROOT => $site, LAZYSITE_PERL => $^X,
        STUB_LOG        => $log, STUB_SITE => $site, SITE_DOMAIN => 'site.example.test',
    );
    my $run_install = sub {
        my (%extra) = @_;
        local @ENV{ keys %env, keys %extra } = ( values %env, values %extra );
        my $out = `bash '$pkg/entrypoint.sh' install 2>&1`;
        return ( $? >> 8, $out );
    };
    my $calls = sub { return -f $log ? [ grep { /^install / } split /\n/, slurp($log) ] : [] };

    spit( "$site/html/CANARY", "mine\n" );

    # first start
    my ( $rc, $out ) = $run_install->();
    is( $rc, 0, 'first start: the install step succeeds' );
    my $c = $calls->();
    is( scalar @$c, 1, 'first start: install.pl ran once' );
    like( $c->[0], qr/--mode provision/,         'first start: provision, a fresh site' );
    like( $c->[0], qr{--docroot \Q$site\E/html}, 'first start: into the docroot volume' );
    like( $c->[0], qr{--cgibin \Q$site\E/cgi-bin}, 'first start: with the engine\'s cgi-bin beside it' );
    like( $c->[0], qr/--domain site\.example\.test/, 'first start: seeded with the domain' );
    unlike( $c->[0], qr/--force/, 'first start: no force' );
    like( $out, qr/setup-sysop --user NAME/, 'first start: it says how to make the first account' );

    # a later start: nothing
    ( $rc, $out ) = $run_install->();
    is( $rc, 0, 'later start: succeeds' );
    is( scalar @{ $calls->() }, 1, 'later start: install.pl is not run again; the volumes\' data is left alone' );
    like( $out, qr/left as they are/, 'later start: and it says so' );
    is( slurp("$site/html/CANARY"), "mine\n", 'later start: the data is untouched' );

    # a new container over the same volumes: the engine's copy is gone
    unlink "$site/tools/lazysite-users.pl";
    ( $rc, $out ) = $run_install->();
    $c = $calls->();
    is( scalar @$c, 2, 'new container: install.pl ran' );
    like( $c->[1], qr/--mode reinstall/, 'new container: reinstall, which keeps content' );
    unlike( $c->[1], qr/--domain/, 'new container: the domain is not re-applied' );

    # a new image: another version in the volume's state
    spit( "$site/html/lazysite/.install-state.json", qq({"version":"9.9.8"}) );
    ( $rc, $out ) = $run_install->();
    $c = $calls->();
    is( scalar @$c, 3, 'new image: install.pl ran' );
    like( $c->[2], qr/--mode upgrade/, 'new image: upgrade' );
    like( $c->[2], qr/--force/, 'new image: past the site\'s update channel, which the sysop\'s choice of image overrides' );

    # the version comes from the manifest when there is one
    spit( "$eng/release-manifest.json",              qq({"version":"9.9.8"}) );
    spit( "$site/html/lazysite/.install-state.json", qq({"version":"9.9.8"}) );
    ( $rc, $out ) = $run_install->();
    is( scalar @{ $calls->() }, 3, 'the image\'s version is the manifest\'s: a state at that version is current' );
    spit( "$eng/release-manifest.json", qq({"version":"9.9.9"}) );

    # install.pl exit codes
    unlink "$site/html/lazysite/.install-state.json";
    ( $rc, $out ) = $run_install->( STUB_INSTALL_RC => 4 );
    is( $rc, 0, 'exit 4 (installed, health check named something): the container still runs' );
    like( $out, qr/health check named a failure/, 'and says so' );
    ( $rc, $out ) = $run_install->( STUB_INSTALL_RC => 2 );
    is( $rc, 1, 'any other failure stops the container' );
    like( $out, qr/install\.pl provision failed \(exit 2\)/, 'and names it' );

    # an unreadable version is refused, not guessed
    unlink "$eng/VERSION", "$eng/release-manifest.json";
    ( $rc, $out ) = $run_install->();
    is( $rc, 1, 'no version in the image: refused' );
}

# --- run: the services start together and stop together -----------------------
{
    my $eng  = "$t/engine2";
    my $site = "$t/srv2";
    my $run  = "$t/run2";
    mkdir $eng; mkdir "$eng/tools"; mkdir $site; mkdir "$site/html"; mkdir "$site/html/lazysite"; mkdir "$site/tools";
    spit( "$eng/VERSION",                            "9.9.9\n" );
    spit( "$site/html/lazysite/.install-state.json", qq({"version":"9.9.9"}) );
    spit( "$site/tools/lazysite-users.pl",           '' );

    my $sleeper = 'use strict; use warnings; $SIG{TERM} = sub { exit 0 }; sleep 60; exit 3;';
    spit( "$eng/tools/lazysite-pool.pl",
        "open my \$o, '>', \"$t/pool.out\" or die; print {\$o} join(' ', \$\$, \"DOCROOT=\$ENV{DOCROOT}\", \"USER=\$ENV{USER}\","
            . " \"FRONT_DOOR=\$ENV{FRONT_DOOR}\", \"CGIBIN=\$ENV{CGIBIN}\", \"ARGS=\@ARGV\"), \"\\n\"; close \$o;\n$sleeper\n" );
    spit( "$eng/tools/lazysited.pl",
        "open my \$o, '>', \"$t/daemon.out\" or die; print {\$o} \"\$\$ \@ARGV\\n\"; close \$o;\nexit 0 if \$ENV{DAEMON_ONCE};\n$sleeper\n" );
    spit( "$t/nginx-stub", "#!/bin/bash\necho \"\$\$ \$*\" > '$t/nginx.out'\nif [ -n \"\${NGINX_DIES:-}\" ]; then exit 7; fi\nexec sleep 60\n" );
    chmod 0755, "$t/nginx-stub";

    my $start = sub {
        my (%extra) = @_;
        my $pid = fork() // die;
        if ( !$pid ) {
            %ENV = (
                %ENV, LAZYSITE_ENGINE => $eng, LAZYSITE_SITE_ROOT => $site, LAZYSITE_PERL => $^X,
                LAZYSITE_NGINX => "$t/nginx-stub", LAZYSITE_RUN_DIR => $run, LAZYSITE_DAEMON_RETRY => 60, %extra,
            );
            open STDOUT, '>', "$t/run.log"; open STDERR, '>&', \*STDOUT;
            exec 'bash', "$pkg/entrypoint.sh", 'run';
            exit 127;
        }
        return $pid;
    };
    my $waitfile = sub {
        my ($f) = @_;
        for ( 1 .. 100 ) { return 1 if -s $f; select undef, undef, undef, 0.1 }
        return 0;
    };
    my $alive = sub { my ($p) = @_; return $p && kill( 0, $p ) };

    my $ep = $start->();
    ok( $waitfile->("$t/pool.out") && $waitfile->("$t/daemon.out") && $waitfile->("$t/nginx.out"), 'run: the pool, lazysited and nginx all start' );
    my $pool = slurp("$t/pool.out");
    like( $pool, qr/DOCROOT=\Q$site\E\/html USER=www-data FRONT_DOOR=1 CGIBIN=\Q$site\E\/cgi-bin/, 'run: the pool runs the one-rule mode on the docroot volume, as www-data' );
    like( $pool, qr/ARGS=--instance lazysite --run-dir \Q$run\E/, 'run: on the instance and directory the vhost\'s socket names' );
    like( slurp("$t/daemon.out"), qr/--docroot \Q$site\E\/html --user www-data/, 'run: lazysited gets the docroot and the user' );
    like( slurp("$t/nginx.out"), qr/-g daemon off;/, 'run: nginx stays in the foreground' );
    ok( -d $run, 'run: the socket directory exists' );
    my ($pool_pid) = $pool                 =~ /^(\d+)/;
    my ($ng_pid)   = slurp("$t/nginx.out") =~ /^(\d+)/;

    kill 'TERM', $ep;
    my $gone = 0;
    for ( 1 .. 100 ) { if ( waitpid( $ep, POSIX::WNOHANG() ) == $ep ) { $gone = 1; last } select undef, undef, undef, 0.1 }
    ok( $gone, 'stop: SIGTERM ends the entrypoint promptly' );
    is( $? >> 8, 0, 'stop: and cleanly' );
    ok( !$alive->($pool_pid) && !$alive->($ng_pid), 'stop: the pool and nginx went with it' );

    # nginx dying takes the container down, with the others
    unlink "$t/pool.out", "$t/daemon.out", "$t/nginx.out";
    $ep = $start->( NGINX_DIES => 1 );
    my $done = 0;
    for ( 1 .. 100 ) { if ( waitpid( $ep, POSIX::WNOHANG() ) == $ep ) { $done = 1; last } select undef, undef, undef, 0.1 }
    ok( $done, 'nginx dying: the entrypoint exits' );
    isnt( $? >> 8, 0, 'nginx dying: with a failure, so the container is restarted' );
    ($pool_pid) = -s "$t/pool.out" ? slurp("$t/pool.out") =~ /^(\d+)/ : (0);
    select undef, undef, undef, 0.3;
    ok( !$alive->($pool_pid), 'nginx dying: and the pool is stopped, not left serving nothing' );
    like( slurp("$t/run.log"), qr/exited \(?7|exited 7/, 'nginx dying: the log says why' );

    # lazysited exiting 0 (plugin off) does not end the container
    unlink "$t/pool.out", "$t/daemon.out", "$t/nginx.out";
    $ep = $start->( DAEMON_ONCE => 1 );
    ok( $waitfile->("$t/nginx.out") && $waitfile->("$t/daemon.out"), 'daemon off: the others start' );
    select undef, undef, undef, 0.5;
    ok( $alive->($ep), 'daemon off: lazysited exiting 0 leaves the container running' );
    kill 'TERM', $ep;
    for ( 1 .. 100 ) { last if waitpid( $ep, POSIX::WNOHANG() ) == $ep; select undef, undef, undef, 0.1 }
}

# --- shipped with the release --------------------------------------------------
{
    my $cfg = JSON::PP->new->decode( slurp("$root/dist/config/classification.json") );
    opendir my $dh, $pkg or die; my @files = map { "installers/docker/$_" } sort grep { -f "$pkg/$_" } readdir $dh; closedir $dh;
    ok( scalar(@files) >= 6, 'the package has its files' );
    my @excluded = grep { my $f = $_; grep { $f =~ /$_/ } @{ $cfg->{exclude} } } @files;
    is_deeply( \@excluded, [], 'the release does not exclude the package' );

    # The release's own manifest builder, on a tree holding the package: the
    # build refuses an unclassified path (SM1226 hit that), and lists a
    # tarball-only file with install_to null.
    my $stage = "$t/stage";
    for my $f (@files) {
        ( my $d = "$stage/$f" ) =~ s{/[^/]+\z}{};
        system( 'mkdir', '-p',       $d );
        system( 'cp',    "$root/$f", "$stage/$f" );
    }
    my $out = `perl '$root/tools/build-manifest.pl' --staged '$stage' --config '$root/dist/config/classification.json' --version 0.0.1 --out '$t/manifest.json' 2>&1`;
    is( $?, 0, 'build-manifest accepts the package (no unclassified path)' ) or diag $out;
    my $m = -f "$t/manifest.json" ? JSON::PP->new->decode( slurp("$t/manifest.json") ) : { files => [] };
    my %by = map { $_->{path} => $_ } @{ $m->{files} };
    is_deeply( [ sort keys %by ], [ sort @files ], 'every file of the package is in the manifest' );
    my @installed = grep { defined $by{$_}{install_to} } keys %by;
    is_deeply( \@installed, [], 'and none is installed into a site tree' );
}

# --- the docs ------------------------------------------------------------------
{
    my $readme = slurp("$pkg/README.md");
    like( $readme, qr/setup-sysop --user NAME/, 'the README documents the first account' );
    like( $readme, qr/docker compose build/,    'and the local build' );
    like( $readme, qr/lazysite-docroot.*lazysite-settings.*lazysite-private/s, 'and the three volumes' );
    like( slurp("$root/docs/IMPLEMENTOR.md"), qr/Deploying with Docker Compose/, 'the implementor guide has a section' );
    unlike( slurp("$root/README.md"), qr/no Docker image yet/, 'the top README no longer says there is no Docker package' );
}

done_testing;

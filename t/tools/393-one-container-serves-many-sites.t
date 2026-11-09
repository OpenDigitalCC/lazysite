#!/usr/bin/perl
# SM1361 (rulings 201, 205, 206, 208, 210): ONE CONTAINER SERVES MANY SITES.
#
# The container's supervisor (installers/docker/entrypoint.sh) and its sites
# command (installers/docker/lazysite-sites), run for real against a read-only
# image stage built from this checkout, with the REAL install.pl. Only what
# needs a container is stood in for: nginx (a process that counts its reloads),
# each site's pool and runtime (processes that record what they were given and
# can be made to crash), and curl for the status probe.
#
#   - two sites in sites.conf are provisioned on the shared engine at the first
#     start, each with its own server block (its aliases in it) and its own pool;
#   - `lazysite-sites add` starts a third with no restart; `remove` stops it and
#     keeps its folder;
#   - a pool that keeps crashing leaves its site `crashed` and answering 503,
#     the others serving; `status` exits 1 and names it; `restart` brings it back;
#   - Q5: an image older than a site's state refuses that site - 503, the restore
#     command printed - and the restore command, run, brings it up on that image;
#   - ruling 206: a site whose install state cannot be read is refused and named;
#   - SIGTERM stops everything, cleanly.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use POSIX      ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_root repo_manifest_guard site_tempdir);
use PreRenameSite qw(slurp spit);
use PayloadStage  qw(make_stage make_writable);

my $root = repo_root();
my $pkg  = "$root/installers/docker";
my $t    = site_tempdir() =~ s{/site/public_html\z}{}r;    # the base; the sites are built below it

my $POOL = <<"STUB";
use strict; use warnings;
my %a = \@ARGV; my \$i = \$a{'--instance'};
open my \$o, '>', "$t/pool-\$i.out" or die;
print {\$o} join( ' ', \$\$, map { "\$_=" . ( \$ENV{\$_} // '' ) } qw(DOCROOT USER FRONT_DOOR CGIBIN WORKERS) ), "\\n";
close \$o;
exit 3 if -e "$t/crash-\$i";
# Listen on the socket the supervisor waits on before it calls the site serving.
use IO::Socket::UNIX ();
my \$sock = "\$a{'--run-dir'}/\$i.sock"; unlink \$sock;
my \$l = IO::Socket::UNIX->new( Local => \$sock, Listen => 5 ) or die "listen \$sock: \$!";
\$SIG{TERM} = sub { exit 0 };
# Accept and close, so the backlog never fills and no connect waits for ever.
while (1) { my \$c = \$l->accept or next; close \$c }
STUB
my $DAEMON = "use strict; use warnings; \$SIG{TERM} = sub { exit 0 }; sleep 1 while 1;\n";

my $MF    = repo_manifest_guard();
my %stub  = ( 'tools/lazysite-pool.pl' => $POOL, 'tools/lazysited.pl' => $DAEMON );
my $image = make_stage( $MF->path, image => 1, links => [qw(form-handler payment-demo)], overlay => \%stub );
my $version = decode_json( slurp("$image/release-manifest.json") )->{version};
my $older = make_stage( $MF->path, image => 1, links => [qw(form-handler payment-demo)], overlay => \%stub,
    version => '0.16.2' );
END { make_writable($_) for grep {defined} $image, $older }

my $sites = "$t/sites";
my $run   = "$t/run";
make_path($sites);
spit( "$t/nginx", "#!/bin/bash\n[ \"\${1:-}\" = -t ] && exit 0\ntrap 'echo reload >> \"$t/nginx.reloads\"' HUP\ntrap 'exit 0' TERM\n"
        . "echo \$\$ > '$t/nginx.started'\nwhile :; do sleep 0.2; done\n" );
spit( "$t/curl", "#!/bin/bash\nif [ -e '$t/http-down' ]; then printf 000; else printf 200; fi\n" );
chmod 0755, "$t/nginx", "$t/curl";

my %ENVS = (
    LAZYSITE_SITES        => $sites, LAZYSITE_RUN_DIR => $run, LAZYSITE_NGINX_DIR => "$t/nginx.d",
    LAZYSITE_PERL         => $^X,    LAZYSITE_NGINX   => "$t/nginx", LAZYSITE_CURL => "$t/curl",
    LAZYSITE_DAEMON_RETRY => 60,     LAZYSITE_BACKOFF => 1, LAZYSITE_CRASH_LIMIT => 2,
);

# Every entrypoint this test starts is stopped at the end, however the test
# ends, and the test has a deadline.
my @STARTED;
$SIG{ALRM} = sub { die "over the test's 600 s deadline\n" };
alarm 600;
END {
    for my $p (@STARTED) {
        next unless $p && kill 0, $p;
        kill 'TERM', $p;
        for ( 1 .. 100 ) { last if waitpid( $p, POSIX::WNOHANG() ) == $p; select undef, undef, undef, 0.1 }
        kill 'KILL', $p if kill 0, $p;
    }
}

sub start {
    my ($engine) = @_;
    unlink "$t/run.log";
    my $pid = fork() // die;
    if ( !$pid ) {
        delete $ENV{PERL5LIB};
        @ENV{ keys %ENVS } = values %ENVS;
        $ENV{LAZYSITE_ENGINE} = $engine;
        open STDOUT, '>', "$t/run.log";
        open STDERR, '>&', \*STDOUT;
        exec 'bash', "$pkg/entrypoint.sh", 'run';
        exit 127;
    }
    push @STARTED, $pid;
    return $pid;
}

sub stop {
    my ($pid) = @_;
    kill 'TERM', $pid;
    for ( 1 .. 300 ) { return $? >> 8 if waitpid( $pid, POSIX::WNOHANG() ) == $pid; select undef, undef, undef, 0.1 }
    kill 'KILL', $pid;
    return -1;
}

sub sites_cmd {
    my (@args) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    local @ENV{ keys %ENVS } = values %ENVS;
    local $ENV{LAZYSITE_ENGINE} = $ENVS{_engine} // $image;
    my $cmd = join ' ', map {quotemeta} 'bash', "$pkg/lazysite-sites", @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

sub state_of { my ($n) = @_; my $s = slurp("$run/status/$n") // ''; return ( split /\t/, $s )[0] // '' }

sub wait_state {
    my ( $n, $want, $secs ) = @_;
    for ( 1 .. ( $secs // 180 ) * 10 ) { return 1 if state_of($n) eq $want; select undef, undef, undef, 0.1 }
    diag "site $n is '" . state_of($n) . "', not '$want'; the log:\n" . ( slurp("$t/run.log") // '' );
    return 0;
}

sub version_of {
    my ($n) = @_;
    return decode_json( slurp("$sites/$n/html-lazysite/.install-state.json") )->{version};
}

spit( "$sites/sites.conf", "# the sites\nalpha alpha.example.test www.alpha.example.test\nbeta beta.example.test\n" );

# ---- first start ------------------------------------------------------------
my $ep = start($image);
ok( wait_state( 'alpha', 'serving' ) && wait_state( 'beta', 'serving' ), 'first start: both sites serve' );
my $sup = slurp("$run/supervisor.pid");
for my $n (qw(alpha beta)) {
    my $s = decode_json( slurp("$sites/$n/html-lazysite/.install-state.json") );
    is( $s->{engine}, 'shared', "$n: on the shared engine" );
    ok( !-e "$sites/$n/lib" && !-e "$sites/$n/tools", "$n: no engine copy in its folder" );
    ok( -f "$sites/$n/html/manager/index.md", "$n: the manager's pages are copied in" );
}
my $vh = slurp("$t/nginx.d/alpha.conf");
like( $vh, qr/server_name alpha\.example\.test www\.alpha\.example\.test;/, 'alpha: one server block, its alias in it' );
like( $vh, qr{fastcgi_pass unix:\Q$run\E/alpha\.sock;},                    'alpha: to its own pool\'s socket' );
like( $vh, qr{root \Q$sites\E/alpha/html;},                                'alpha: on its own docroot' );
unlike( $vh, qr/__[A-Z]+__/, 'alpha: no placeholder left' );
like( slurp("$t/nginx.d/00-default.conf"), qr{location = /lazysite-health \{ return 204; \}}, 'the health location' );
my $pool = slurp("$t/pool-beta.out") // '';
like( $pool, qr{DOCROOT=\Q$sites\E/beta/html USER=www-data FRONT_DOOR=1 CGIBIN=\Q$image\E WORKERS=2},
    'beta: its own pool, one-rule mode, the image as its cgi-bin, as www-data' );

# ---- add and remove, no restart ------------------------------------------------
my ( $rc, $out ) = sites_cmd( 'add', 'gamma', 'gamma.example.test' );
is( $rc, 0, 'add: succeeds' ) or diag $out;
like( $out, qr/^gamma\s+serving/m, 'add: the new site serves' );
is( slurp("$run/supervisor.pid"), $sup, 'add: without a restart' );
ok( kill( 0, $ep ), 'add: the container is the same one' );
ok( -f "$t/nginx.d/gamma.conf", 'add: its server block is written' );
( $rc, $out ) = sites_cmd( 'add', 'delta', 'beta.example.test' );
isnt( $rc, 0, 'add: a domain another site has is refused' );
like( $out, qr/beta\.example\.test is already another site's domain/, 'add: saying which' );

my ($gpid) = ( slurp("$t/pool-gamma.out") // '' ) =~ /^(\d+)/;
( $rc, $out ) = sites_cmd( 'remove', 'gamma' );
is( $rc, 0, 'remove: succeeds' ) or diag $out;
ok( !-e "$t/nginx.d/gamma.conf" && !-e "$run/status/gamma", 'remove: its block and status go' );
select undef, undef, undef, 0.5;
ok( !( $gpid && kill( 0, $gpid ) ), 'remove: its pool is stopped' );
ok( -d "$sites/gamma/html-lazysite", 'remove: its folder is kept' );
unlike( slurp("$sites/sites.conf"), qr/^gamma /m, 'remove: and it is out of sites.conf' );

# ---- a pool that keeps crashing ------------------------------------------------
spit( "$t/crash-beta", '' );
my ($bpid) = slurp("$t/pool-beta.out") =~ /^(\d+)/;
kill 'TERM', $bpid;
ok( wait_state( 'beta', 'crashed', 60 ), 'crash: beta is left crashed after its crash limit' );
like( slurp("$t/nginx.d/beta.conf"), qr/return 503/, 'crash: and answers 503' );
is( state_of('alpha'), 'serving', 'crash: alpha is untouched' );
ok( kill( 0, $ep ), 'crash: the container runs on' );
( $rc, $out ) = sites_cmd('status');
is( $rc, 1, 'status: exits 1 while a site is not serving' );
like( $out, qr/^beta\s+crashed\s+200\s+its pool exited 3/m, 'status: naming it and why' );
like( $out, qr/^alpha\s+serving\s+200/m, 'status: and the site that serves' );
unlink "$t/crash-beta";
( $rc, $out ) = sites_cmd( 'restart', 'beta' );
like( $out, qr/^beta\s+serving/m, 'restart: beta serves again' );
( $rc, $out ) = sites_cmd('status');
is( $rc, 0, 'status: exits 0 when every site serves' ) or diag $out;

# ---- ruling 206: an install state that cannot be read ---------------------------
is( stop($ep), 0, 'stop: SIGTERM ends the container cleanly' );
ok( !kill( 0, ( slurp("$t/nginx.started") // 0 ) + 0 ), 'stop: nginx went with it' );
my $good = slurp("$sites/beta/html-lazysite/.install-state.json");
spit( "$sites/beta/html-lazysite/.install-state.json", "{ damaged" );
spit( "$sites/alpha/html-lazysite/.install-state.json",
    slurp("$sites/alpha/html-lazysite/.install-state.json") =~ s/"version"\s*:\s*"[^"]*"/"version" : "0.16.2"/r );
$ep = start($image);
ok( wait_state( 'beta', 'refused' ), 'damaged state: the site is refused' );
like( slurp("$run/status/beta"), qr/its install state cannot be read .* lazysite-sites check beta/, 'damaged state: named, with the next step' );
ok( wait_state( 'alpha', 'serving' ), 'damaged state: the other site serves' );
is( version_of('alpha'), $version, 'upgrade: alpha, at 0.16.2, is upgraded to the image' );
my @backups = glob("$sites/alpha/html-lazysite/backups/lazysite-backup-*-pre-$version.tar.gz");
is( scalar @backups, 1, 'upgrade: with a backup taken first' );
is( stop($ep), 0, 'stopped' );
spit( "$sites/beta/html-lazysite/.install-state.json", $good );

# ---- Q5: an older image refuses the newer sites -----------------------------------
$ep = start($older);
ok( wait_state( 'alpha', 'refused' ) && wait_state( 'beta', 'refused' ), 'older image: both sites, newer than it, are refused' );
my $log = slurp("$t/run.log");
like( slurp("$run/status/alpha"), qr/it is at \Q$version\E and this image is 0\.16\.2/, 'older image: saying why' );
like( $log, qr/restore it with:  lazysite-sites restore alpha \Q$backups[0]\E/, 'older image: the restore command is printed' );
like( $log, qr/no backup in \S+\/beta\/html-lazysite\/backups holds a version this image \(0\.16\.2\) can run/, 'older image: and where none holds a version it can run, it says so' );
like( slurp("$t/nginx.d/alpha.conf"), qr/return 503/, 'older image: the refused site answers 503' );
is( version_of('alpha'), $version, 'older image: nothing was changed' );
{
    local $ENVS{_engine} = $older;
    ( $rc, $out ) = sites_cmd( 'restore', 'alpha', $backups[0] );
}
is( $rc, 0, 'restore: succeeds' ) or diag $out;
like( $out, qr/^alpha\s+serving/m, 'restore: alpha serves on the older image' );
is( version_of('alpha'), '0.16.2', 'restore: at the version its backup holds' );
is( state_of('beta'), 'refused', 'restore: beta, not restored, stays refused' );
is( stop($ep), 0, 'stopped' );

done_testing();

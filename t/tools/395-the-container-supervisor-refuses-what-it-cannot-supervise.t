#!/usr/bin/perl
# SM1361 (rulings 206, 218, 220): THE CONTAINER'S SUPERVISOR REFUSES WHAT IT
# CANNOT SUPERVISE.
#
# installers/docker/entrypoint.sh, run against stubs (an engine whose install.pl,
# pool and runtime record what they were given; nginx a process that writes when
# it starts):
#
#   - ruling 220: with a run directory it cannot write (compose's bare tmpfs entry
#     is root 0755) it exits non-zero, naming the path and the tmpfs remedy, and
#     NEVER starts nginx - so the container is never healthy with no supervisor;
#   - ruling 218: a site whose runtime (lazysited) exits 4 - a service state file
#     it cannot tell (SM1417) - is not restarted; the log and `lazysite-sites
#     status` name the file's directory and the remedy, the site's pool serves on,
#     and `lazysite-sites restart` starts the runtime again.
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use POSIX      ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_root site_tempdir);
use PreRenameSite qw(slurp spit);

my $root = repo_root();
my $pkg  = "$root/installers/docker";
my $t    = site_tempdir() =~ s{/site/public_html\z}{}r;    # the base; the stubs live below it

my $eng = "$t/engine";
make_path( "$eng/tools", "$eng/installers/nginx" );
copy( "$root/installers/nginx/vhost-one-rule-pool.conf.example", "$eng/installers/nginx/" ) or die $!;
spit( "$eng/VERSION",               "9.9.9\n" );
spit( "$eng/release-manifest.json", qq({"version":"9.9.9"}) );
spit( "$eng/install.pl", <<"STUB" );
use strict; use warnings;
my (\$d) = grep { \$ARGV[\$_] eq '--docroot' } 0 .. \$#ARGV;
my \$state = \$ARGV[ \$d + 1 ] . '-lazysite/.install-state.json';
open my \$s, '>', \$state or die "\$state: \$!"; print {\$s} qq({"version":"9.9.9"}); close \$s;
STUB
spit( "$eng/tools/lazysite-pool.pl", <<"STUB" );
\$SIG{TERM} = sub { exit 0 };
open my \$o, '>>', '$t/pool.starts'; print {\$o} "\$\$\\n"; close \$o;
use IO::Socket::UNIX ();
my %a = \@ARGV; my \$sock = "\$a{'--run-dir'}/\$a{'--instance'}.sock"; unlink \$sock;
my \$l = IO::Socket::UNIX->new( Local => \$sock, Listen => 5 ) or die "listen \$sock: \$!";
while (1) { my \$c = \$l->accept or next; close \$c }
STUB
spit( "$eng/tools/lazysited.pl",
    "open my \$o, '>>', '$t/daemon.starts'; print {\$o} \"\$\$\\n\"; close \$o; exit 4 if -e '$t/state-damaged'; \$SIG{TERM} = sub { exit 0 }; sleep 1 while 1;\n" );
spit( "$t/nginx", "#!/bin/bash\n[ \"\${1:-}\" = -t ] && exit 0\necho \$\$ >> '$t/nginx.starts'\ntrap 'exit 0' TERM\ntrap '' HUP\nwhile :; do sleep 0.2; done\n" );
spit( "$t/curl", "#!/bin/bash\nprintf 200\n" );
chmod 0755, "$t/nginx", "$t/curl";

my $sites = "$t/sites";
make_path($sites);
spit( "$sites/sites.conf", "alpha alpha.example.test\n" );

my %ENVS = (
    LAZYSITE_ENGINE => $eng, LAZYSITE_SITES => $sites, LAZYSITE_NGINX_DIR => "$t/nginx.d",
    LAZYSITE_PERL   => $^X,  LAZYSITE_NGINX => "$t/nginx", LAZYSITE_CURL => "$t/curl",
    LAZYSITE_DAEMON_RETRY => 60, LAZYSITE_BACKOFF => 1,
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
    my ($run) = @_;
    my $pid = fork() // die;
    if ( !$pid ) {
        delete $ENV{PERL5LIB};
        @ENV{ keys %ENVS } = values %ENVS;
        $ENV{LAZYSITE_RUN_DIR} = $run;
        open STDOUT, '>', "$t/run.log";
        open STDERR, '>&', \*STDOUT;
        exec 'bash', "$pkg/entrypoint.sh", 'run';
        exit 127;
    }
    push @STARTED, $pid;
    return $pid;
}
sub reap {
    my ( $pid, $secs ) = @_;
    for ( 1 .. ( $secs // 30 ) * 10 ) { return $? >> 8 if waitpid( $pid, POSIX::WNOHANG() ) == $pid; select undef, undef, undef, 0.1 }
    return undef;
}
sub sites_cmd {
    my ( $run, @args ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    local @ENV{ keys %ENVS } = values %ENVS;
    local $ENV{LAZYSITE_RUN_DIR} = $run;
    my $cmd = join ' ', map {quotemeta} 'bash', "$pkg/lazysite-sites", @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}
sub lines { my $s = slurp( $_[0] ) // ''; return scalar( () = $s =~ /\n/g ) }
sub wait_for {
    my ( $test, $secs ) = @_;
    for ( 1 .. ( $secs // 30 ) * 10 ) { return 1 if $test->(); select undef, undef, undef, 0.1 }
    return 0;
}

# ---- ruling 220: a run directory it cannot write -----------------------------------
SKIP: {
    skip 'running as root, which can write a 0555 directory', 4 if $> == 0;
    my $locked = "$t/locked-run";
    make_path($locked);
    chmod 0555, $locked;
    my $ep = start("$locked/lazysite");
    my $rc = reap($ep);
    chmod 0755, $locked;
    ok( defined $rc && $rc != 0, 'an unwritable run directory: the entrypoint exits non-zero' );
    my $log = slurp("$t/run.log") // '';
    like( $log, qr{not starting: cannot create or write \Q$locked\E/lazysite}, 'naming the path' );
    like( $log, qr{- /run/lazysite:uid=\d+,gid=\d+,mode=0770}, 'and the tmpfs remedy' );
    ok( !-e "$t/nginx.starts", 'and nginx was never started, so nothing answers healthy' );
}

# ---- ruling 218: a runtime that exits 4 is left down, and named ------------------------
my $run = "$t/run";
spit( "$t/state-damaged", '' );
my $ep = start($run);
ok( wait_for( sub { -e "$run/runtime/alpha" } ), 'exit 4: the site\'s runtime is marked down' );
select undef, undef, undef, 6.5;    # past the 5 s retry the loop gives any other exit
is( lines("$t/daemon.starts"), 1, 'exit 4: and it is not started again' );
like( slurp("$t/run.log") // '', qr{site alpha: its runtime \(lazysited\) refused, exit 4: a state file in \Q$sites\E/alpha/html-lazysite/daemon cannot be read; it is not restarted - repair the file, then: lazysite-sites restart alpha},
    'exit 4: the log names the directory and the remedy' );
ok( kill( 0, ( slurp("$t/pool.starts") // '' ) =~ /(\d+)/ ? $1 : 0 ), 'exit 4: the site\'s pool serves on' );
my ( $rc, $out ) = sites_cmd( $run, 'status' );
is( $rc, 1, 'status: exits 1' );
like( $out, qr{^alpha\s+serving,runtime-down\s+200\s+its runtime refused: a state file in \Q$sites\E/alpha/html-lazysite/daemon cannot be read - see lazysite-sites check alpha}m,
    'status: names the runtime, the directory and the next step' );

unlink "$t/state-damaged";
( $rc, $out ) = sites_cmd( $run, 'restart', 'alpha' );
ok( wait_for( sub { lines("$t/daemon.starts") >= 2 } ), 'restart: the runtime is started again once the file is repaired' );
ok( !-e "$run/runtime/alpha", 'restart: and is no longer marked down' );
( $rc, $out ) = sites_cmd( $run, 'status' );
is( $rc, 0, 'status: exits 0 again' ) or diag $out;

kill 'TERM', $ep;
is( reap($ep), 0, 'stop: cleanly' );

done_testing();

package Odoo::Test::Oomd;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter 'import';
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Select;
use POSIX ();
use Time::HiRes ();

use Odoo::Ops::Daemon;

our @EXPORT_OK = qw(oomd_world oomd_live_world oomd_start oomd_stop oomd_ask oomd_wait_gone slurp spew);

# Helpers for the tests of oomd: a private world (a runtime directory, a state directory, a cache directory, an
# ops config and a daemon config over the CliFake instance) and a daemon started in the foreground as a child.
# Run from the repository root (like every test).

sub spew ($path, $text) {
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return $path;
}

sub slurp ($path) {
    open my $fh, '<', $path or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# oomd_world(%o): { dir, ops_conf, key, runs, env } ; extra => "key = value\n" lines go in every config
sub oomd_world (%o) {
    my $dir = tempdir( 'oomd-XXXXXX', DIR => '/tmp', CLEANUP => !$o{keep} );
    make_path("$dir/runs");
    spew( "$dir/key", "k\n" );
    chmod 0600, "$dir/key";
    my $audit = $o{audit} ? "audit_log = $dir/audit.jsonl\n" : '';
    my $conf = "url = https://odoo.example\ndb = local16\nlogin = tester\napi_key_file = $dir/key\nruns_dir = $dir/runs\nallow_writes = 1\nactor = alice\n${audit}" . ( $o{ops_extra} // '' );
    spew( "$dir/ops.conf", $conf );
    my %env = (
        XDG_RUNTIME_DIR => "$dir/xdg", XDG_STATE_HOME => "$dir/xdg", XDG_CACHE_HOME => "$dir/cache",
        OOM_OPS_TEST_TRANSPORT => 'Odoo::Test::CliFake', ODOO_OPS_NAMESPACES => 'Odoo::Test::Ops,Odoo::Test::OomdOps',
        OOM_OPS_TEST_STATE => $o{state} // "$dir/state.json", ODOO_OOM_PACK_DIRS => $o{pack_dirs} // '/nonexistent',
        PERL5LIB => join( ':', 'lib', 't/lib', grep { defined } $ENV{PERL5LIB} ),
    );
    make_path( "$dir/xdg", "$dir/cache" );
    chmod 0700, "$dir/xdg";
    return { dir => $dir, ops_conf => "$dir/ops.conf", key => "$dir/key", runs => "$dir/runs", env => \%env, conf_text => $conf };
}

# oomd_live_world($ops_conf): a private world over a live instance's ops config. The config's lines are copied (never
# printed) with this world's own runs_dir and without an audit; no fake transport is set.
sub oomd_live_world ($ops_conf, %o) {
    my $dir = tempdir( 'oomd-XXXXXX', DIR => '/tmp', CLEANUP => !$o{keep} );
    make_path("$dir/runs");
    my $text = slurp($ops_conf) // die "cannot read $ops_conf";
    my @keep = grep { !/^\s*(?:runs_dir|audit_log|audit_syslog|audit_required|cache_dir|name)\s*=/ } split /\n/, $text;
    my $name = ( $text =~ /^\s*name\s*=\s*(.+?)\s*$/m )[0];
    my $conf = join( "\n", @keep, "runs_dir = $dir/runs", ( defined $name ? "name = $name" : () ) ) . "\n";
    spew( "$dir/ops.conf", $conf );
    chmod 0600, "$dir/ops.conf";
    make_path( "$dir/xdg", "$dir/cache" );
    chmod 0700, "$dir/xdg";
    my %env = ( XDG_RUNTIME_DIR => "$dir/xdg", XDG_STATE_HOME => "$dir/xdg", XDG_CACHE_HOME => "$dir/cache",
        PERL5LIB => join( ':', 'lib', 't/lib', grep { defined } $ENV{PERL5LIB} ) );
    return { dir => $dir, ops_conf => "$dir/ops.conf", runs => "$dir/runs", env => \%env, conf_text => $conf };
}

# oomd_start($world, name => N, extra => "workers = 2\n", config => PATH): the pid of the foreground daemon, ready
sub oomd_start ($w, %o) {
    my $name = $o{name} // 'test';
    my $path = $o{config} // "$w->{dir}/$name.conf";
    spew( $path, ( $o{conf_text} // $w->{conf_text} ) . ( $o{extra} // "workers = 2\n" ) ) if !$o{config};
    pipe( my $r, my $wr ) or die $!;
    my $err = "$w->{dir}/$name.stderr";
    my $pid = fork // die $!;
    if ( !$pid ) {
        close $r;
        open STDOUT, '>&', $wr;
        open STDERR, '>', $err;
        %ENV = ( %ENV, %{ $w->{env} } );
        exec $^X, 'bin/oomd', '--name', $name, '--config', $path, ( $o{background} ? () : '--foreground' ) or POSIX::_exit(127);
    }
    close $wr;
    $w->{pids}{$name} = $pid;
    my $sel = IO::Select->new($r);
    my $buf = '';
    my $until = Time::HiRes::time() + ( $o{wait} // 15 );
    while ( $buf !~ /\n/ && Time::HiRes::time() < $until ) {
        next if !$sel->can_read(0.2);
        my $n = sysread( $r, $buf, 4096, length $buf );
        last if !$n;
    }
    $w->{ready}{$name} = $buf;
    close $r;
    $w->{socket}{$name} = $buf =~ /\Aoomd \S+ ready (\S+)\n/ ? $1 : undef;
    return $pid;
}

# oomd_stop($world, $name, $signal): the exit status (undef if it would not stop)
sub oomd_stop ($w, $name = 'test', $sig = 'TERM') {
    my $pid = $w->{pids}{$name} or return undef;
    kill $sig, $pid;
    my $until = Time::HiRes::time() + 20;
    while ( Time::HiRes::time() < $until ) {
        my $k = waitpid( $pid, POSIX::WNOHANG() );
        if ( $k == $pid ) { delete $w->{pids}{$name}; return $? >> 8 }
        Time::HiRes::sleep(0.05);
    }
    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    delete $w->{pids}{$name};
    return undef;
}

sub oomd_ask ($w, $name, $req, %o) {
    return Odoo::Ops::Daemon->ask( $w->{socket}{$name}, { v => 1, %$req }, timeout => $o{timeout} // 30 );
}

sub oomd_wait_gone ($pid, $secs = 10) {
    my $until = Time::HiRes::time() + $secs;
    while ( Time::HiRes::time() < $until ) { return 1 if !kill( 0, $pid ); Time::HiRes::sleep(0.05) }
    return 0;
}

1;

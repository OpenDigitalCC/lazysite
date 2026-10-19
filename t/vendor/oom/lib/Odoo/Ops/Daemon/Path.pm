package Odoo::Ops::Daemon::Path;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Errno qw(EINTR);
use File::Spec;
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP ();
use Odoo::JSON ();
use Socket qw(SOCK_STREAM);
use Time::HiRes ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Daemon::Path - where an oomd daemon's files are, and how to ask one

=head1 SYNOPSIS

    my $sock = Odoo::Ops::Daemon::Path->socket_for('site1');
    my $health = Odoo::Ops::Daemon::Path->health( socket => $sock );
    my @running = Odoo::Ops::Daemon::Path->status;

=head1 DESCRIPTION

The part of oomd that both sides of the socket use: the rules for a daemon's
name and the places it keeps its socket, pid record, log and cache, and the
two ways of asking a running daemon (C<ask> and the C<health> verb). It loads
JSON, C<IO::Socket::UNIX> and L<Odoo::Error> and nothing else, so a client
that only talks to a socket (L<Odoo::Ops::Client::Daemon>) does not load the
rest of OOM. The server (L<Odoo::Ops::Daemon>) inherits these as its own class
methods.

=head2 Names and places

C<valid_name($name)>, C<runtime_dir>, C<state_dir>, C<cache_dir($name)>,
C<socket_for($name)> and C<paths($name, %conf)>: where a daemon's files are.
The runtime directory is C<$XDG_RUNTIME_DIR/oomd>, else C</tmp/oomd-UID>.

Each running daemon keeps a small owner-only record there, C<NAME.pid>, of
three lines: its pid, its socket and its name. It is removed when the daemon
exits. C<socket_for> reads the record's socket line first, so a daemon started
with a C<socket> of its own is found by its name.

=cut

my $JSON = Odoo::JSON->new;

sub valid_name ($class, $name) {
    return defined $name && $name =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/ ? 1 : 0;
}

sub _need_name ($class, $name) {
    Odoo::Error->throw( kind => 'usage', message => 'a daemon needs a name (letters, digits, dot, dash, underscore; at most 64)', fix => 'oomd --name NAME --config FILE' )
        if !defined $name || !length $name;
    Odoo::Error->throw( kind => 'usage', message => "'$name' is not a daemon name (letters, digits, dot, dash, underscore; at most 64)" )
        if !$class->valid_name($name);
    return $name;
}

sub runtime_dir ($class) {
    my $x = $ENV{XDG_RUNTIME_DIR};
    return File::Spec->catdir( $x, 'oomd' ) if defined $x && length $x && -d $x;
    return "/tmp/oomd-$<";
}

sub state_dir ($class) {
    my $x = $ENV{XDG_STATE_HOME};
    my $base = defined $x && length $x ? $x : File::Spec->catdir( $ENV{HOME} // ( getpwuid($<) )[7] // '/tmp', '.local', 'state' );
    return File::Spec->catdir( $base, 'oomd' );
}

sub cache_dir ($class, $name) {
    my $x = $ENV{XDG_CACHE_HOME};
    my $base = defined $x && length $x ? $x : File::Spec->catdir( $ENV{HOME} // ( getpwuid($<) )[7] // '/tmp', '.cache' );
    return File::Spec->catdir( $base, 'oomd', $name );
}

sub paths ($class, $name, %conf) {
    $class->_need_name($name);
    my $run = $class->runtime_dir;
    return {
        run    => $run,
        socket => $conf{socket} // File::Spec->catfile( $run, "$name.sock" ),
        pid    => File::Spec->catfile( $run, "$name.pid" ),
        log    => $conf{log} // File::Spec->catfile( $class->state_dir, "$name.log" ),
        cache  => $class->cache_dir($name),
    };
}

# the record's lines: pid, socket, name (an older record has two)
sub record ($class, $name) {
    my $p = $class->paths($name);
    open my $fh, '<', $p->{pid} or return;
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return { pid => $l[0], socket => ( defined $l[1] && $l[1] =~ m{\A/} ? $l[1] : undef ), name => $l[2] // $name, file => $p->{pid} };
}

sub socket_for ($class, $name) {
    $class->_need_name($name);
    my $r = $class->record($name);
    return $r->{socket} if $r && defined $r->{socket};
    return $class->paths($name)->{socket};
}

=head2 Asking a daemon

C<ask($socket, \%request, timeout =E<gt> S)> sends one request line and returns the
response hash; it dies with a C<transport> L<Odoo::Error> (category
C<daemon-down> when nothing is there to answer) when it cannot.
C<health(name =E<gt> N | socket =E<gt> S)> is the C<health> verb's answer.

C<status> lists the daemons of this user: every record in the runtime
directory, with the daemon's health. A record whose pid is gone is removed.

=cut

sub ask ($class, $socket, $req, %o) {
    my $sock = IO::Socket::UNIX->new( Peer => $socket, Type => SOCK_STREAM );
    if ( !$sock ) {
        my $why = $!{ENOENT} ? 'no such socket' : $!{ECONNREFUSED} ? 'nothing is listening' : "$!";
        my $e = Odoo::Error->new( kind => 'transport', code => 'daemon-down', message => "oomd: cannot reach $socket ($why)",
            fix => 'oomd status lists the daemons; start one with oomd --name NAME --config FILE' );
        $e->{unreachable} = 1;
        $e->{why} = $why;
        die $e;
    }
    my $line = $JSON->encode($req) . "\n";
    my $off  = 0;
    local $SIG{PIPE} = 'IGNORE';
    while ( $off < length $line ) {
        my $n = syswrite( $sock, $line, length($line) - $off, $off );
        if ( !defined $n ) { next if $! == EINTR; Odoo::Error->throw( kind => 'transport', message => "oomd: cannot write to $socket: $!" ) }
        $off += $n;
    }
    my $timeout = $o{timeout} // 600;
    my $sel = IO::Select->new($sock);
    my $buf = '';
    my $deadline = $timeout ? Time::HiRes::time() + $timeout : undef;
    while ( $buf !~ /\n/ ) {
        my $wait = $deadline ? $deadline - Time::HiRes::time() : undef;
        Odoo::Error->throw( kind => 'transport', message => "oomd: no answer from $socket within $timeout seconds" ) if defined $wait && $wait <= 0;
        next if !$sel->can_read( defined $wait ? $wait : 5 );
        my $n = sysread( $sock, $buf, 1 << 20, length $buf );
        next if !defined $n && $! == EINTR;
        Odoo::Error->throw( kind => 'transport', message => "oomd: cannot read from $socket: $!" ) if !defined $n;
        Odoo::Error->throw( kind => 'transport', message => "oomd: $socket closed without an answer" ) if $n == 0 && $buf !~ /\n/;
    }
    my ($first) = $buf =~ /\A([^\n]*)\n/;
    my $res = eval { $JSON->decode($first) };
    Odoo::Error->throw( kind => 'transport', message => "oomd: the answer from $socket is not JSON" ) if ref $res ne 'HASH';
    return $res;
}

sub health ($class, %o) {
    my $socket = $o{socket} // $class->socket_for( $o{name} );
    my $res = $class->ask( $socket, { v => 1, verb => 'health' }, timeout => $o{timeout} // 10 );
    Odoo::Error->throw( kind => 'transport', message => "oomd: health failed at $socket" ) if !$res->{ok};
    return $res->{result};
}

sub status ($class) {
    my $run = $class->runtime_dir;
    my @out;
    return @out if !-d $run;
    opendir my $dh, $run or return @out;
    my @names = sort map { /\A(.+)\.(?:pid|sock)\z/ ? $1 : () } readdir $dh;
    closedir $dh;
    my %seen;
    for my $name ( grep { !$seen{$_}++ } @names ) {
        next if !$class->valid_name($name);
        my $p = $class->paths($name);
        my $r = $class->record($name);
        # a record whose process is gone is a leftover: it is removed, not listed
        if ( $r && defined $r->{pid} && $r->{pid} =~ /\A\d+\z/ && !( kill( 0, $r->{pid} ) || $!{EPERM} ) ) {
            unlink $r->{file};
            next if !-S $p->{socket};
            $r = undef;
        }
        my ( $pid, $sock ) = $r ? ( $r->{pid}, $r->{socket} ) : ();
        $sock = $p->{socket} if !defined $sock;
        my $h = eval { $class->health( socket => $sock, timeout => 3 ) };
        push @out, { name => $name, pid => $pid, socket => $sock, ok => $h ? 1 : 0, ( $h ? ( health => $h ) : ( error => ( $@ ? "$@" =~ s/\s+\z//r : 'no answer' ) ) ) };
    }
    return @out;
}

1;

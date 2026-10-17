package Odoo::Ops::Trail;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_APPEND O_CREAT);
use Scalar::Util ();
use Sys::Hostname ();
use Time::HiRes ();

use Odoo::Error;
use Odoo::Ops;

=head1 NAME

Odoo::Ops::Trail - the audit trail of a config: one file and syslog, two levels

=head1 SYNOPSIS

    my $trail = Odoo::Ops::Trail->for_config($config);      # undef when the config names no destination
    $trail->event( apply => op => 'crm.import', run => $id, outcome => 'applied', changes => {...} );

=head1 DESCRIPTION

The audit a config asks for with C<audit_log> and C<audit_syslog> (see
L<Odoo::Ops::Config>). It is shared by every command run with that config:
C<oom-ops>, C<oom-mailshot> and C<oom-accounts> each begin it with
L</program> and end it with L</finish_command>, and a Perl program that builds
an L<Odoo::Ops::Context> gets the same trail, because the Context asks for it.

Every line is one JSON object with C<ts>, C<event>, the fields that say who
(C<actor>, C<actor_from>, C<os_user>, C<login>, C<uid>, C<host>, C<pid>,
C<instance>, C<db>) and the fields of its event. At the C<core> level the
events are C<command plan read approve withdraw close apply revert resume
action refused>; at the C<transaction> level every RPC call is a line as well
(C<event: call>, the record L<Odoo::Ops::Audit> writes). No value is ever
logged: each event has a fixed set of keys and the trail refuses any other.
Parameters are named, never given.

The file is opened C<O_APPEND> and created owner-only; each line leaves in one
C<syswrite>, so two processes appending do not interleave. Syslog gets the
same line (ident C<oom-ops>, C<oom-mailshot> or C<oom-accounts>, option
C<pid>), kept under 4,000 bytes by replacing a long list with its count.

A destination that cannot be opened or written is reported once on standard
error and the command goes on; with C<audit_required = 1> the command does not
start (C<refused/audit-unavailable>) and, when a line fails during the command,
the next call to Odoo is not made.

=cut

my $PROGRAM = 'oom-ops';
my %CMD;
my $CURRENT;
my $ACTOR_OPTION;
my %SYSLOG_OPEN;
my %TRAILS;
my $SYSLOG_CAP = 4000;
my $TOUCHED_CAP = 200;

my @WHO = qw(actor actor_from os_user login uid host pid instance db);
my @COMMON = ( qw(ts event op run outcome), @WHO );

my %EVENT = (
    command  => [qw(command code exit ms calls params)],
    plan     => [qw(buckets input_count models params)],
    read     => [qw(models rows params)],
    approve  => [],
    withdraw => [],
    close    => [qw(reason)],
    apply    => [qw(changes touched touched_count)],
    revert   => [qw(changes touched touched_count)],
    resume   => [qw(changes touched touched_count)],
    action   => [qw(model ids method args_count state_before state_after answer created)],
    refused  => [qw(code)],
    call     => [qw(service model method fault_category ms fields refused_fields for_login second_factor)],
);
my %ALLOWED = map { my $e = $_; $e => { map { $_ => 1 } @COMMON, @{ $EVENT{$e} } } } keys %EVENT;

my %FACILITY = map { $_ => 1 } qw(user auth authpriv daemon local0 local1 local2 local3 local4 local5 local6 local7);

sub facilities ($class) { sort keys %FACILITY }
sub events     ($class) { sort keys %EVENT }
sub event_keys ($class, $event) { @{ $EVENT{$event} // [] } }

# ---- the process: program, command, actor ---------------------------------------------

=head2 Odoo::Ops::Trail->program($name)

Names the program (C<oom-ops>, ...): the syslog ident, and the start of the
command's clock. Called once, first, by each front door.

=cut

sub program ($class, $name) {
    $PROGRAM = $name;
    %CMD     = ( t0 => Time::HiRes::time() );
    return;
}

sub command ($class, $name) { $CMD{name} = $name; return }

=head2 Odoo::Ops::Trail->note(op => ..., run => ..., params => [...])

What the command is about, for its closing C<command> line.

=cut

sub note ($class, %kv) { @CMD{ keys %kv } = values %kv; return }

=head2 Odoo::Ops::Trail->take_actor_option(\@argv)

Removes C<--actor NAME> or C<--actor=NAME> from the argument list (up to a
bare C<-->); with C<leading> only those before the first other
argument (a command that has an option of that name of its own, as C<oom-ops runs>, keeps it) and keeps NAME as the caller's name for the person it serves. The
global option of the three programs.

=cut

sub take_actor_option ($class, $argv, %o) {
    my @keep;
    my $name;
    for ( my $i = 0 ; $i < @$argv ; $i++ ) {
        my $a = $argv->[$i];
        # leading: only what stands before the command word is taken
        if ( $o{leading} && $a ne '--actor' && $a !~ /\A--actor=/ ) { push @keep, @{$argv}[ $i .. $#$argv ]; last }
        if ( $a eq '--' ) { push @keep, @{$argv}[ $i .. $#$argv ]; last }
        if ( $a eq '--actor' ) {
            Odoo::Error->throw( kind => 'usage', message => '--actor needs a name', fix => 'for example --actor "Ann Lee"' )
                if $i == $#$argv || $argv->[ $i + 1 ] eq '';
            $name = $argv->[ ++$i ];
            next;
        }
        if ( $a =~ /\A--actor=(.*)\z/s ) { $name = $1; next }
        push @keep, $a;
    }
    @$argv = @keep;
    Odoo::Error->throw( kind => 'usage', message => '--actor needs a name', fix => 'for example --actor "Ann Lee"' )
        if defined $name && $name eq '';
    $ACTOR_OPTION = $name if defined $name;
    return $name;
}

sub set_actor_option ($class, $name) { $ACTOR_OPTION = $name; return }

=head2 Odoo::Ops::Trail->resolve_actor($config)

C<( $name, $from )>: C<--actor>, then C<ODOO_OOM_ACTOR>, then the config's
C<actor>, then C<$USER>; C<$from> is C<option>, C<env>, C<config> or C<user>.

=cut

sub resolve_actor ($class, $config) {
    return ( $ACTOR_OPTION, 'option' ) if defined $ACTOR_OPTION && length $ACTOR_OPTION;
    return ( $ENV{ODOO_OOM_ACTOR}, 'env' ) if defined $ENV{ODOO_OOM_ACTOR} && length $ENV{ODOO_OOM_ACTOR};
    my $c = $config ? $config->get('actor') : undef;
    return ( $c, 'config' ) if defined $c && length $c;
    return ( $ENV{USER} // 'unknown', 'user' );
}

sub os_user ($class) { scalar( getpwuid($<) ) // "uid$<" }

# ---- one trail per config -------------------------------------------------------------

=head2 Odoo::Ops::Trail->for_config($config, %opt)

The trail of a config (made once per config object), or undef when the config
names no destination. Opens the destinations: with C<audit_required> one that
cannot be opened is C<refused/audit-unavailable>. It is also the process's
current trail, the one L</emit> writes to.

=cut

sub for_config ($class, $config, %opt) {
    return $CURRENT = undef if !$config || !$config->audit_enabled;
    # one trail per process for a destination set and an instance, whichever Config object asks
    my $key = join "\0", map { $_ // '' } map { $config->get($_) } qw(audit_log audit_syslog audit_syslog_facility audit_level audit_required url db login name);
    # a credential given in memory names its own login: the trail speaks for that person
    $key .= "\0" . $opt{login} if defined $opt{login} && $opt{login} ne ( $config->get('login') // '' );
    my $self = $TRAILS{$key};
    if ( !$self ) {
        my ( $actor, $from ) = defined $opt{actor} ? ( $opt{actor}, $opt{actor_from} // 'option' ) : $class->resolve_actor($config);
        my $url_host = ( $config->get('url') // '' ) =~ m{^[a-z]+://([^/:]+)}i ? $1 : undef;
        $self = bless {
            config   => $config,
            level    => $config->audit_level,
            required => $config->audit_required,
            path     => $config->get('audit_log'),
            syslog   => $config->audit_syslog,
            facility => $config->audit_facility,
            now      => $opt{now} // sub { time },
            calls    => 0,
            warned   => {},
            who      => {
                actor      => $actor,
                actor_from => $from,
                os_user    => $class->os_user,
                login      => $opt{login} // $config->get('login'),
                host       => Sys::Hostname::hostname(),
                pid        => $$,
                instance   => $config->get('name') // $url_host,
                db         => $config->get('db'),
            },
        }, $class;
        $self->_open;    # throws with audit_required
        $TRAILS{$key} = $self;
    }
    return $CURRENT = $self;
}

sub current ($class) { $CURRENT }

=head2 Odoo::Ops::Trail->begin(\@argv)

Starts the trail of the config the command line names (C<--conf F> or C<-c F>),
before the command parses anything, so a command that fails on its parameters
leaves its line too, and a required audit that cannot be written stops the
command here. A config that cannot be read is left to the command to report.

=cut

sub begin ($class, $argv) {
    my $path;
    for my $i ( 0 .. $#$argv ) {
        last if $argv->[$i] eq '--';
        $path = $argv->[ $i + 1 ] if $argv->[$i] =~ /\A(?:--conf|-c)\z/ && $i < $#$argv;
        $path = $1 if $argv->[$i] =~ /\A--conf=(.+)\z/s;
    }
    return if !defined $path;
    require Odoo::Ops::Config;
    my $config = eval { Odoo::Ops::Config->load($path) } or return;
    return $class->for_config($config);
}

=head2 Odoo::Ops::Trail->emit($event, %data)

An event on the current trail; nothing when there is none.

=cut

sub emit ($class, $event, %data) {
    return if !$CURRENT;
    return $CURRENT->event( $event, %data );
}

sub set_uid_source ($self, $client) {
    Scalar::Util::weaken( my $c = $client );
    $self->{uid_source} = sub { $c && ref $c ? $c->{uid} : undef };
    return;
}

sub calls ($self) { $self->{calls} }
sub level ($self) { $self->{level} }
sub who   ($self) { my %w = %{ $self->{who} }; my $u = $self->_uid; $w{uid} = $u if defined $u; \%w }

sub _uid ($self) {
    my $u = $self->{uid_source} ? $self->{uid_source}->() : undef;
    return defined $u && $u =~ /\A\d+\z/ ? 0 + $u : undef;
}

# ---- destinations ---------------------------------------------------------------------

sub _unavailable ($self, $reason) {
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'audit-unavailable',
        message => $reason,
        fix     => 'make the audit destination writable, or take audit_required out of the config (the config\'s owner decides)',
    );
}

sub _open ($self) {
    if ( defined $self->{path} ) {
        if ( sysopen( my $fh, $self->{path}, O_WRONLY | O_APPEND | O_CREAT, 0600 ) ) {
            $self->{fh} = $fh;
        }
        else {
            my $why = "cannot open $self->{path}: $!";
            $self->_unavailable($why) if $self->{required};
            $self->_warn( $self->{path}, "audit: cannot write to $self->{path}: $!" );
        }
    }
    if ( $self->{syslog} ) {
        my $ok = eval {
            require Sys::Syslog;
            my $key = "$PROGRAM|$self->{facility}";
            if ( !$SYSLOG_OPEN{$key} ) {
                # ndelay: a syslog that cannot be reached shows now, not at the first line
                Sys::Syslog::openlog( $PROGRAM, $self->{required} ? 'pid,ndelay' : 'pid', $self->{facility} );
                $SYSLOG_OPEN{$key} = 1;
            }
            1;
        };
        if ( !$ok ) {
            my $why = _clean($@);
            $self->_unavailable("syslog: $why") if $self->{required};
            $self->_warn( 'syslog', "audit: cannot write to syslog: $why" );
            $self->{syslog_down} = 1;
        }
    }
    return;
}

sub _clean ($err) {
    $err = "$err";
    $err =~ s/ at \S+ line \d+\.?\n?//g;
    $err =~ s/\s+\z//;
    return $err;
}

sub _warn ($self, $dest, $text) {
    return if $self->{warned}{$dest}++;
    print STDERR "$text\n";
    return;
}

# A line that cannot be written: said once on stderr; with audit_required the next
# call to Odoo is refused (check).
sub _fail ($self, $dest, $reason) {
    if ( $self->{required} ) {
        $self->{broken} //= $dest eq 'syslog' ? "syslog: $reason" : "cannot write $dest: $reason";
        return;
    }
    $self->_warn( $dest, "audit: cannot write to $dest: $reason" );
    return;
}

=head2 check

Throws C<refused/audit-unavailable> when the trail is required and a line
could not be written: called before each call to Odoo.

=cut

sub check ($self) {
    $self->_unavailable( $self->{broken} ) if $self->{required} && $self->{broken};
    return;
}

sub broken ($self) { $self->{required} ? $self->{broken} : undef }

sub _write ($self, $line, $outcome_hint) {
    my $json = Odoo::Ops::json()->encode($line);
    if ( defined $self->{path} ) {
        if ( !$self->{fh} ) {
            $self->_fail( $self->{path}, 'not open' );
        }
        else {
            my $text = "$json\n";
            no warnings q(closed);
            my $n    = syswrite( $self->{fh}, $text );
            if ( !defined $n )            { $self->_fail( $self->{path}, "$!" ) }
            elsif ( $n != length $text )  { $self->_fail( $self->{path}, 'short write' ) }
        }
    }
    $self->_syslog( $line, $json ) if $self->{syslog};
    return;
}

sub _priority ($outcome) {
    return 'info' if !defined $outcome;
    return 'warning' if $outcome =~ /\A(?:refused|usage|config|partly-applied|partly-reverted)\z/;
    return 'err'     if $outcome =~ /\A(?:fault|transport|failed)\z/;
    return 'info';
}

# the syslog copy: under the cap, a long list replaced by its count
sub _syslog_text ($line, $json) {
    return $json if length($json) < $SYSLOG_CAP;
    my %l = %$line;
    my @lists = sort { length( Odoo::Ops::json()->encode( $l{$b} ) ) <=> length( Odoo::Ops::json()->encode( $l{$a} ) ) }
        grep { ref $l{$_} eq 'ARRAY' } keys %l;
    # the named lists first, then the longest of the rest
    my @order = ( ( grep { $_ eq 'fields' || $_ eq 'touched' } @lists ), ( grep { $_ ne 'fields' && $_ ne 'touched' } @lists ) );
    for my $k (@order) {
        $l{ $k . '_count' } //= @{ $l{$k} };
        delete $l{$k};
        $json = Odoo::Ops::json()->encode( \%l );
        last if length($json) < $SYSLOG_CAP;
    }
    return $json;
}

sub _syslog ($self, $line, $json) {
    return if $self->{syslog_down};
    my $text = _syslog_text( $line, $json );
    my $ok = eval { Sys::Syslog::syslog( _priority( $line->{outcome} ), '%s', $text ); 1 };
    $self->_fail( 'syslog', _clean($@) ) if !$ok;
    return;
}

# ---- lines ----------------------------------------------------------------------------

=head2 event($name, %data)

One core line. Refuses an event or a key outside the set that event has.

=cut

sub event ($self, $name, %data) {
    my $allowed = $ALLOWED{$name}
        or Odoo::Error->throw( kind => 'usage', message => "audit has no event '$name'" );
    for my $k ( keys %data ) {
        Odoo::Error->throw( kind => 'usage', message => "audit event $name cannot carry '$k'" ) if !$allowed->{$k};
    }
    my %line = ( ts => $self->{now}->(), event => $name, %{ $self->who } );
    $CMD{op}  = $data{op}  if defined $data{op};
    $CMD{run} = $data{run} if defined $data{run};
    # a list too long for a line: the first part and the count
    if ( ref $data{touched} eq 'ARRAY' && @{ $data{touched} } > $TOUCHED_CAP ) {
        my $n = @{ $data{touched} };
        $data{touched}       = [ @{ $data{touched} }[ 0 .. $TOUCHED_CAP - 1 ] ];
        $data{touched_count} = $n;
    }
    delete $data{$_} for grep { !defined $data{$_} } keys %data;
    @line{ keys %data } = values %data;
    $self->_write( \%line, $data{outcome} );
    return;
}

=head2 call(\%record)

An RPC call's record, from L<Odoo::Ops::Audit>: counted, and written as an
C<event: call> line at the C<transaction> level.

=cut

sub call ($self, $rec) {
    $self->{calls}++ if ( $rec->{service} // '' ) ne 'web' && ( $rec->{outcome} // '' ) ne 'refused';
    return if $self->{level} ne 'transaction';
    my %rec = %$rec;
    my $ts  = delete $rec{ts};
    my %line = ( ts => $ts // $self->{now}->(), event => 'call', %{ $self->who }, %rec );
    for my $k ( keys %line ) {
        Odoo::Error->throw( kind => 'usage', message => "audit event call cannot carry '$k'" ) if !$ALLOWED{call}{$k};
    }    $self->_write( \%line, $line{outcome} );
    return;
}

# ---- the command line -----------------------------------------------------------------

=head2 Odoo::Ops::Trail->command_error($err)

Keeps the error a command ended with; a refusal is also a C<refused> line.

=cut

sub command_error ($class, $err) {
    $CMD{error} = $err;
    my $e = Scalar::Util::blessed($err) && $err->isa('Odoo::Error') ? $err : undef;
    if ( $CURRENT && $e && $e->kind eq 'refused' ) {
        eval { $CURRENT->event( refused => outcome => 'refused', code => $e->code // 'refused', ( map { defined $CMD{$_} ? ( $_ => $CMD{$_} ) : () } qw(op run) ) ) };
    }
    return;
}

sub _outcome_of ($err, $status, $command = '') {
    if ( Scalar::Util::blessed($err) && $err->isa('Odoo::Error') ) {
        my $k = $err->kind;
        return $k =~ /\A(?:refused|fault|transport|usage|config)\z/ ? $k : 'fault';
    }
    return 'fault' if defined $err;
    return 'ok' if !$status;
    # doctor's exit 1 is a warning in its report, not a refusal
    return $status == 1 ? 'ok' : 'fault' if $command eq 'doctor';
    return $status == 2 ? 'config' : $status == 1 ? 'refused' : 'fault';
}

=head2 Odoo::Ops::Trail->finish_command($status)

Writes the C<command> line, from an C<END> block, so a command that died
leaves its line too. C<$status> is C<$?>, the exit status the program returns.
When the trail is required and a line could not be written, says so on
standard error and exits 1.

=cut

sub finish_command ($class, $status) {
    my $t = $CURRENT or return;
    return if $CMD{finished}++ || !defined $CMD{name};
    my $err = $CMD{error};
    my $out = _outcome_of( $err, $status, $CMD{name} );
    my $e   = Scalar::Util::blessed($err) && $err->isa('Odoo::Error') ? $err : undef;
    eval {
        $t->event(
            command => command => $CMD{name}, outcome => $out, exit => $status // 0,
            ms => int( ( Time::HiRes::time() - ( $CMD{t0} // Time::HiRes::time() ) ) * 1000 ),
            calls => $t->calls,
            ( $e && $e->kind eq 'refused' ? ( code => $e->code // 'refused' ) : () ),
            ( defined $CMD{op}  ? ( op  => $CMD{op} )  : () ),
            ( defined $CMD{run} ? ( run => $CMD{run} ) : () ),
            ( ref $CMD{params} eq 'ARRAY' ? ( params => $CMD{params} ) : () ),
        );
    };
    if ( my $why = $t->broken ) {
        print STDERR "oom: refused/audit-unavailable: $why\n";
        $? = 1 if !$status;
    }
    return;
}

# for tests: forget the process state
sub reset ($class) {
    %CMD = ();
    $CURRENT = $ACTOR_OPTION = undef;
    %SYSLOG_OPEN = ();
    %TRAILS = ();
    return;
}

1;

package Odoo::Ops::Context;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Path qw(make_path);
use File::Spec;
use Scalar::Util ();
use Time::HiRes ();

use Odoo::Client;
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Audit;
use Odoo::Ops::Credential;
use Odoo::Ops::Guard;
use Odoo::Ops::Profile;
use Odoo::Ops::Trail;

=head1 NAME

Odoo::Ops::Context - one guarded connection, its profiles, audit and runs

=head1 SYNOPSIS

    my $ctx = Odoo::Ops::Context->new(config => Odoo::Ops::Config->load($path));
    my $odoo    = $ctx->client;              # Odoo::Client behind the guard
    my $profile = $ctx->profile('crm');      # loaded for the server's series
    my $dir     = $ctx->run_dir('crm.export');

=head1 DESCRIPTION

Builds the client the operations use: the real transport (from the
config, or C<transport> passed in for tests) wrapped in an
L<Odoo::Ops::Guard>, credentials from L<Odoo::Ops::Credential>, and an
L<Odoo::Ops::Audit> sink. With a run directory the audit is written to
C<audit.jsonl> there; before one exists, records stay in memory and
are flushed into it when it is created.

The audit of the config (C<audit_log>, C<audit_syslog>, C<audit_level>,
C<audit_required>; see L<Odoo::Ops::Config> and L<Odoo::Ops::Trail>) belongs to
this route. A Perl program that builds a Context and uses C<< $ctx->client >>
goes through the L<Odoo::Ops::Guard>, so its calls and the events it causes are
audited exactly as the commands' are, at the same level, and with
C<audit_required> the Context is refused (C<refused/audit-unavailable>) when the
audit cannot be written. The actor is C<actor> passed to C<new>, else
C<ODOO_OOM_ACTOR>, the config's C<actor> or C<$USER>.

C<now> (a coderef returning epoch seconds) is injectable so tests are
deterministic.

=head2 A key in memory

    my $ctx = Odoo::Ops::Context->new(
        config     => $config,      # url, db, login (the service's own), audit_*
        credential => { login => 'jane@example.com', api_key => $key },
        actor      => 'jane@example.com',
    );

This is how a calling program runs as a person whose API key it holds, with
no key file: a lazysite sign-in that keeps the person's key for the session
is the case. The context authenticates as C<login> with C<api_key>, and every
operation, guard decision and audit line is that person's: the audit's C<login>
is C<jane@example.com> and the config's C<login> is left out of it. The key
stays in this hash and in the client; it is in no error message, audit line,
plan, journal or report (C<t/62-keys.t> searches for it). C<core.whoami> run on
the context reports C<login>, C<< credential => 'api_key' >> and the key's
name, scope and expiry, never its value. Odoo refuses the key when its login is
archived, when the key was deleted or has expired; the refusal is a
C<credential> fault whose C<fix> names C<oom-accounts probe>.

=cut

sub new ($class, %args) {
    my $config = $args{config}
        or Odoo::Error->throw( kind => 'config', message => 'context needs config' );
    my $now = $args{now} // sub { time };

    my %cred = $args{credential} ? %{ $args{credential} } : Odoo::Ops::Credential->resolve($config);
    # who the context runs as: the login of a credential given in memory, else the config's
    my $login = defined $cred{login} && length $cred{login} ? $cred{login} : $config->get('login');
    my $kind  = $cred{session} ? 'session' : defined $cred{password} ? 'password' : 'api_key';
    # the password strategy: login and password become a web session
    my $password  = delete $cred{password};
    my $pw_file   = delete $cred{password_file};
    my $by_login  = defined $password;
    my $inner = $args{transport} // do {
        my %backend = (
            jsonrpc => 'Odoo::Transport::JSONRPC',
            xmlrpc  => 'Odoo::Transport::XMLRPC',
            json2   => 'Odoo::Transport::JSON2',
            session => 'Odoo::Transport::Session',
        );
        # a session credential selects the session transport
        my $name = $cred{session} || $by_login ? 'session' : ( $config->get('transport') // 'jsonrpc' );
        my $pkg  = $backend{$name}
            or Odoo::Error->throw( kind => 'config', message => "unknown transport '$name'" );
        require( $pkg =~ s{::}{/}gr . '.pm' );
        $pkg->new(
            url                => $config->get('url'),
            timeout            => $config->get('timeout') // 120,
            max_response_bytes => $config->get('max_response_bytes'),
            ssl_ca_file        => $config->get('ssl_ca_file'),
            ssl_verify         => $config->get('ssl_verify'),
            ( $cred{session} ? ( session => $cred{session} ) : () ),
        );
    };
    delete $cred{session};
    if ($by_login) {
        # the session answers who is calling; no login or key rides the calls
        delete $cred{login};
    }

    my ( $actor, $actor_from ) = defined $args{actor} ? ( $args{actor}, 'option' ) : Odoo::Ops::Trail->resolve_actor($config);
    # the shared audit of the config, opened (and, when required, proved writable) before any call
    my $trail = Odoo::Ops::Trail->for_config( $config, now => $now, actor => $actor, actor_from => $actor_from, login => $login );
    my $audit = Odoo::Ops::Audit->new( now => $now, trail => $trail );
    my $guard = Odoo::Ops::Guard->new(
        inner => $inner,
        audit => $audit,
        actor => $actor,
        login => $login,
    );

    my %ctx;
    $ctx{lang} = $config->get('lang') if $config->get('lang');
    $ctx{tz}   = $config->get('tz')   if $config->get('tz');

    my $client = Odoo::Client->new(
        url       => $config->get('url'),
        db        => $config->get('db'),
        %cred,
        transport => $guard,
        context   => \%ctx,
        ( $args{retries} ? ( retries => $args{retries} ) : () ),
    );
    $trail->set_uid_source($client) if $trail;

    my $self = bless {
        config   => $config,
        client   => $client,
        guard    => $guard,
        audit    => $audit,
        trail    => $trail,
        actor    => $actor,
        now      => $now,
        profiles => {},
        profile_dirs => $args{profile_dirs} // [ grep {defined} $config->get('profile_dir') ],
        password_file => $pw_file,
        login         => $login,
        credential_kind => $kind,
    }, $class;
    # a session that expires mid-run is opened again, once, for the call that met it
    if ( $by_login && $inner->can('set_reauth') ) {
        Scalar::Util::weaken( my $me = $self );    # the transport must not keep the context alive
        $inner->set_reauth( sub { $me->open_session } );
    }
    # the session is opened at start; doctor asks to open it itself so a
    # refused login is a line of its report, not a failure to begin
    $self->open_session($password)
        if $by_login && !$args{defer_login} && !( $inner->can('session_id') && defined $inner->session_id );
    return $self;
}

sub config ($self) { $self->{config} }
sub client ($self) { $self->{client} }
sub guard  ($self) { $self->{guard} }
sub audit  ($self) { $self->{audit} }
sub trail  ($self) { $self->{trail} }
sub actor  ($self) { $self->{actor} }
sub now    ($self) { $self->{now}->() }

=head2 credential_kind

Which credential this context uses: C<api_key> (a key, from C<api_key_file> or
given in memory), C<password> (a login and a password file, exchanged for a web
session) or C<session> (a web session id the caller holds). Never the value.

=cut

sub credential_kind ($self) { $self->{credential_kind} }

=head2 session_transport

The web-session transport under the guard (the one a C<password> or
C<session> credential selects), or undef when the connection is an RPC
transport. It is the only thing that can fetch a report route, which Odoo
answers to a web session alone.

=cut

sub session_transport ($self) {
    my $t = $self->{guard}->inner;
    return $t if $t->can('session_id') && $t->can('authenticate');
    return undef;
}

=head2 can_reopen_session

True when the credential is C<password>: a lost session can be opened
again from the password file.

=cut

sub can_reopen_session ($self) { defined $self->{password_file} }

=head2 open_session($password, %opts)

Authenticates the session transport with the login and the password (read
again from C<password_file> when not given) and returns the identity.
Called at start by a C<password> context, and again by an operation that
meets a lost session. The password is not kept.

When Odoo wants the second factor (the user has two-factor on) the call dies
with C<kind =E<gt> 'fault'>, category C<second-factor-required> and a C<fix:>
line: ask the person for their Odoo authenticator code and complete the
sign-in with L</complete_totp>. The half-open session is kept on the
transport. C<trusted_device =E<gt> VALUE> is passed on to
L<Odoo::Transport::Session/authenticate>; a device Odoo still trusts signs in
without a code. The sign-in is recorded in the audit as a C<web> call
carrying C<second_factor: totp>; the password, the code and the trusted-device
value are not.

=cut

sub open_session ($self, $password = undef, %opts) {
    my $t = $self->session_transport
        or Odoo::Error->throw( kind => 'usage', message => 'this connection has no web session to open' );
    $password //= Odoo::Ops::Credential->secret_file( $self->{password_file}, 'password_file' )
        if defined $self->{password_file};
    Odoo::Error->throw( kind => 'refused', code => 'needs-session', message => 'no password to open a web session with',
        fix => 'a config whose credential is password (login and password_file)' )
        if !defined $password;
    my $id = $t->authenticate( $self->{config}->get('db'), $self->{login}, $password,
        ( defined $opts{trusted_device} ? ( trusted_device => $opts{trusted_device} ) : () ) );
    return $id if !$id->{pending};
    $self->{guard}->audit_web( 'session.authenticate', 'answered', 0, second_factor => 'totp' );
    Odoo::Error->throw( kind => 'fault', message => "this user's sign-in needs the second factor (Odoo's authenticator code)",
        fault_class => 'oom.SecondFactorRequired',
        fix => 'ask the person for their Odoo authenticator code and complete the sign-in with complete_totp' );
}

=head2 complete_totp($code, remember =E<gt> 0|1)

Finishes a sign-in that C<open_session> left waiting for the code
(L<Odoo::Transport::Session/complete_totp>) and returns the identity. A wrong
code dies as category C<second-factor> and the sign-in stays open. Recorded
in the audit as a C<web> call C<session.totp> carrying C<second_factor: totp>
and its outcome (C<answered>, or C<fault> with the category); the code is not
in the record.

=cut

sub complete_totp ($self, $code, %opts) {
    my $t = $self->session_transport
        or Odoo::Error->throw( kind => 'usage', message => 'this connection has no web session to complete' );
    my $t0 = Time::HiRes::time();
    my $id = eval { $t->complete_totp( $code, %opts ) };
    my $err = $@;
    my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );
    if ($err) {
        my $cat = ref $err && $err->can('fault_category') ? $err->fault_category : undef;
        $self->{guard}->audit_web( 'session.totp', 'fault', $ms, second_factor => 'totp', ( defined $cat ? ( fault_category => $cat ) : () ) );
        die $err;
    }
    $self->{guard}->audit_web( 'session.totp', 'answered', $ms, second_factor => 'totp' );
    return $id;
}

sub approval     ($self) { $self->{config}->approval }
sub plan_ttl     ($self) { $self->{config}->plan_ttl }
sub instance     ($self) { $self->{config}->instance }
sub allow_writes ($self) { $self->{config}->allow_writes }

=head2 profile($pack)

The pack's profile for this server, loaded once. The series is the
config's C<profile_series> if set, otherwise the server's own. The profile
reads the installed modules through L<Odoo::Ops::Modules> when it needs them.

=cut

sub profile ($self, $pack) {
    return $self->{profiles}{$pack} //= do {
        my $p = Odoo::Ops::Profile->load(
            pack   => $pack,
            series => $self->{config}->get('profile_series') // $self->{client}->server_series,
            dirs   => $self->{profile_dirs},
        );
        # validate asks which modules are installed only when a field it maps is missing
        Scalar::Util::weaken( my $me = $self );
        $p->modules_from( sub { require Odoo::Ops::Modules; $me ? Odoo::Ops::Modules->installed($me) : undef } );
        $p;
    };
}

=head2 behaviour($model)

The L<Odoo::Ops::Behaviour> of a physical model for this server's
series (cached; an unknown model answers an empty behaviour).

=cut

sub behaviour ($self, $model) {
    require Odoo::Ops::Behaviour;
    return $self->{behaviours}{$model} //= Odoo::Ops::Behaviour->load(
        model  => $model,
        series => $self->{config}->get('profile_series') // $self->{client}->server_series,
        dirs   => $self->{profile_dirs},
    );
}

=head2 run_dir($op_name)

Creates and returns C<< <runs_dir>/<UTC stamp>-<op> >> (once per
context), and redirects the audit to C<audit.jsonl> inside it.

=cut

sub run_dir ($self, $op) {
    return $self->{run_dir} if $self->{run_dir};
    my $root = $self->{config}->get('runs_dir')
        or Odoo::Error->throw( kind => 'config', message => 'config has no runs_dir' );
    my $stamp = Odoo::Ops::iso_time( $self->now ) =~ tr/-:TZ//dr;
    my $base  = File::Spec->catdir( $root, "$stamp-$op" );
    my ( $dir, $n ) = ( $base, 1 );
    $dir = $base . '-' . ++$n while -e $dir;
    make_path($dir);
    $self->use_run_dir($dir);
    return $dir;
}

=head2 use_run_dir($dir)

Adopts an existing run directory (apply writes next to its plan).

=cut

sub use_run_dir ($self, $dir) {
    my $held = $self->{audit}->records;
    my $file = Odoo::Ops::Audit->new(
        path  => File::Spec->catfile( $dir, 'audit.jsonl' ),
        now   => $self->{now},
        trail => $self->{trail},
    );
    $file->replay(%$_) for @$held;
    $self->{audit} = $file;
    $self->{guard}->set_audit($file);
    $self->{run_dir} = $dir;
    return $dir;
}

1;

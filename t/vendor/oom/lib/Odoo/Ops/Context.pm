package Odoo::Ops::Context;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Path qw(make_path);
use File::Spec;
use Scalar::Util ();

use Odoo::Client;
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Audit;
use Odoo::Ops::Credential;
use Odoo::Ops::Guard;
use Odoo::Ops::Profile;

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

C<now> (a coderef returning epoch seconds) is injectable so tests are
deterministic.

=cut

sub new ($class, %args) {
    my $config = $args{config}
        or Odoo::Error->throw( kind => 'config', message => 'context needs config' );
    my $now = $args{now} // sub { time };

    my %cred = $args{credential} ? %{ $args{credential} } : Odoo::Ops::Credential->resolve($config);
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

    my $actor = $args{actor} // $config->get('actor') // $ENV{USER} // 'unknown';
    my $audit = Odoo::Ops::Audit->new( now => $now );
    my $guard = Odoo::Ops::Guard->new(
        inner => $inner,
        audit => $audit,
        actor => $actor,
        login => $config->get('login'),
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

    my $self = bless {
        config   => $config,
        client   => $client,
        guard    => $guard,
        audit    => $audit,
        actor    => $actor,
        now      => $now,
        profiles => {},
        profile_dirs => $args{profile_dirs} // [ grep {defined} $config->get('profile_dir') ],
        password_file => $pw_file,
        login         => $config->get('login'),
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
sub actor  ($self) { $self->{actor} }
sub now    ($self) { $self->{now}->() }

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

=head2 open_session($password)

Authenticates the session transport with the login and the password (read
again from C<password_file> when not given) and returns the identity.
Called at start by a C<password> context, and again by an operation that
meets a lost session. The password is not kept.

=cut

sub open_session ($self, $password = undef) {
    my $t = $self->session_transport
        or Odoo::Error->throw( kind => 'usage', message => 'this connection has no web session to open' );
    $password //= Odoo::Ops::Credential->secret_file( $self->{password_file}, 'password_file' )
        if defined $self->{password_file};
    Odoo::Error->throw( kind => 'refused', code => 'needs-session', message => 'no password to open a web session with',
        fix => 'a config whose credential is password (login and password_file)' )
        if !defined $password;
    return $t->authenticate( $self->{config}->get('db'), $self->{login}, $password );
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
        path => File::Spec->catfile( $dir, 'audit.jsonl' ),
        now  => $self->{now},
    );
    $file->record(%$_) for @$held;
    $self->{audit} = $file;
    $self->{guard}->set_audit($file);
    $self->{run_dir} = $dir;
    return $dir;
}

1;

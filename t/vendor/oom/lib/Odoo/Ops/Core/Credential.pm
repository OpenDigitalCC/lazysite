package Odoo::Ops::Core::Credential;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Core::User;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Credential - change your own password, turn two-factor on or off, at once

=head1 SYNOPSIS

    # in memory, from a program that holds the person's session
    my $op = Odoo::Ops::Core::Credential->new( ctx => $ctx, params => { action => 'change-password' } );
    my $now = $op->perform( old => $old, new => $new );

    # two-factor on: the secret and the URI once, then the code
    my $step = Odoo::Ops::Core::Credential->new( ctx => $ctx, params => { action => 'totp-enable' } )
        ->perform( password => $pw );
    my $done = Odoo::Ops::Core::Credential->new( ctx => $ctx, params => { action => 'totp-enable', wizard => $step->{wizard} } )
        ->perform( password => $pw, code => $code );

    # at a terminal: the secrets on standard input, never as --set values
    oom-ops run core.credential --conf me.conf --set action=change-password

=head1 DESCRIPTION

C<core.credential> is an operation of a kind of its own, C<immediate>. It is
never planned: it has no plan, no run folder, no journal and no approval, and
C<oom-ops run> applies it at once. A plan and its journal are files, and a
password given to one would be kept at rest. This operation keeps nothing and
echoes nothing.

It runs as the person whose credential the context holds (a web session, a
login and password, or a key given in memory): you change your own password,
not someone else's. Password change and two-factor only.

The secrets are not parameters. A program gives them to C<perform> in memory;
C<oom-ops run> reads them from standard input, one per line (without echo
when standard input is a terminal), so that no value is in shell history, the
process list, a file or the audit.

=head2 Actions

    change-password  perform(old, new), or two lines on standard input: the
                     old password, the new one. Odoo's res.users
                     change_password(old, new), called as the user. Answers
                     Odoo's own answer; the password is not read back.
    totp-enable      two-factor on, in Odoo's own enable wizard. Step one,
                     perform(password) or one line: opens the wizard (the
                     identity check is Odoo's, with the password) and answers
                     the wizard's number, the secret and the provisioning URI,
                     once, to the caller only, for the person to scan. Step two,
                     with wizard => N, perform(password, code) or two lines:
                     the password and the authenticator's code. Reads
                     totp_enabled back. A wrong code is Odoo's refusal in
                     Odoo's words and the wizard stays, so the code can be
                     given again.
    totp-disable     two-factor off through Odoo's identity check:
                     perform(password) or one line. Reads totp_enabled back.

Two-factor needs a web session (a C<password> or C<session> credential: the
identity check belongs to the session) and the C<auth_totp> module; without
them the action is C<refused/needs-session> or C<refused/not-applicable>.

=head2 What is answered, audited and refused

The answer is what is now true: C<action>, Odoo's answer for a password
change, C<two_factor> C<on> or C<off> with C<verified> for the other two. The
only secrets in an answer are the TOTP secret and URI of C<totp-enable> step
one. The audit (L<Odoo::Ops::Trail>) records C<event: credential>, the
C<action>, the login and the C<outcome> (and, for a fault, its
C<fault_category>): never a value, and not the length of one. Odoo's refusals
are passed on in Odoo's words: a wrong old password, a password its policy
refuses, a wrong code.

=cut

sub op_name   ($class) { 'core.credential' }
sub summary   ($class) { 'Change your own password or turn two-factor on or off, at once: nothing is planned, stored or echoed' }
sub pack      ($class) { undef }
sub immediate ($class) { 1 }
sub writes    ($class) { 0 }

sub params ($class) {
    {   action => { type => 'str', required => 1,
            help => 'change-password | totp-enable | totp-disable. The secrets are read from standard input, one per line: '
                  . 'change-password: old, new; totp-enable: password (then, with wizard=N, password and code); totp-disable: password' },
        wizard => { type => 'int',
            help => 'totp-enable step two: the wizard number step one answered' },
    };
}

# the secrets each action takes, in the order standard input gives them
my %SECRETS = (
    'change-password' => [qw(old new)],
    'totp-enable'     => [qw(password)],
    'totp-disable'    => [qw(password)],
);

sub actions ($class) { sort keys %SECRETS }

# the models and methods the actions call; the guard refuses any other
sub write_scope ($class) {
    {   'res.users'                => [qw(change_password action_totp_enable_wizard action_totp_disable)],
        'res.users.identitycheck'  => [qw(write run_check)],
        'auth_totp.wizard'         => [qw(read write enable)],
    };
}

=head2 secret_names($params)

Class method: the names of the secrets C<perform> takes for these params,
in the order C<oom-ops> reads them from standard input.

=cut

sub secret_names ($class, $params) {
    my $action = $params->{action} // '';
    my @n = @{ $SECRETS{$action} // [] };
    push @n, 'code' if $action eq 'totp-enable' && defined $params->{wizard};
    return @n;
}

=head2 read_secrets($params, $fh)

Class method: the secrets for these params from a handle, one per line. On a
terminal each is asked for on standard error without echo. A missing line is
refused by name.

=cut

sub read_secrets ($class, $params, $fh) {
    my %s;
    my $tty = -t $fh;
    for my $name ( $class->secret_names($params) ) {
        my $line = $tty ? _ask( $fh, $name ) : scalar <$fh>;
        Odoo::Error->throw( kind => 'usage', message => "core.credential $params->{action}: the $name is missing from standard input",
            fix => 'give ' . join( ', ', $class->secret_names($params) ) . ' on standard input, one per line' )
            if !defined $line;
        chomp $line;
        $s{$name} = $line;
    }
    return %s;
}

sub _ask ($fh, $name) {
    require POSIX;
    my $term = POSIX::Termios->new;
    $term->getattr( fileno $fh );
    my $lflag = $term->getlflag;
    $term->setlflag( $lflag & ~POSIX::ECHO() );
    $term->setattr( fileno $fh, POSIX::TCSANOW() );
    print STDERR "$name: ";
    my $line = <$fh>;
    $term->setlflag($lflag);
    $term->setattr( fileno $fh, POSIX::TCSANOW() );
    print STDERR "\n";
    return $line;
}

# an immediate operation has no plan and no report: it is performed
sub run ($self) {
    Odoo::Error->throw( kind => 'usage', message => 'core.credential is applied at once and keeps nothing: it has no plan or report',
        fix => 'call perform with the secrets in memory, or oom-ops run core.credential with them on standard input' );
}

=head2 perform(%secrets)

Does the action as the context's user, at once, and returns what is now true
(a hashref). C<%secrets> are C<old> and C<new>, or C<password> and C<code>;
they are used and not kept. The audit gets one C<credential> event whatever
the outcome.

=cut

sub perform ($self, %secret) {
    my $action = $self->param('action');
    my @need   = $self->secret_names( $self->all_params );
    my @lack   = grep { !defined $secret{$_} || !length $secret{$_} } @need;
    my $out = eval {
        Odoo::Error->throw( kind => 'usage', message => "core.credential $action needs the " . join( ' and the ', @lack ),
            fix => 'oom-ops describe core.credential lists the actions' ) if @lack;
        $self->ctx->guard->with_scope( $self->scope_for('apply'), $self->op_name, sub { $self->_do( $action, \%secret ) } );
    };
    my $err = $@;
    $secret{$_} = undef for keys %secret;
    $self->_audit( $action, $err );
    die $err if $err;
    return $out;
}

sub _audit ($self, $action, $err) {
    my $trail = $self->ctx->can('trail') ? $self->ctx->trail : undef;
    return if !$trail;
    my ( $outcome, $cat ) = ( 'ok', undef );
    if ($err) {
        my $e = ref $err && eval { $err->isa('Odoo::Error') } ? $err : undef;
        $outcome = $e ? ( $e->kind =~ /\A(?:refused|fault|transport|usage|config)\z/ ? $e->kind : 'fault' ) : 'fault';
        $cat     = $e ? $e->fault_category : undef;
    }
    eval { $trail->event( credential => op => $self->op_name, action => $action, outcome => $outcome, fault_category => $cat ) };
    return;
}

sub _do ($self, $action, $s) {
    return $self->_change_password($s) if $action eq 'change-password';
    return $self->_totp_enable($s)     if $action eq 'totp-enable';
    return $self->_totp_disable($s)    if $action eq 'totp-disable';
    Odoo::Error->throw( kind => 'usage', message => "core.credential has no action '$action' (known: " . join( ', ', $self->actions ) . ')',
        fix => 'oom-ops describe core.credential lists the actions' );
}

sub _change_password ($self, $s) {
    my $answer = $self->client->model('res.users')->call( 'change_password', [ $s->{old}, $s->{new} ] );
    return { action => 'change-password', answer => ( $answer ? 1 : 0 ) };
}

# two-factor needs the session the identity check belongs to, and the module
sub _totp_ready ($self) {
    my $ctx = $self->ctx;
    Odoo::Error->throw( kind => 'refused', code => 'needs-session',
        message => 'core.credential: two-factor is turned on and off in a web session, and this connection has none',
        fix => 'use a config whose credential is password (login and password_file), or a session credential' )
        if ( $ctx->credential_kind // '' ) eq 'api_key';
    my $users = $self->client->model('res.users');
    Odoo::Error->throw( kind => 'refused', code => 'not-applicable',
        message => 'core.credential: not applicable here: module auth_totp is not installed',
        fix => 'two-factor needs the auth_totp module on the instance' )
        if !$users->fields->{totp_enabled};
    return $users;
}

sub _totp_state ($self, $users, $uid) { $users->read_one( $uid, ['totp_enabled'] )->{totp_enabled} ? 1 : 0 }

sub _totp_enable ($self, $s) {
    my $users  = $self->_totp_ready;
    my $client = $self->client;
    my $uid    = $client->uid;
    my $series = $client->server_series;
    my $wizard = $self->param('wizard');
    my $wm     = $client->model('auth_totp.wizard');
    if ( !defined $wizard ) {
        my $act = $users->call( 'action_totp_enable_wizard', [ [$uid] ] );
        $act = Odoo::Ops::Core::User->_identity_check( $client, $act, $s->{password}, $series );
        Odoo::Error->throw( kind => 'fault', message => 'Odoo gave no two-factor wizard' )
            if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'auth_totp.wizard' || !$act->{res_id};
        my $w = $wm->read_one( $act->{res_id}, [ 'secret', 'url' ] );
        Odoo::Error->throw( kind => 'fault', message => 'the two-factor wizard showed no secret' ) if !$w->{secret};
        return { action => 'totp-enable', step => 'secret', wizard => $act->{res_id}, secret => $w->{secret}, uri => $w->{url} };
    }
    # step two: Odoo's enable on the wizard step one opened; its identity check is answered with the password.
    # The code goes to Odoo as the string it is: a caller that used it as a number would have it sent as one.
    my $code = "$s->{code}";
    my $act;
    if ( $series < 19 ) {
        $wm->write( $wizard, { code => $code } );
        $act = $wm->call( 'enable', [ [$wizard] ] );
    }
    else {
        $act = $wm->call( 'enable', [ [$wizard] ], context => { code => $code } );
    }
    Odoo::Ops::Core::User->_identity_check( $client, $act, $s->{password}, $series );
    my $now = $self->_totp_state( $users, $uid );
    return { action => 'totp-enable', step => 'enabled', two_factor => $now ? 'on' : 'off', verified => $now ? 1 : 0 };
}

sub _totp_disable ($self, $s) {
    my $users  = $self->_totp_ready;
    my $client = $self->client;
    my $uid    = $client->uid;
    my $act    = $users->call( 'action_totp_disable', [ [$uid] ] );
    Odoo::Ops::Core::User->_identity_check( $client, $act, $s->{password}, $client->server_series );
    my $now = $self->_totp_state( $users, $uid );
    return { action => 'totp-disable', two_factor => $now ? 'on' : 'off', verified => $now ? 0 : 1 };
}

1;

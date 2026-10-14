package Odoo::Client;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed looks_like_number);

use Odoo::Error;
use Odoo::Model;

our $VERSION = '0.09';

=head1 NAME

Odoo::Client - session and RPC plumbing for the Odoo mapper

=head1 SYNOPSIS

    my $odoo = Odoo::Client->new(
        url          => 'https://example.odoohost.net',
        db           => 'example-db',
        login        => 'integration-user',
        api_key_file => '/path/to/key',      # or api_key => '...'
        transport    => 'xmlrpc',            # default 'jsonrpc'; or 'json2' (19+)
        context      => { lang => 'en_GB' },
    );

    say $odoo->version->{server_version};
    my $partners = $odoo->model('res.partner');
    my $rows = $partners->search_read([['is_company', '=', 1]], ['name'],
                                      limit => 10);

=head1 DESCRIPTION

Holds the connection details, authenticates lazily on first use, and
funnels every call through C<execute_kw> with the default context
merged in. Transport-kind errors are retried on a ladder (default
0/2/5/15 seconds); server faults are raised immediately.

The API key is read once and never appears in error messages or logs.
In Odoo an API key is simply used in place of the password, so
C<password> is accepted as a synonym for C<api_key>.

=head1 METHODS

=head2 new(%args)

Required: C<url>, C<db>, C<login>, and one of C<api_key>,
C<password>, C<api_key_file>. Optional: C<transport> ('jsonrpc', 'xmlrpc', 'json2' (19+, API key), or an object with a C<call> method), C<context> (hashref
merged into every call, call-site context winning), C<timeout>
(seconds, default 120), C<ssl_ca_file> (a private CA to trust),
C<ssl_verify> (0 only in a lab), C<max_response_bytes> (cap on one answer;
over it the call dies as kind C<refused>; default none),
C<retries> (arrayref of pre-attempt sleeps,
default [0, 2, 5, 15]), C<overlay> (a namespace searched for
per-model behaviour classes - see C<record_class> in
L<Odoo::Model>).

=head2 version / uid / whoami

C<version> asks the server (no auth needed). C<uid> authenticates on
first call and caches the numeric user id. C<whoami> reads back the
login and display name of the authenticated user.

=head2 execute_kw($model, $method, \@args, \%kwargs)

The raw escape hatch every higher layer uses.

=head2 model($name)

Returns a cached L<Odoo::Model> handle; no pre-declared class needed.

=head2 models(%opts)

Model discovery via C<ir.model>: returns a sorted arrayref of model
names, or with C<< detail => 1 >> an arrayref of
C<{model, name}> rows. C<< match => qr/.../ >> filters by model name.

Note that many Odoo deployments restrict reading C<ir.model> records
to administrative groups, in which case this faults with an access
error even though C<< model($name)->fields >> works fine - per-model
introspection needs no special rights.

=cut

sub new ($class, %args) {
    for my $req (qw(url db)) {
        Odoo::Error->throw(kind => 'config', message => "$req required")
            if !defined $args{$req};
    }
    Odoo::Error->throw(kind => 'config', message => 'login required')
        if !defined $args{login} && !( blessed($args{transport}) && _carries_session($args{transport}) );
    my $key = $args{api_key} // $args{password};
    if (!defined $key && defined $args{api_key_file}) {
        $key = _read_key_file($args{api_key_file});
    }
    # a session transport (or a guard around one) already knows who is
    # calling: no key is needed, and none is carried
    my $sessioned = blessed($args{transport}) && _carries_session($args{transport});
    Odoo::Error->throw(
        kind    => 'config',
        message => 'one of api_key, password, api_key_file required',
    ) if ( !defined $key || $key eq '' ) && !$sessioned;

    my $self = bless {
        url     => $args{url},
        db      => $args{db},
        login   => $args{login},
        key     => $key,
        context => $args{context} // {},
        retries => $args{retries} // [0, 2, 5, 15],
        overlay => $args{overlay},
        models  => {},
    }, $class;

    my $transport = $args{transport} // 'jsonrpc';
    if (blessed($transport) || (ref $transport && ref($transport) ne '')) {
        Odoo::Error->throw(
            kind    => 'config',
            message => 'transport object must provide a call method',
        ) if !eval { $transport->can('call') };
        $self->{transport} = $transport;
    }
    else {
        my %backend = (
            jsonrpc => 'Odoo::Transport::JSONRPC',
            xmlrpc  => 'Odoo::Transport::XMLRPC',
            json2   => 'Odoo::Transport::JSON2',
        );
        my $pkg = $backend{$transport}
            or Odoo::Error->throw(
                kind    => 'config',
                message => "unknown transport '$transport'",
            );
        my $file = $pkg =~ s{::}{/}gr . '.pm';
        require $file;
        $self->{transport} = $pkg->new(
            url                => $args{url},
            timeout            => $args{timeout} // 120,
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        );
    }
    return $self;
}

sub _read_key_file ($path) {
    open my $fh, '<', $path
        or Odoo::Error->throw(
            kind    => 'config',
            message => "cannot read api_key_file $path: $!",
        );
    my $key = <$fh>;
    close $fh;
    chomp $key if defined $key;
    return $key;
}

sub url       ($self) { $self->{url} }
sub db        ($self) { $self->{db} }
sub login     ($self) { $self->{login} }
sub transport ($self) { $self->{transport} }
sub overlay   ($self) { $self->{overlay} }

sub version ($self) {
    return $self->_call('common', 'version');
}

=head2 server_series

The Odoo major series as a plain integer (16, 17, ...), parsed from
the server's version string and cached. Use it for the rare
version-conditional code path; prefer feature detection where the
server can tell us directly.

=cut

sub server_series ($self) {
    return $self->{server_series} //= do {
        my $v = $self->version->{server_version} // '';
        my ($major) = $v =~ /^(\d+)/;
        Odoo::Error->throw(
            kind    => 'fault',
            message => "cannot parse server version '$v'",
        ) if !$major;
        0 + $major;
    };
}

sub uid ($self) {
    return $self->{uid} //= $self->_authenticate;
}

# the transport, or the innermost transport a guard wraps, when it is
# a session transport
sub _session_transport ($t) {
    while ( blessed($t) ) {
        return $t if $t->can('session_id') && $t->can('identity');
        last if !$t->can('inner_transport');
        $t = $t->inner_transport;
    }
    return undef;
}
sub _carries_session ($t) { !!_session_transport($t) }

=head2 web_session

A new, unauthenticated L<Odoo::Transport::Session> to the same server,
sharing the connection's HTTP client (so the same CA and timeouts).
For the few Odoo actions that exist only over a web session as the
user concerned (an API key is minted that way). The caller
C<authenticate>s it and C<destroy>s it. A transport that provides its
own C<web_session> (a test double) is asked first.

=cut

sub web_session ($self) {
    my $t = $self->{transport};
    $t = $t->inner_transport while blessed($t) && $t->can('inner_transport');
    return $t->web_session if blessed($t) && $t->can('web_session');
    Odoo::Error->throw( kind => 'usage', message => 'this transport cannot open a web session (it has no HTTP client)' )
        if !( blessed($t) && $t->can('http') );
    require Odoo::Transport::Session;
    return Odoo::Transport::Session->new( url => $self->{url}, http => $t->http );
}

=head2 session_identity

For a client on a session transport: what authentication said about
the user (see L<Odoo::Transport::Session/identity>); undef otherwise.

=cut

sub session_identity ($self) {
    my $t = _session_transport( $self->{transport} ) or return undef;
    $self->uid if !$t->identity;    # a resumed session learns who it is
    $self->{login} //= $t->identity->{login} if $t->identity;
    return $t->identity;
}

sub _authenticate ($self) {
    my $uid = $self->_call(
        'common', 'authenticate',
        $self->{db}, $self->{login}, $self->{key}, {},
    );
    if (!defined $uid || !looks_like_number($uid) || !$uid) {
        Odoo::Error->throw(
            kind    => 'fault',
            message => "authentication failed for '$self->{login}' on '$self->{db}'",
        );
    }
    return $uid;
}

=head2 verify_credentials($login, $secret, %opts)

For applications that let people log in with their Odoo credentials:
asks the server to authenticate C<$login> with C<$secret> and returns
the numeric uid on success, undef on refusal. Transport problems
still die, so "server unreachable" is never mistaken for "wrong
password".

C<$secret> may be the user's password or any of their Odoo API keys -
the wire treats them identically. One caveat: a user with two-factor
authentication enabled cannot RPC-authenticate by password; Odoo
refuses it, and such users must use an API key.

This does not touch the client's own session or cached uid, and needs
no special rights - any client instance can verify third-party
credentials. C<< db => >> overrides the database to check against.

=cut

sub verify_credentials ($self, $login, $secret, %opts) {
    my $uid = $self->_call(
        'common', 'authenticate',
        $opts{db} // $self->{db}, $login, $secret, {},
    );
    return ( defined $uid && looks_like_number($uid) && $uid ) ? $uid : undef;
}

sub whoami ($self) {
    my $rows = $self->execute_kw(
        'res.users', 'read',
        [ [ $self->uid ] ],
        { fields => [qw(login name)] },
    );
    return $rows->[0];
}

sub execute_kw ($self, $model, $method, $args = [], $kwargs = {}) {
    my %kw  = %$kwargs;
    my %ctx = (%{ $self->{context} }, %{ delete($kw{context}) // {} });
    $kw{context} = \%ctx if %ctx;
    return $self->_call(
        'object', 'execute_kw',
        $self->{db}, $self->uid, $self->{key},
        $model, $method, $args, \%kw,
    );
}

sub model ($self, $name) {
    return $self->{models}{$name} //=
        Odoo::Model->new(client => $self, name => $name);
}

sub models ($self, %opts) {
    my $rows = $self->execute_kw(
        'ir.model', 'search_read',
        [ [] ],
        { fields => [qw(model name)], order => 'model' },
    );
    if (my $match = $opts{match}) {
        $rows = [ grep { $_->{model} =~ $match } @$rows ];
    }
    return $rows if $opts{detail};
    return [ map { $_->{model} } @$rows ];
}

# Retry ladder: each entry is a sleep before that attempt. Transport
# errors walk the ladder; faults and anything else surface at once.
sub _call ($self, $service, $method, @args) {
    my @ladder = @{ $self->{retries} };
    @ladder = (0) if !@ladder;
    my $last;
    for my $delay (@ladder) {
        sleep $delay if $delay;
        my $result;
        my $ok = eval { $result = $self->{transport}->call($service, $method, @args); 1 };
        return $result if $ok;
        $last = $@;
        die $last
            if !(blessed($last) && $last->isa('Odoo::Error') && $last->is_transport);
    }
    die $last;
}

1;

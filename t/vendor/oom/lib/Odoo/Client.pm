package Odoo::Client;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed looks_like_number);

use Odoo::Transport::Session ();
use Odoo::Error;
use Odoo::Model;
use Odoo::Portable;

our $VERSION = '0.27';

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

A client made with C<new> directly has no guard and no audit; the audited route is
L<Odoo::Ops::Context>, whose C<client> goes through the guard and the config's audit trail.

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

The raw escape hatch every higher layer uses. The rows of C<read> and
C<search_read> come back with every empty char, text, html, date,
datetime, selection, binary, reference and many2one as undef: Odoo sends
C<false> for them and the transports decode it as C<0>, so the field's
C<fields_get> type decides, once, here. A string C<"0"> is a value; a
number or a boolean is left as it is.

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

=head2 own_web_session

A web session (see L</web_session>) already authenticated as this
client's own login, with the client's secret given as the password. It
serves the few actions that exist only over a web session as the
connection's user (an administrator turning another user's two-factor
off). It works where the secret is that user's password, as in the
local cluster's configs; a real API key is refused by the web login
(category C<credential>, read live on 16, 18 and 19, 2026-10-13). The
caller C<destroy>s it. Dies as C<usage> for a client that holds no
secret (a session client).

=cut

sub own_web_session ($self) {
    Odoo::Error->throw( kind => 'usage', message => 'this client holds no login and key to open a web session with' )
        if !defined $self->{login} || !defined $self->{key} || $self->{key} eq '';
    my $web = $self->web_session;
    Odoo::Transport::Session::require_signed_in( $web, $web->authenticate( $self->{db}, $self->{login}, $self->{key} ) );
    return $web;
}

=head2 own_secret

The client's own key, for the one place a second use of it is needed: the
identity check Odoo asks for after C<own_web_session>. Never print it or
write it anywhere.

=cut

sub own_secret ($self) {
    Odoo::Error->throw( kind => 'usage', message => 'this client holds no key' ) if !defined $self->{key} || $self->{key} eq '';
    return $self->{key};
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
            kind        => 'fault',
            fault_class => 'oom.AuthRefused',
            message     => "authentication failed for '$self->{login}' on '$self->{db}' (Odoo answered false and gave no reason)",
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

=head2 session_groups

The groups of the user this client acts as (for a session transport,
the person whose session is carried), as C<< [ { id, name, xmlid? } ] >>
sorted by name; an empty list for a user with none. A page may show or
hide a section by them; Odoo remains what refuses a call.

The field is read from C<fields_get> (C<group_ids> from 19, C<groups_id>
before), never guessed. The user's own row is read with C<res.users.read>
(inside the L<Odoo::Ops::Guard> base scope); the names come from
C<res.groups> (C<full_name>, else C<display_name>, else C<name>), a
second read the Guard's base scope does not cover, so an operation that
calls this declares C<res.groups> C<read> (C<core.whoami> does). C<xmlid>
is present only when the user may read C<ir.model.data> (an
administrator); a person's session is refused it and the key is left out.

On 16 to 18 the field holds the groups with those they imply; from 19 it
holds the groups assigned directly (read live 2026-10-13).

=head2 session_groups_report

The same read as a hash: C<groups> (as above), C<groups_readable> (1, or
0 when Odoo refused the read of C<res.groups>: a portal user's session
may be; then C<groups> is the empty list, not a fault) and C<field> (the
physical field read). Other faults, and a transport failure, still die.

=cut

sub session_groups ($self, %opt) { $self->session_groups_report(%opt)->{groups} }

sub session_groups_report ($self, %opt) {
    my $users = $self->model('res.users');
    my $field = $users->fields->{group_ids} ? 'group_ids' : 'groups_id';
    my $row   = $users->read_one( $self->uid, [$field] );
    my $ids   = ref $row->{$field} eq 'ARRAY' ? $row->{$field} : [];
    return { groups => [], groups_readable => 1, field => $field } if !@$ids;

    my $gm    = $self->model('res.groups');
    my $gf    = $gm->fields;
    my ($name_field) = grep { $gf->{$_} } qw(full_name display_name name);
    my $rows = eval { $gm->call( 'read', [$ids], fields => [ $name_field // 'display_name' ] ) };
    if ( my $err = $@ ) {
        return { groups => [], groups_readable => 0, field => $field }
            if blessed($err) && $err->isa('Odoo::Error') && $err->is_access_denied;
        die $err;
    }
    my %xml;
    if ( $opt{xmlids} // 1 ) {
        my $x = eval {
            $self->model('ir.model.data')->search_read(
                [ [ 'model', '=', 'res.groups' ], [ 'res_id', 'in', $ids ] ], [qw(module name res_id)] );
        };
        if ( ref $x eq 'ARRAY' ) { $xml{ $_->{res_id} } = "$_->{module}.$_->{name}" for @$x }
    }
    my @groups = map { +{ id => $_->{id}, name => $_->{ $name_field // 'display_name' } // '',
            ( $xml{ $_->{id} } ? ( xmlid => $xml{ $_->{id} } ) : () ) } } @$rows;
    @groups = sort { lc $a->{name} cmp lc $b->{name} or $a->{id} <=> $b->{id} } @groups;
    return { groups => \@groups, groups_readable => 1, field => $field };
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
    my $result = $self->_call(
        'object', 'execute_kw',
        $self->{db}, $self->uid, $self->{key},
        $model, $method, $args, \%kw,
    );
    return $self->_empty_groups( $model, $args->[2], $result ) if $method eq 'read_group';
    return $result if $method ne 'read' && $method ne 'search_read';
    return $self->_empties_as_undef( $model, $result );
}

# A read_group row names its group by the field (or field:granularity) it was grouped on, and
# the group of records with nothing there is Odoo's false, decoded as 0. For a field of a type
# that is empty as false (and a many2many or one2many, which group by false too) that group is
# the empty value. A boolean or a number groups by its own value, 0 included.
sub _empty_groups ($self, $model, $groupby, $rows) {
    return $rows if ref $rows ne 'ARRAY' || !@$rows || ref $groupby ne 'ARRAY';
    my $fields = eval { $self->model($model)->fields };
    return $rows if ref $fields ne 'HASH';
    for my $spec (@$groupby) {
        my ($name) = split /:/, $spec;
        my $type = $fields->{$name} && $fields->{$name}{type};
        next if !defined $type || !( Odoo::Portable::empty_is_false($type) || $type =~ /\A(?:many2many|one2many)\z/ );
        for my $row (@$rows) {
            $row->{$spec} = undef if ref $row eq 'HASH' && exists $row->{$spec} && Odoo::Portable::is_false_value( $row->{$spec} );
        }
    }
    return $rows;
}

# The one place Odoo's false becomes an empty value. The wire sends false
# for an empty char, text, html, date, datetime, selection, binary,
# reference and many2one, and the transports decode it as 0. Every read
# funnels through here, so the field types from fields_get decide once
# and every surface (Model, Record, operations) sees undef.
sub _empties_as_undef ($self, $model, $rows) {
    return $rows if ref $rows ne 'ARRAY' || !@$rows || ref $rows->[0] ne 'HASH';
    my $fields = eval { $self->model($model)->fields };
    return $rows if ref $fields ne 'HASH';
    Odoo::Portable::empty_row( $fields, $_ ) for @$rows;
    return $rows;
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

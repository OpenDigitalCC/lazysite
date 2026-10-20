package Odoo::Client;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);

use Odoo::Transport ();
use Odoo::Transport::Session ();
use Odoo::Cache ();
use Odoo::Error;
use Odoo::Model;
use Odoo::Portable;

our $VERSION = '0.38';

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

=head2 The cache

With C<cache> (an L<Odoo::Cache>; L<Odoo::Ops::Context> passes one unless the
config says C<cache = 0>) a new client does not start from nothing:

=over

=item * The uid of an API key is kept per url, db, login and a SHA-256
fingerprint of the key (never the key), and used instead of C<authenticate>,
which Odoo makes slow on purpose. The first call Odoo refuses for credentials
or access (or a missing user record, which is how Odoo answers a uid it does
not know) while the uid is only remembered authenticates once, keeps the uid
it learns and, when that is another uid, makes that call again once; a wrong key has no remembered uid and is
refused by C<authenticate> as before. A client on a session transport, or with
no key, remembers no uid.

=item * C<version> is kept per url for C<cache_ttl_version> seconds (default
300; 0 keeps nothing). C<< version( fresh => 1 ) >> always asks.

=item * C<fields_get> (through L<Odoo::Model/fields>) is kept per url, db,
model, login and language, and used while the state of the C<ir.model.fields>
rows (the newest row, the number of rows and the newest C<write_date>) is the one it
was kept at. That state is read once per process, shared between processes for
C<cache_ttl_fields_stamp> seconds (default 5; 0 reads it in every process) in a small file of the
cache directory, with three calls for every model: a read per model would cost what the
C<fields_get> it saves costs. A module installed or upgraded, or a field made,
moves it and each model's fields are read again when next used. A login that
may not read C<ir.model.fields> keeps nothing, unless the program that made the client names a login that
may (C<stamp_source>, a coderef answering the state as C<fields_stamp> reads it, with C<stamp_source_name> naming that
login for the shared record): the state is a fact about the server, so it is read there once and checked for
every login, while each login's definitions stay in its own files and are never read for another.

=back

The files hold ids, definitions and dates; no key, password, session id or
field value.
}) ;

# constructor

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
        cache   => $args{cache},
        ttl_version => $args{cache_ttl_version} // 300,
        # how long the state of ir.model.fields is shared between processes through the cache directory
        ttl_fields_stamp => $args{cache_ttl_fields_stamp} // 5,
        # a resident program lends the state of ir.model.fields from one client to the next (per login)
        stamp_memory => $args{stamp_memory},
        # a program that holds a login which may read ir.model.fields reads the state for every other login
        stamp_source => $args{stamp_source},
        stamp_source_name => $args{stamp_source_name},
        now     => $args{now} // sub { time },
        # a remembered uid or field list is for a key that says who is calling
        keyed   => ( defined $key && $key ne '' && !$sessioned ) ? 1 : 0,
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

sub version ($self, %opt) {
    my $cache = $self->{cache};
    return $self->_call('common', 'version') if !$cache || $self->{ttl_version} <= 0;
    my $url   = $self->{url};
    my $kept  = $cache->recall('version.json');
    my $entry = ref $kept eq 'HASH' ? $kept->{$url} : undef;
    my $now   = $self->{now}->();
    return $entry->{version}
        if !$opt{fresh} && ref $entry eq 'HASH' && ref $entry->{version} eq 'HASH'
        && $entry->{at} && $now - $entry->{at} < $self->{ttl_version} && $now >= $entry->{at};
    my $v = $self->_call('common', 'version');
    if ( ref $v eq 'HASH' ) {
        $kept = {} if ref $kept ne 'HASH';
        $kept->{$url} = { at => $now, version => $v };
        $cache->keep( 'version.json', $kept );
    }
    return $v;
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
    return $self->{uid} if defined $self->{uid};
    if ( defined( my $kept = $self->_remembered_uid ) ) {
        $self->{uid_unproven} = 1;
        return $self->{uid} = $kept;
    }
    my $uid = $self->_authenticate;
    $self->_remember_uid($uid);
    return $self->{uid} = $uid;
}

# The name of this identity in the uid file: a digest of url, db, login and
# the key's own digest. Nothing in the name or the file can give the key back
# short of guessing it.
sub _uid_entry ($self) {
    return Odoo::Cache->digest( 'uid', $self->{url}, $self->{db}, $self->{login}, Odoo::Cache->digest( 'key', $self->{key} ) );
}

sub _remembered_uid ($self) {
    return undef if !$self->{cache} || !$self->{keyed};
    my $kept = $self->{cache}->recall('uid.json');
    my $e    = ref $kept eq 'HASH' ? $kept->{ $self->_uid_entry } : undef;
    return ref $e eq 'HASH' && defined $e->{uid} && $e->{uid} =~ /\A[1-9]\d*\z/ ? 0 + $e->{uid} : undef;
}

sub _remember_uid ($self, $uid) {
    return if !$self->{cache} || !$self->{keyed};
    my $kept = $self->{cache}->recall('uid.json');
    $kept = {} if ref $kept ne 'HASH';
    if ( defined $uid ) {
        $kept->{ $self->_uid_entry } = { uid => 0 + $uid, url => $self->{url}, db => $self->{db}, login => $self->{login} };
    }
    else {
        delete $kept->{ $self->_uid_entry };
    }
    $self->{cache}->keep( 'uid.json', $kept );
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
    my $result = $self->_object_call( $model, $method, $args, \%kw );
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

# One object call. While the uid is only remembered, a call Odoo refuses for
# credentials, access or a missing record is met once by a real authenticate:
# the uid may be a user since replaced (Odoo answers a uid it does not know with
# a MissingError on res.users, probed on 16, 18 and 19), or the key since revoked
# (then authenticate refuses it in Odoo's words). When authenticate gives the uid
# already held the refusal was the call's own and is raised as it came; when it
# gives another the call is made again, once. The first answer that is not such a
# refusal proves the uid.
sub _object_call ($self, $model, $method, $args, $kw) {
    my $result = eval {
        $self->_call( 'object', 'execute_kw', $self->{db}, $self->uid, $self->{key}, $model, $method, $args, $kw );
    };
    if ( my $err = $@ ) {
        die $err if !$self->{uid_unproven}
            || !( blessed($err) && $err->isa('Odoo::Error') && $err->is_fault
                && ( $err->is_invalid_credential || $err->is_access_denied || $err->is_missing ) );
        delete $self->{uid_unproven};
        my $held = delete $self->{uid};
        $self->_remember_uid(undef);
        die $err if $self->uid == $held;
        $result = $self->_call( 'object', 'execute_kw', $self->{db}, $self->uid, $self->{key}, $model, $method, $args, $kw );
    }
    delete $self->{uid_unproven};
    return $result;
}

=head2 fields_cached($model, \&fetch)

The C<fields_get> answer of C<$model>: from the cache when it is kept and the
model's C<ir.model.fields> has not changed since, else C<fetch> is called and
its answer kept. With no cache, or when this login may not read
C<ir.model.fields>, it is C<fetch> every time. C<stamp_memory> (a hash a resident program keeps and gives to each client) makes the check of
C<ir.model.fields> once per login in C<cache_ttl_version> seconds instead of once per client.

=head2 forget_fields($model)

Makes the next C<fields_cached> look at the date of C<ir.model.fields> again.

=cut

sub forget_fields ($self, $model) {
    my $login = $self->{stamp_login} // $self->{login} // '';
    my @keys = ( $login, ( $self->{stamp_source} ? $self->_via_key : () ) );
    if ( $self->{cache} ) { $self->{cache}->forget( $self->_stamp_file($_) ) for @keys }
    delete $self->{fields_stamp};
    delete $self->{stamp_memory}{$_} for grep { $self->{stamp_memory} } @keys;
}

sub fields_cached ($self, $model, $fetch) {
    my $cache = $self->{cache};
    # the login the fields are kept for: the client's own, or the one a session transport says it signed in as
    my $login = $self->{login};
    if ( !defined $login ) {
        my $st = _session_transport( $self->{transport} );
        # a session transport new to this client has not been asked who it is yet; the answer is needed for the call anyway
        $self->uid if $st && !$st->identity && $cache;
        $login = $st->identity->{login} if $st && $st->identity;
    }
    return $fetch->() if !$cache || !defined $login;
    $self->{stamp_login} = $login;
    my $stamp = $self->{fields_stamp} //= $self->_stamp_for($login);
    my $wd = $stamp->[0];
    return $fetch->() if !defined $wd;
    my $name = 'fields-' . ( $model =~ s/[^\w.-]//gr ) . '-'
        . substr( Odoo::Cache->digest( 'fields', $self->{url}, $self->{db}, $model, $login, $self->{context}{lang} ), 0, 16 ) . '.json';
    my $kept = $cache->recall($name);
    return $kept->{fields} if ref $kept eq 'HASH' && ref $kept->{fields} eq 'HASH' && ( $kept->{stamp} // '' ) eq $wd;
    my $fields = $fetch->();
    $cache->keep( $name, { model => $model, url => $self->{url}, db => $self->{db}, login => $login,
            stamp => $wd, fields => $fields } ) if ref $fields eq 'HASH';
    return $fields;
}

# The state of ir.model.fields for this login: read, or, for a resident program that lends its memory to each client
# (C<stamp_memory>, a hash it keeps), the one it read less than cache_ttl_version seconds ago for the same login.
sub _stamp_for ($self, $login) {
    # The state is a fact about the server, not about the person: where a source for it is given (a login that may
    # read ir.model.fields) it is read there and shared by every login; a person's definitions stay their own.
    if ( my $source = $self->{stamp_source} ) {
        my $s = $self->_stamp_via( $self->_via_key, $source );
        return $s if $s && defined $s->[0];
    }
    return $self->_stamp_via( $login, sub { $self->_fields_stamp } );
}

# The key under which the shared state of ir.model.fields is kept when a source reads it: not a login's.
sub _via_key ($self) { return "\0via\0" . ( $self->{stamp_source_name} // 'source' ) }

sub _stamp_via ($self, $key, $read) {
    my $mem = $self->{stamp_memory};
    my $now = $self->{now}->();
    my $m   = $mem ? $mem->{$key} : undef;
    return $m->{stamp} if $m && $self->{ttl_version} > 0 && $now >= $m->{at} && $now - $m->{at} < $self->{ttl_version};
    # a burst of short-lived processes shares one reading for cache_ttl_fields_stamp seconds
    my $ttl  = $self->{ttl_fields_stamp};
    my $name = $self->_stamp_file($key);
    if ( $ttl > 0 && $self->{cache} ) {
        my $kept = $self->{cache}->recall($name);
        if ( ref $kept eq 'HASH' && defined $kept->{stamp} && !ref $kept->{stamp} && defined $kept->{at} && $kept->{at} =~ /\A\d+\z/
            && $now >= $kept->{at} && $now - $kept->{at} < $ttl ) {
            my $s = [ $kept->{stamp} ];
            $mem->{$key} = { stamp => $s, at => $kept->{at} } if $mem;
            return $s;
        }
    }
    my $s = [ $read->() ];
    $mem->{$key} = { stamp => $s, at => $now } if $mem;
    $self->{cache}->keep( $name, { at => $now, stamp => $s->[0] } ) if $ttl > 0 && $self->{cache} && defined $s->[0];
    return $s;
}

# the shared file of the state of ir.model.fields, per url, db and login (a login's rights decide what it can read)
sub _stamp_file ($self, $login) {
    return 'fields-stamp-' . substr( Odoo::Cache->digest( 'stamp', $self->{url}, $self->{db}, $login ), 0, 16 ) . '.json';
}

# What changed in the field definitions of every model, as one string; undef when it cannot be
# read. Three cheap reads: the newest row (a module installed or a field made adds rows), the
# number of rows (an uninstall removes them) and the newest write_date (an upgrade changes rows
# in place). write_date alone does not serve: Odoo leaves it empty on the rows a module loads
# (probed on 16, 18 and 19), and a descending order puts those first. A refusal here (a login
# that may not read ir.model.fields) is no sign of a stale uid, so it does not go through the
# authenticate-once path.
=head2 fields_stamp

The state of C<ir.model.fields> as one string (the newest row, the number of
rows and the newest C<write_date>: three cheap reads), or undef when this
login may not read it. It is what a kept C<fields_get> is checked against, and
what a C<stamp_source> hands to the clients of other logins.

=cut

sub fields_stamp ($self) { return $self->_fields_stamp }

sub _fields_stamp ($self) {
    my $ask = sub ( $method, $domain, $kw ) {
        $self->_call( 'object', 'execute_kw', $self->{db}, $self->uid, $self->{key}, 'ir.model.fields', $method, [$domain], $kw );
    };
    my @part = eval {
        my $newest = $ask->( 'search_read', [], { fields => ['id'], order => 'id desc', limit => 1 } );
        my $count  = $ask->( 'search_count', [], {} );
        my $dated  = $ask->( 'search_read', [ [ 'write_date', '!=', JSON::PP::false() ] ],
            { fields => ['write_date'], order => 'write_date desc, id desc', limit => 1 } );
        die "no answer\n" if ref $newest ne 'ARRAY' || ref $dated ne 'ARRAY' || ref $count || !defined $count || $count !~ /\A\d+\z/;
        my $id = ref $newest->[0] eq 'HASH' ? $newest->[0]{id} : 0;
        my $wd = ref $dated->[0] eq 'HASH' && defined $dated->[0]{write_date} && !ref $dated->[0]{write_date} ? $dated->[0]{write_date} : '';
        ( $id // 0, $count, $wd );
    };
    return @part == 3 ? join( ':', @part ) : undef;
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
# errors walk the ladder; faults and anything else surface at once. A write
# (an execute_kw of a method that does not only read) is sent again only when
# the transport says its request never left (connect refused, DNS, TLS): a
# write whose request may have reached Odoo is never resent, whether or not
# the transport can say so, because the change may have been made and a second
# send would make it twice. That error is marked as a write and surfaces at once.
sub _call ($self, $service, $method, @args) {
    my @ladder = @{ $self->{retries} };
    @ladder = (0) if !@ladder;
    my $write = $service eq 'object' && $method eq 'execute_kw' && !Odoo::Transport::is_read_method( $args[4] );
    my $last;
    for my $delay (@ladder) {
        sleep $delay if $delay;
        my $result;
        my $ok = eval { $result = $self->{transport}->call($service, $method, @args); 1 };
        return $result if $ok;
        $last = $@;
        die $last
            if !(blessed($last) && $last->isa('Odoo::Error') && $last->is_transport);
        if ($write) {
            $last->{write} = 1;
            # sent unknown (a transport that does not say) counts as sent
            die $last if $last->{sent} || !defined $last->{sent};
        }
    }
    die $last;
}

1;

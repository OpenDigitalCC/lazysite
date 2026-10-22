package Odoo::Transport::JSON2;

use v5.36;
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::JSON ();

use Odoo::Error;
use Odoo::Transport;

our $VERSION = '0.42';

=head1 NAME

Odoo::Transport::JSON2 - Odoo 19's C</json/2> API behind the common transport surface

=head1 SYNOPSIS

    my $odoo = Odoo::Client->new(
        url => 'https://erp.example', db => 'prod', login => 'integration',
        api_key_file => '/path/to/key', transport => 'json2',
    );
    $odoo->model('res.partner')->search_read( [], ['name'], limit => 5 );

=head1 DESCRIPTION

The fourth transport. Odoo 19 adds C<POST /json/2/E<lt>modelE<gt>/E<lt>methodE<gt>>:
the body is a JSON object of the method's keyword arguments (plus
C<ids> for the records and C<context>), the credential is an API key in
an C<Authorization: Bearer> header, and the database is chosen by the
C<X-Odoo-Database> header. The answer is the method's result, or on
failure an HTTP status with C<{name, message, arguments, context, debug}>.

This class presents the same C<call('object', 'execute_kw', ...)> surface
as the other transports, so L<Odoo::Client>, the operations layer, plans
and journals run unchanged over it. The db and key positions of
C<execute_kw> become the header and the bearer; the uid position is
ignored (the key says who is calling). C<call('common', 'authenticate')>
asks C<res.users/context_get> for the key owner's uid and checks that
user's login against the one given, answering 0 for a refused key or a
different login. C<call('common', 'version')> asks
C</web/webclient/version_info>.

=head2 Positional arguments

C<execute_kw> carries positional arguments; C</json/2> takes names. The
transport knows the names of the methods the mapper uses (C<search>,
C<search_read>, C<search_count>, C<read>, C<create>, C<write>,
C<unlink>, C<copy>, C<fields_get>, C<read_group>, C<name_search>,
C<name_create>, C<default_get>; names checked against the 19.0
signatures). For any other method the only positional argument allowed is
the ids, first (a list, or one bare integer); everything else must be a keyword argument
(C<< $model->call($method, [$ids], key => value) >>). A call that cannot
be named dies as kind C<usage>, naming the method - it is never guessed.
C<create> with one hashref is sent as a list of one and answers one id,
as the other transports do.

=head2 Series

The route exists from Odoo 19 (probed live 2026-10-13: 19 present; 16
and 18 answer a login redirect or a 404 page). On any other series the
first object call dies as kind C<refused>, code C<series>, before any
credential is sent. C<min_series> (default 19) is exposed so a later
series can be admitted by changing one value after it has been probed.

=head2 Errors

A JSON answer with a C<name> becomes a fault with that C<fault_class>
(the C<debug> traceback is never copied); 401 is a credential fault. HTML
or empty answers with a 5xx status (a proxy) are transport failures and
retried; a 404 page is a refusal naming the missing route.

=cut

# names of the positional parameters, per method, from the 19.0 signatures
# (odoo/orm/models.py). A model method takes no ids; a record method takes
# its ids first and then these.
my %MODEL_METHOD = (
    search       => [qw(domain offset limit order)],
    search_read  => [qw(domain fields offset limit order)],
    search_count => [qw(domain limit)],
    create       => [qw(vals_list)],
    fields_get   => [qw(allfields attributes)],
    read_group   => [qw(domain fields groupby offset limit orderby lazy)],
    name_search  => [qw(name domain operator limit)],
    name_create  => [qw(name)],
    default_get  => [qw(fields)],
);
my %RECORD_METHOD = (
    read   => [qw(fields load)],
    write  => [qw(vals)],
    unlink => [],
    copy   => [qw(default)],
);

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw( kind => 'config', message => 'url required' );
    $url =~ s{/+\z}{};
    return bless {
        url        => $url,
        id         => 0,
        min_series => $args{min_series} // 19,
        json       => Odoo::JSON->new( plain_bools => 1 ),
        http       => $args{http} // Odoo::Transport::http_client(
            timeout            => $args{timeout},
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        ),
    }, $class;
}

sub name       ($self) { 'json2' }
sub http       ($self) { $self->{http} }
sub min_series ($self) { $self->{min_series} }

sub call ($self, $service, $method, @params) {
    if ( $service eq 'common' && $method eq 'version' ) {
        return $self->_version;
    }
    if ( $service eq 'common' && $method eq 'authenticate' ) {
        my ( $db, $login, $key ) = @params;
        return $self->_authenticate( $db, $login, $key );
    }
    if ( $service eq 'object' && $method eq 'execute_kw' ) {
        my ( $db, undef, $key, $model, $mmethod, $args, $kwargs ) = @params;
        $self->_need_series;
        return $self->_execute( $db, $key, $model, $mmethod, $args // [], $kwargs // {} );
    }
    Odoo::Error->throw(
        kind    => 'usage',
        message => "the json2 transport does not carry $service.$method",
    );
}

# --- internals --------------------------------------------------------------

sub _version ($self) {
    my $body = $self->{json}->encode( { jsonrpc => '2.0', method => 'call', params => {}, id => ++$self->{id} } );
    my $res  = $self->{http}->post( "$self->{url}/web/webclient/version_info",
        { content => $body, headers => { 'content-type' => 'application/json' } } );
    $self->_check_http( $res, 'json2 version' );
    my $data = $self->_decode( $res, 'json2 version' );
    Odoo::Error->throw( kind => 'transport', message => 'json2 version: no result in the answer' )
        if ref $data ne 'HASH' || ref $data->{result} ne 'HASH';
    return $data->{result};
}

# the series gate: asked once, before a credential leaves
sub _need_series ($self) {
    return if $self->{series_ok};
    my $v = $self->_version->{server_version} // '';
    my ($major) = $v =~ /^(?:saas~)?(\d+)/;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'series',
        message => "the json2 transport needs Odoo $self->{min_series} or later (server says '$v'); use jsonrpc or xmlrpc",
    ) if !$major || $major < $self->{min_series};
    $self->{series_ok} = 1;
    return;
}

sub _authenticate ($self, $db, $login, $key) {
    $self->_need_series;
    my $ctx = eval { $self->_post( $db, $key, 'res.users', 'context_get', {} ) };
    if ( my $err = $@ ) {
        return 0 if ref $err && $err->isa('Odoo::Error') && $err->is_invalid_credential;
        die $err;
    }
    my $uid = ref $ctx eq 'HASH' ? $ctx->{uid} : undef;
    return 0 if !$uid;
    # the key authenticates its owner; the login given must be that owner
    my $rows = $self->_post( $db, $key, 'res.users', 'read', { ids => [$uid], fields => ['login'] } );
    return 0 if ref $rows ne 'ARRAY' || !@$rows || lc( $rows->[0]{login} // '' ) ne lc( $login // '' );
    return $uid;
}

sub _execute ($self, $db, $key, $model, $method, $args, $kwargs) {
    my %body = %$kwargs;
    my $wrap_create = 0;
    my @args = @$args;

    if ( my $names = $MODEL_METHOD{$method} ) {
        $self->_bind( \%body, $names, \@args, $model, $method );
        if ( $method eq 'create' && ref $body{vals_list} eq 'HASH' ) {
            $body{vals_list} = [ $body{vals_list} ];
            $wrap_create = 1;
        }
    }
    else {
        if (@args) {
            my $ids = shift @args;
            # execute_kw callers pass one id as a bare integer; /json/2 wants the list
            $ids = [$ids] if defined $ids && !ref $ids && $ids =~ /^\d+\z/;
            Odoo::Error->throw( kind => 'usage',
                message => "json2 cannot send $model.$method: its first positional argument must be the list of ids" )
                if ref $ids ne 'ARRAY' || grep { ref $_ || !defined $_ || $_ !~ /^\d+\z/ } @$ids;
            Odoo::Error->throw( kind => 'usage', message => "json2: ids given twice to $model.$method" )
                if exists $body{ids};
            $body{ids} = $ids;
        }
        $self->_bind( \%body, $RECORD_METHOD{$method} // [], \@args, $model, $method );
    }

    my $result = $self->_post( $db, $key, $model, $method, \%body );
    return $wrap_create && ref $result eq 'ARRAY' ? $result->[0] : $result;
}

# positional arguments -> named, by the method's table; leftovers are named
sub _bind ($self, $body, $names, $args, $model, $method) {
    Odoo::Error->throw( kind => 'usage',
        message => "json2 cannot name the " . ( @$args - @$names ) . " extra positional argument(s) of $model.$method; pass them as keywords" )
        if @$args > @$names;
    for my $i ( 0 .. $#$args ) {
        my $n = $names->[$i];
        Odoo::Error->throw( kind => 'usage', message => "json2: argument '$n' of $model.$method given twice" )
            if exists $body->{$n};
        $body->{$n} = $args->[$i];
    }
    return;
}

sub _post ($self, $db, $key, $model, $method, $body) {
    Odoo::Error->throw( kind => 'config', message => 'json2 needs an API key (the bearer credential)' )
        if !defined $key || $key eq '';
    my $label = "json2 $model.$method";
    my %headers = ( 'content-type' => 'application/json', authorization => "Bearer $key" );
    $headers{'x-odoo-database'} = $db if defined $db && length $db;
    my $res = Odoo::Transport::post( $self->{http}, "$self->{url}/json/2/$model/$method",
        { content => $self->{json}->encode($body), headers => \%headers },
        idempotent => Odoo::Transport::is_read_method($method) );
    my $idem = Odoo::Transport::is_read_method($method) ? 1 : 0;
    $self->_check_http( $res, $label, $idem );
    my $out = eval { $self->_decode( $res, $label ) };
    die Odoo::Transport::answered_unusably( $@, idempotent => $idem ) if $@;
    return $out;
}

# policy refusals, then the failures that are the network's, not Odoo's
sub _check_http ($self, $res, $label, $idem = 1) {
    Odoo::Transport::refuse_by_policy( $res, $label );
    my $status = $res->{status} // 0;
    return if $res->{success};
    my $ctype = $res->{headers}{'content-type'} // '';
    return if $ctype =~ m{json};    # an Odoo error body: _decode raises it
    Odoo::Error->throw( kind => 'refused', code => 'series',
        message => "$label: HTTP 404 and no JSON answer - the server has no /json/2 route (Odoo before 19?)" )
        if $status == 404;
    die Odoo::Transport::transport_error( $res, $label, idempotent => $idem );
}

my %CLASS = (    # the HTTP-level names Odoo uses, folded onto the exception names the rest knows
    'werkzeug.exceptions.Unauthorized' => 'odoo.exceptions.AccessDenied',
);

sub _decode ($self, $res, $label) {
    my $data = eval { $self->{json}->decode( $res->{content} // '' ) };
    my $failed = !$res->{success};
    if ($failed) {
        if ( ref $data eq 'HASH' && defined $data->{message} ) {
            my $class = $data->{name};
            $class = $CLASS{$class} // $class if defined $class;
            Odoo::Error->throw(
                kind        => 'fault',
                message     => $data->{message},
                code        => $res->{status},
                fault_class => $class,
            );
        }
        my $peek = substr( $res->{content} // '', 0, 120 );
        Odoo::Error->throw( kind => 'transport', message => "$label: unparseable error answer (HTTP $res->{status}): $peek" );
    }
    if ( !defined $data && ( $res->{content} // '' ) !~ /\Anull\s*\z/ ) {
        my $peek = substr( $res->{content} // '', 0, 120 );
        Odoo::Error->throw( kind => 'transport', message => "$label: unparseable response: $peek" );
    }
    return $data;
}

1;

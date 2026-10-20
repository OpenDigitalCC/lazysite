package Odoo::Ops::Service;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Cwd ();
use Digest::SHA ();
use File::Basename qw(basename dirname);
use File::Spec;
use JSON::PP ();
use Odoo::JSON ();
use Scalar::Util qw(blessed);
use Time::HiRes ();

use Odoo::Cache;
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Credential;
use Odoo::Ops::Plan;
use Odoo::Ops::File;
use Odoo::Ops::Wire;
use Odoo::Ops::Calls;
use Odoo::Ops::Registry;
use Odoo::Ops::Runner;
use Odoo::Ops::Runs;
use Odoo::Ops::Trail;
use Odoo::Transport;

=head1 NAME

Odoo::Ops::Service - the requests oom-ops and oomd both answer, in one place

=head1 SYNOPSIS

    my $svc = Odoo::Ops::Service->new( config => $config );                    # in this process (oom-ops)
    my $res = $svc->execute( { op => 'core.get', phase => 'run', params => {...} } );

    my $svc = Odoo::Ops::Service->new( config => $config, mode => 'daemon',    # a worker of oomd
        credentials => { conn => { path => '/srv/x/key' } }, name => 'site1' );
    my ( $line, $outcome, $id, $op ) = $svc->serve_line($json_line);

=head1 DESCRIPTION

Everything a request does that is not printing: plan a write or read a report
(C<run>, C<check>), apply an approved plan (C<apply>), record an approval
(C<approve>), plan an undo (C<revert>) or the rest of a run (C<resume>).
C<oom-ops> calls it in its own process and prints what comes back;
L<oomd|Odoo::Ops::Daemon> calls it in a worker and sends what comes back over
its socket as one JSON line. The same code answers both, so the guard, the
plans, the journals, the audit and the refusals are the same whichever way a
request came.

A request is a hash: C<op>, C<phase> (C<run>, C<check>, C<apply>, C<revert>,
C<resume>, C<approve>), C<params>, C<credential> (C<< { label => 'conn' } >> or
C<< { session => $id } >>, daemon mode), C<actor>, C<plan> or C<journal> (a
path, or a run id for a plan), C<check> (on revert and resume), C<options>
(apply: C<continue_on_error batch stop_after only>), C<note> (approve),
C<secrets> (an operation applied at once, C<core.credential>), C<instance>
(C<< { url, db } >> the caller means), C<idem> and C<id> (the caller's request id).

C<idem> is the caller's key for the request (up to 128 printable characters, made
by the caller, never by OOM) on C<run>, C<apply> and C<approve>. A request with a
key that already made a run is answered with that run, C<< repeat => 1 >> in the
answer beside C<< idem => KEY >>: the plan while the run is open, the result once
it was applied (nothing is sent to Odoo again). The same key with another
operation or other parameters is refused C<refused/idem-mismatch>, naming the
run; a key from another login never answers this one; a key is free again when
its run is closed, withdrawn or removed. See L<Odoo::Ops::Runs>, C<idem_claim>.

C<execute> answers a hash whose C<kind> says what it is (C<plan>, C<report>,
C<now>, C<needs-secrets>, C<result>, C<approved>, C<nothing>) and dies with an
L<Odoo::Error> otherwise. C<serve_line> is the daemon's side: a JSON line in, a
JSON line out, never dying, and the outcome for the log.

The C<mode> is C<local> (C<oom-ops>: the config's own credential), C<daemon> (a worker of oomd) or C<inproc>
(the fallback of L<Odoo::Ops::Client::Daemon>: credentials by label or session, as a daemon takes them, in this
process). In C<daemon> mode a plan, journal or run id must lie in the config's
C<runs_dir>, a credential is a label the daemon holds (the key files are read
when a request names them; a key is never in a request), and a request for
another instance than the config's is refused.

=cut

my $PRETTY = Odoo::JSON->new( pretty => 1 );

sub new ($class, %a) {
    my $config = $a{config} or Odoo::Error->throw( kind => 'config', message => 'service needs a config' );
    my $self = bless {
        config      => $config,
        mode        => $a{mode} // 'local',
        credentials => $a{credentials} // {},
        name        => $a{name},
        act_as      => $a{act_as},
        transports  => {},
        stamp_memory => {},
        http_store  => {},
        sessions    => {},
        pack_sig    => {},
        served      => 0,
    }, $class;
    return $self;
}

our @ISA = ('Odoo::Ops::Calls');

sub call ($self, $req) { $self->execute($req) }

sub config ($self) { $self->{config} }
sub mode   ($self) { $self->{mode} }

# ---- the wire --------------------------------------------------------------------------------

=head2 serve_line($line)

C<( $response_line, $outcome, $id, $op )>: the request as one JSON line in, the
response as one JSON line out (no newline). C<$outcome> is C<ok> or the
error's kind (with C</code> when it has one): what the daemon's log records.

=cut

sub serve_line ($self, $line) {
    my $req = eval { Odoo::Ops::json()->decode($line) };
    if ( ref $req ne 'HASH' ) {
        my $e = { kind => 'usage', code => 'usage', message => 'the request is not one JSON object', fix => 'send one JSON object per line' };
        return ( Odoo::Ops::json()->encode( { id => undef, ok => JSON::PP::false, error => $e } ), 'usage', undef, undef );
    }
    my $res = $self->handle($req);
    my $out = eval { Odoo::Ops::json()->encode($res) };
    if ( !defined $out ) {
        my $e = { kind => 'fault', code => 'fault', message => 'the answer could not be written as JSON', fix => undef };
        $res = { id => $req->{id}, ok => JSON::PP::false, error => $e };
        $out = Odoo::Ops::json()->encode($res);
    }
    my $outcome = $res->{ok} ? 'ok' : join '/', grep { defined && length } $res->{error}{kind}, ( ( $res->{error}{code} // '' ) ne ( $res->{error}{kind} // '' ) ? $res->{error}{code} : undef );
    return ( $out, $outcome, $req->{id}, $req->{op} );
}

=head2 handle($request)

The response hash for a request: C<< { id, ok => true, result } >> or
C<< { id, ok => false, error => { kind, code, message, fix } } >>. Never dies.
In daemon mode it also runs the audit trail's side of a command (one
C<command> line per request) and stands the request's actor in for the
process's.

=cut

sub handle ($self, $req) {
    my $daemon = $self->{mode} eq 'daemon';
    my $phase  = $req->{phase} // 'run';
    if ($daemon) {
        Odoo::Ops::Trail->reset;
        Odoo::Ops::Trail->program('oomd');
        my $actor = $req->{actor};
        Odoo::Ops::Trail->set_actor_option($actor) if defined $actor && !ref $actor && length $actor;
        Odoo::Ops::Trail->command( $phase eq 'check' ? 'run' : $phase );
    }
    my $res = eval {
        Odoo::Ops::Trail->for_config( $self->{config} ) if $daemon;
        $self->execute($req);
    };
    my $err = $@;
    my $status = 0;
    my $resp;
    if ( defined $res ) {
        $status = 3 if ref $res eq 'HASH' && $res->{kind} eq 'result' && !$res->{result}->ok;
        $resp = eval { { id => $req->{id}, ok => JSON::PP::true, result => $self->to_wire($res) } };
        $err = $@, $resp = undef if !$resp;
    }
    if ( !$resp ) {
        my $e = blessed($err) && $err->isa('Odoo::Error') ? $err : undef;
        $status = !$e ? 1 : $e->kind =~ /^(usage|config)\z/ ? 2 : 1;
        Odoo::Ops::Trail->command_error($err) if $daemon;
        $resp = { id => $req->{id}, ok => JSON::PP::false, error => error_hash($err) };
    }
    if ($daemon) {
        eval { Odoo::Ops::Trail->finish_command($status) };
        my $t = $self->{test_package};
        eval { $t->finish } if $t && $t->can('finish');
    }
    $self->{served}++;
    return $resp;
}

=head2 error_hash($error)

C<< { kind, code, message, fix, fault_class } >> of an error, the same fields
C<oom-ops --json> prints. An error that is not an L<Odoo::Error> is a C<fault>
marked C<internal>.

=cut

sub error_hash ($err) {
    if ( blessed($err) && $err->isa('Odoo::Error') ) {
        return { kind => $err->kind, code => $err->code // $err->kind, message => $err->message, fix => $err->fix,
            ( defined $err->fault_class ? ( fault_class => $err->fault_class ) : () ) };
    }
    return { kind => 'fault', code => 'fault', internal => 1, message => ( "$err" =~ s/\s+\z//r ), fix => undef };
}

=head2 error_from_wire($hash)

The L<Odoo::Error> a response's C<error> hash describes. An C<internal> fault is
rethrown as the plain text it was.

=cut

sub error_from_wire ($h) { return Odoo::Ops::Wire::error_from_wire($h) }

=head2 to_wire($result) / from_wire($result)

The result of C<execute> with its objects (a plan, a result) as plain data, and
back. A client that receives a plan or a result over a socket gets the same
objects C<execute> gives in-process.

=cut

sub to_wire ($class, $res) {
    my %r = %$res;
    $r{plan}   = $r{plan}->to_hash   if blessed $r{plan};
    $r{result} = $r{result}->to_hash if blessed $r{result};
    return \%r;
}

sub from_wire ($class, $res) { return Odoo::Ops::Wire->from_wire($res) }

# ---- one request -----------------------------------------------------------------------------

my %PHASE = map { $_ => 1 } qw(run check apply revert resume approve);

sub execute ($self, $req) {
    local $self->{live_session};
    my $res;
    my $ok = eval { $res = $self->_execute($req); 1 };
    my $err = $@;
    $self->_settle_session( $ok ? undef : $err );
    die $err if !$ok;
    return $res;
}

sub _execute ($self, $req) {
    Odoo::Error->throw( kind => 'usage', message => 'the request is not a hash' ) if ref $req ne 'HASH';
    Odoo::Error->throw( kind => 'usage', message => "request version $req->{v} is not understood; this daemon speaks v1", fix => 'send "v":1' )
        if defined $req->{v} && $req->{v} ne '1';
    my $phase = $req->{phase} // 'run';
    Odoo::Error->throw( kind => 'usage', message => "unknown phase '$phase'", fix => 'phase is one of run, check, apply, revert, resume, approve' )
        if !$PHASE{$phase};
    my $idem = $req->{idem};
    if ( defined $idem ) {
        Odoo::Error->throw( kind => 'usage', message => 'idem: the key is up to 128 printable characters',
            fix => 'give a key you made for the request, such as a UUID' ) if ref $idem || $idem !~ /\A[\x20-\x7e]{1,128}\z/;
        Odoo::Error->throw( kind => 'usage', message => "idem is for run, apply and approve; a $phase has no repeat to guard",
            fix => 'send the key with the run, apply or approve of the request' ) if $phase !~ /\A(?:run|apply|approve)\z/;
        Odoo::Ops::Trail->note( idem => $idem );
    }
    $self->_instance_ok($req) if $self->{mode} ne 'local';
    # the operations of this config's packs are found by every registry this process makes from here on
    Odoo::Ops::Registry->use_config( $self->{config} );
    $self->_refresh_packs if $self->{mode} eq 'daemon';
    return $self->_run( $req, check => 0 ) if $phase eq 'run';
    return $self->_run( $req, check => 1 ) if $phase eq 'check';
    return $self->_apply($req)   if $phase eq 'apply';
    return $self->_approve($req) if $phase eq 'approve';
    return $self->_revert($req)  if $phase eq 'revert';
    return $self->_resume($req);
}

# a daemon serves the one instance its config names (docs/OPS.md, oomd)
sub _instance_ok ($self, $req) {
    my $c    = $self->{config};
    my $have = { url => ( $c->get('url') =~ s{/+\z}{}r ), db => $c->get('db') };
    my %ask;
    for my $src ( $req->{instance}, $req->{params} ) {
        next if ref $src ne 'HASH';
        for my $k (qw(url db)) {
            $ask{$k} = $src->{$k} if defined $src->{$k} && !ref $src->{$k};
        }
    }
    $ask{url} =~ s{/+\z}{} if defined $ask{url};
    for my $k (qw(url db)) {
        next if !defined $ask{$k} || $ask{$k} eq $have->{$k};
        Odoo::Error->throw( kind => 'refused', code => 'instance',
            message => "this daemon serves $have->{url} (database $have->{db}); the request is for "
                . ( $ask{url} // $have->{url} ) . ' (database ' . ( $ask{db} // $have->{db} ) . ')',
            fix => 'send the request to the daemon that serves that instance' );
    }
    return;
}

# ---- credentials and the context --------------------------------------------------------------

sub _test_args ($self, %o) {
    my $pkg = $ENV{OOM_OPS_TEST_TRANSPORT} or return ();
    require( $pkg =~ s{::}{/}gr . '.pm' );
    $self->{test_package} = $pkg;
    return $pkg->context_args(%o);
}

# The context a request runs in. With act_as (a daemon's label), an operation that acts for a person
# finds its service credential there, built when it first needs it (Odoo::Ops::Acting).
sub context ($self, $req = {}, %extra) {
    my $ctx = $self->_context( $req, %extra );
    if ( defined $self->{act_as} && $self->{mode} ne 'local' ) {
        my $label = $self->{act_as};
        my $held  = $self->{credentials}{$label};
        my $via   = ( $held ? $held->{login} : undef ) // $self->{config}->get('login');
        $ctx->set_service_builder( sub (%more) { $self->_context( { credential => { label => $label }, actor => $ctx->actor }, %more ) },
            name => $label, via => $via );
    }
    return $ctx;
}

sub _context ($self, $req = {}, %extra) {
    my $config = $self->{config};
    my $sess = ref $req->{credential} eq 'HASH' && defined $req->{credential}{session};
    my @test   = $self->_test_args( $sess ? ( session => 1 ) : () );
    if ( $self->{mode} eq 'local' ) {
        return Odoo::Ops::Context->new( config => $config, @test );
    }
    my $actor = defined $req->{actor} && !ref $req->{actor} && length $req->{actor} ? $req->{actor} : undef;
    my @actor = $actor ? ( actor => $actor ) : ();
    my $c     = $req->{credential};
    $c = { label => 'conn' } if !defined $c;
    Odoo::Error->throw( kind => 'usage', message => 'credential is { "label": NAME } or { "session": ID }',
        fix => 'name one of the credentials the daemon holds, or give a session id' ) if ref $c ne 'HASH';
    if ( defined $c->{session} ) {
        Odoo::Error->throw( kind => 'usage', message => 'a session credential is a session id string' )
            if ref $c->{session} || !length $c->{session};
        # the session is for this request only: no transport is kept for it. What is remembered of it is who it is, for a short
        # time, under a digest of the id (never the id), in this worker's memory; its connection is the worker's shared one.
        my $digest = Digest::SHA::sha256_hex( $c->{session} );
        my $ctx = Odoo::Ops::Context->new( config => $config, @actor, @test, credential => { session => $c->{session} },
            stamp_memory => $self->{stamp_memory}, $self->_shared_args, $self->_remembered_identity($digest), $self->_stamp_source );
        $self->{live_session} = { digest => $digest, ctx => $ctx } if $self->{mode} eq 'daemon';
        return $ctx;
    }
    my $label = $c->{label};
    Odoo::Error->throw( kind => 'usage', message => 'credential names neither a label nor a session',
        fix => 'send { "label": "conn" } or { "session": ID }' ) if !defined $label || ref $label || $label !~ /\A\w[\w.-]*\z/;
    my $held = $self->{credentials}{$label};
    my %cred;
    if ($held) {
        my $key = Odoo::Ops::Credential->secret_file( $held->{path}, "credential '$label'" );
        %cred = ( login => $held->{login} // $config->get('login'), api_key => $key );
    }
    elsif ( $label eq 'conn' ) {
        # the connection's own credential: a key is kept as a client would; a password makes its own session
        my %own = $ENV{OOM_OPS_TEST_TRANSPORT} ? () : Odoo::Ops::Credential->resolve($config);
        %cred = ( login => $own{login}, api_key => $own{api_key} ) if defined $own{api_key};
    }
    else {
        Odoo::Error->throw( kind => 'usage',
            message => "this daemon holds no credential labelled '$label' (it holds: " . join( ', ', 'conn', sort keys %{ $self->{credentials} } ) . ')',
            fix => 'name one of those labels, or give a session id' );
    }
    if ( !%cred && !$held ) {
        # the connection's own login and password: its web session is opened once and kept, as a key's connection is
        my @session;
        if ( !@test && ( $config->get('credential') // '' ) eq 'password' ) {
            @session = ( transport => ( $self->{transports}{'conn.session'} //= Odoo::Ops::Context->build_transport( $config, 'session', $self->_shared_args ) ) );
            push @session, cache_dir => ( $config->cache_dir // Odoo::Cache->default_dir ) if $config->cache_enabled;
        }
        return Odoo::Ops::Context->new( config => $config, @actor, @test, %extra, @session, stamp_memory => $self->{stamp_memory}, $self->_stamp_source( $req ) );
    }
    my @transport;
    if ( !@test ) {
        my $t = $config->get('transport') // 'jsonrpc';
        # one open connection per label for a key: the next request does not open another
        @transport = ( transport => ( $self->{transports}{$label} //= Odoo::Ops::Context->build_transport( $config, undef, $self->_shared_args ) ) )
            if $t =~ /\A(?:jsonrpc|xmlrpc|json2)\z/;
    }
    my @cache = @transport && $config->cache_enabled ? ( cache_dir => $config->cache_dir // Odoo::Cache->default_dir ) : ();
    return Odoo::Ops::Context->new( config => $config, @actor, @test, %extra, ( %cred ? ( credential => {%cred} ) : () ), @transport, @cache, stamp_memory => $self->{stamp_memory}, $self->_stamp_source( $req ) );
}

# ---- what a worker keeps between requests -----------------------------------------------------------

# The one HTTP client (so one kept-alive connection) this worker uses for the Odoo URL and TLS settings of its config,
# whoever the request runs as. It holds no cookie jar and no credential: each request's own transport sends its own
# cookies and keys, so nothing one person sends can ride on another's request. Only a daemon shares it.
sub _shared_args ($self) {
    return () if $self->{mode} ne 'daemon';
    my $c = $self->{config};
    return ( http => Odoo::Transport::shared_http( $self->{http_store},
        url => $c->get('url'), timeout => $c->get('timeout') // 120, ssl_verify => $c->get('ssl_verify'),
        ssl_ca_file => $c->get('ssl_ca_file'), max_response_bytes => $c->get('max_response_bytes') ) );
}

# Who a session is, for cache_ttl_session seconds, by a digest of the session id; hands the transport the identity
# (without the server's whole answer) so the first query is not preceded by asking Odoo who this is.
sub _remembered_identity ($self, $digest) {
    return () if $self->{mode} ne 'daemon';
    my $ttl = $self->{config}->cache_ttl_session;
    my $e   = $self->{sessions}{$digest};
    return () if !$e || $ttl <= 0;
    if ( time - $e->{at} >= $ttl ) { delete $self->{sessions}{$digest}; return () }
    return ( session_identity => { %{ $e->{identity} }, company_ids => [ @{ $e->{identity}{company_ids} // [] } ] } );
}

# After a request: remember what its session transport learned of who the session is, or forget the entry when
# Odoo no longer knows the session. The call that met the fault is answered as it was, never repeated here.
sub _settle_session ($self, $err) {
    my $live = delete $self->{live_session} or return;
    my $digest = $live->{digest};
    my $st = eval { $live->{ctx}->session_transport };
    my $expired = blessed($err) && $err->isa('Odoo::Error') && $err->is_session_expired;
    if ( $expired || !$st || !$st->has_session ) { delete $self->{sessions}{$digest}; return }
    my $id  = $st->identity or return;
    my $ttl = $self->{config}->cache_ttl_session;
    return if $ttl <= 0;
    my $s = $self->{sessions};
    if ( keys %$s > 1000 ) { for my $k ( keys %$s ) { delete $s->{$k} if time - $s->{$k}{at} >= $ttl } }
    my %kept = map { $_ => $id->{$_} } grep { $_ ne 'raw' } keys %$id;
    $s->{$digest} = { at => time, identity => \%kept } if !$s->{$digest};
    return;
}

# The state of ir.model.fields is a fact about the server: a daemon reads it through its own connection credential
# (which may read it) for every login, and each login's definitions stay under its own name. A config that names
# a login of its own (cache_stamp_conf) is left to Odoo::Ops::Context.
sub _stamp_source ($self, $req = undef) {
    return () if $self->{mode} ne 'daemon' || $self->{config}->cache_stamp_conf || !$self->{config}->cache_enabled;
    my $src = sub {
        my $ctx = $self->{stamp_ctx} //= Odoo::Ops::Trail->aside( sub {
            $self->context( { credential => { label => 'conn' } }, cache => 0 ) } );
        return Odoo::Ops::Trail->aside( sub { $ctx->client->fields_stamp } );
    };
    return ( stamp_source => sub { my $s = eval { $src->() }; return $s }, stamp_source_name => 'daemon' );
}

# ---- packs --------------------------------------------------------------------------------------

# A pack whose version or files changed since this worker last looked is loaded again, that pack alone
# (docs/OPS.md, oomd): its modules leave %INC and their packages are emptied, and the next request that
# names one of its operations loads the new code.
sub _refresh_packs ($self) {
    my $reg = Odoo::Ops::Registry->new;
    my %p   = $reg->packs;
    for my $name ( sort keys %p ) {
        my $sig = $reg->_pack_signature( $p{$name} );
        my $was = $self->{pack_sig}{$name};
        _unload_pack( $p{$name} ) if defined $was && $was ne $sig;
        $self->{pack_sig}{$name} = $sig;
    }
    for my $gone ( grep { !$p{$_} } keys %{ $self->{pack_sig} } ) { delete $self->{pack_sig}{$gone} }
    return;
}

sub _unload_pack ($m) {
    require Symbol;
    my $lib = $m->{lib};
    for my $inc ( sort keys %INC ) {
        my $file = $INC{$inc};
        next if !defined $file || ref $file || index( $file, "$lib/" ) != 0;
        ( my $pkg = $inc ) =~ s{/}{::}g;
        $pkg =~ s/\.pm\z//;
        Symbol::delete_package($pkg);
        delete $INC{$inc};
    }
    return;
}

# ---- run and check --------------------------------------------------------------------------------

sub _run ($self, $req, %o) {
    my $check = $o{check} ? 1 : 0;
    my $name  = $req->{op};
    Odoo::Error->throw( kind => 'usage', message => 'run needs an operation name', fix => 'oom-ops list names the operations' )
        if !defined $name || ref $name || !length $name;
    my $params = ref $req->{params} eq 'HASH' ? { %{ $req->{params} } } : {};
    # a file arrives from the daemon's wire as base64: decoded here, before the operation or any check sees it
    $params = Odoo::Ops::File->from_wire($params);
    my $class  = Odoo::Ops::Registry->new->class_for($name);
    # 'fields' asks a read to show its descriptor block; an operation with a parameter of that name keeps it
    my $schema = $req->{schema} ? 1 : 0;
    if ( !$class->params->{fields} && exists $params->{fields} ) {
        $schema = 1 if delete( $params->{fields} ) =~ /^(?:1|yes|true)\z/i;
    }
    # an operation applied at once may have its secrets among the params of a request (a daemon's callers send them so)
    my %inline;
    if ( $class->immediate && $self->{mode} ne 'local' && ref $req->{secrets} ne 'HASH' ) {
        for my $k (qw(old new password code)) { $inline{$k} = delete $params->{$k} if exists $params->{$k} && !$class->params->{$k} }
        $req = { %$req, secrets => {%inline} } if %inline;
    }
    $params = $class->check_params($params);    # refuse before connecting
    Odoo::Ops::Trail->note( op => $name, params => [ sort keys %$params ] );
    return $self->_now( $class, $params, $req, $check ) if $class->immediate;
    Odoo::Error->throw( kind => 'usage', message => "idem: $name " . ( $class->immediate ? 'is applied at once' : 'is a read' ) . ' and makes no run to hold a key',
        fix => 'send idem with a write operation' ) if defined $req->{idem} && !$class->writes;
    Odoo::Error->throw( kind => 'usage', message => 'idem: --check records no run, so it holds no key', fix => 'send the key with the run, not the check' )
        if defined $req->{idem} && $check;
    my $ctx = $self->context($req);
    my ( $claim, $idem );
    if ( defined $req->{idem} ) {
        my $digest = Odoo::Ops::Runs->request_digest( $name, $params );
        $claim = Odoo::Ops::Runs->idem_claim( $self->_runs_root, instance => $ctx->instance, owner => $self->_owner( $req, $ctx ), key => $req->{idem} );
        if ( my $run = $claim->run ) {
            Odoo::Error->throw( kind => 'refused', code => 'idem-mismatch',
                message => "idem '$req->{idem}' belongs to run $run->{id} ($run->{op}), which was a different request",
                fix => 'a key means one request: give this request a key of its own, or repeat the first one exactly' )
                if ( $claim->request // '' ) ne $digest;
            return $self->_idem_answer( $ctx, $run, $req->{idem} );
        }
        $idem = { key => $req->{idem}, owner => $claim->owner, request => $digest };
    }
    # a read leaves a folder unless --check or the config's record_reads = 0 says not; a write always plans into one
    my $keep = !$check && ( $class->writes || $ctx->config->record_reads );
    my $dir  = $keep ? $ctx->run_dir($name) : undef;
    my $op   = $class->new( ctx => $ctx, params => $params );
    my $out  = $op->run;

    if ( blessed($out) && $out->isa('Odoo::Ops::Plan') ) {
        my $res = $self->_emit_plan( $out, $ctx, $check, $dir, ( $idem ? ( idem => $idem ) : () ) );
        $claim->bind( $res->{run_id}, $idem->{request} ) if $claim && defined $res->{run_id};
        return $res;
    }

    my $path;
    if ($dir) {
        $path = File::Spec->catfile( $dir, 'report.json' );
        open my $fh, '>', $path or die "cannot write $path: $!\n";
        print {$fh} $PRETTY->encode($out);    # the file keeps everything
        close $fh;
    }
    return { kind => 'report', report => $out, path => $path, schema => $schema, op => $name };
}

# An operation applied at once (core.credential): no plan, no run folder, no journal. Its secrets are given in
# the request, or read from standard input one per line when this process has one to read.
sub _now ($self, $class, $params, $req, $check) {
    Odoo::Error->throw( kind => 'usage', message => $class->op_name . ' is applied at once; --check has nothing to plan',
        fix => 'oom-ops describe ' . $class->op_name . ' says what it does' ) if $check;
    my %secret;
    if ( ref $req->{secrets} eq 'HASH' ) { %secret = %{ $req->{secrets} } }
    elsif ( $self->{mode} eq 'daemon' ) {
        return { kind => 'needs-secrets', names => [ $class->secret_names($params) ], op => $class->op_name };
    }
    else { %secret = $class->read_secrets( $params, \*STDIN ) }
    my $ctx = $self->context($req);
    my $op  = $class->new( ctx => $ctx, params => $params );
    return { kind => 'now', report => $op->perform(%secret), op => $class->op_name };
}

# A finished plan: save and index it unless it is only being checked.
sub _emit_plan ($self, $plan, $ctx, $check, $dir, %o) {
    my ( $path, $run_id );
    if ($check && $ctx->trail) {
        # nothing is recorded, but the config's owner can see a plan was asked for
        my %models = map { $_->{model} => 1 } grep { defined $_->{model} } @{ $plan->changes };
        eval { $ctx->trail->event( read => op => $plan->op, outcome => 'ok', models => [ sort keys %models ], rows => $plan->input_count ) };
    }
    if ( !$check ) {
        $path   = $plan->save( File::Spec->catfile( $dir, 'plan.json' ) );
        $run_id = basename($dir);
        Odoo::Ops::Runs->index_plan( $dir, $plan, now => $ctx->now, ttl => $ctx->plan_ttl, by => $ctx->actor,
            ( defined $o{reverts} ? ( reverts => $o{reverts} ) : () ), ( $o{idem} ? ( idem => $o{idem} ) : () ) );
    }
    return { kind => 'plan', plan => $plan, path => $path, run_id => $run_id, check => $check, approval => $ctx->approval,
        ( $o{idem} ? ( idem => $o{idem}{key} ) : () ) };
}

# ---- the idempotency key ---------------------------------------------------------------------------------

sub _runs_root ($self) {
    return $self->{config}->get('runs_dir') // Odoo::Error->throw( kind => 'config', message => 'config has no runs_dir' );
}

# whose key it is: the login the request runs as (a session's, the user it belongs to)
sub _owner ($self, $req, $ctx = undef) {
    my $c = $req->{credential};
    if ( $self->{mode} ne 'local' && ref $c eq 'HASH' && defined $c->{session} ) {
        $ctx //= $self->context($req);
        my $uid = $ctx->client->uid;
        return "uid:$uid";
    }
    if ( $self->{mode} ne 'local' && ref $c eq 'HASH' && defined $c->{label} && $self->{credentials}{ $c->{label} } ) {
        return $self->{credentials}{ $c->{label} }{login} // $self->{config}->get('login');
    }
    return $ctx ? $ctx->login : $self->{config}->get('login');
}

# The key of an apply or an approve: it belongs to the run being worked on. A key bound to another run is a
# different request; a key not yet bound is bound here. Returns the claim, which holds the key until it is dropped.
sub _idem_bind ($self, $req, $ctx, $dir) {
    my $key   = $req->{idem};
    my $claim = Odoo::Ops::Runs->idem_claim( $self->_runs_root, instance => $self->{config}->instance, owner => $self->_owner( $req, $ctx ), key => $key );
    my $id    = basename($dir);
    if ( my $run = $claim->run ) {
        Odoo::Error->throw( kind => 'refused', code => 'idem-mismatch',
            message => "idem '$key' belongs to run $run->{id} ($run->{op}); this request is for run $id",
            fix => 'a key means one request: give this request a key of its own' )
            if $run->{id} ne $id;
        return $claim;
    }
    my $mine = Odoo::Ops::Runs->new( dir => dirname($dir) )->peek($id);
    my $has  = $mine && ref $mine->{idem} eq 'HASH' ? $mine->{idem} : undef;
    Odoo::Error->throw( kind => 'refused', code => 'idem-mismatch',
        message => "run $id was made with another idem key; '$key' is not its key",
        fix => 'send the key the run was made with, or none' )
        if $has && $has->{key} ne $key;
    $claim->bind( $id, $has ? $has->{request} : undef );
    Odoo::Ops::Runs->set_idem( $dir, { key => $key, owner => $claim->owner, request => ( $has ? $has->{request} : undef ) } ) if !$has;
    return $claim;
}

# The first answer again, from the run the key belongs to: its result once applied, else its plan. Nothing is sent to Odoo.
sub _idem_answer ($self, $ctx, $run, $key) {
    Odoo::Ops::Trail->note( repeat => 1 );
    my $dir = File::Spec->catdir( $self->_runs_root, $run->{id} );
    if ( ref $run->{result} ) {
        my $rf = File::Spec->catfile( $dir, 'result.json' );
        my $h;
        if ( -e $rf && open my $fh, '<', $rf ) {
            $h = eval { Odoo::Ops::json()->decode( do { local $/; <$fh> } ) };
            close $fh;
        }
        $h ||= { applied => 1, op => $run->{op}, plan_fingerprint => $run->{fingerprint}, total => $run->{changes}, counts => $run->{result}{counts} // {},
            by_bucket => {}, verified => 0, not_verified => 0, journal => $run->{result}{journal}, created => {}, written => {}, unlinked => {},
            custom => [], failed_changes => [], unknown_changes => [], invariants => [], invariants_failed => 0 };
        return { kind => 'result', result => bless( {%$h}, 'Odoo::Ops::Result' ), path => $rf, dir => $dir, run_id => $run->{id}, idem => $key, repeat => 1 };
    }
    my $path = File::Spec->catfile( $dir, 'plan.json' );
    my $plan = Odoo::Ops::Plan->load($path);
    return { kind => 'plan', plan => $plan, path => $path, run_id => $run->{id}, check => 0, approval => $ctx->approval, idem => $key, repeat => 1 };
}

# ---- paths -----------------------------------------------------------------------------------------

# a plan, by path or by run id; a daemon reads only what lies in its runs_dir
sub _plan_path ($self, $ref) {
    Odoo::Error->throw( kind => 'usage', message => 'the request needs a plan (a path to plan.json, or a run id)', fix => 'oom-ops run <op> makes one' )
        if !defined $ref || ref $ref || !length $ref;
    my $path = $ref;
    if ( $ref !~ m{/} && $ref !~ /\.json\z/ ) {
        my $root = $self->{config}->get('runs_dir')
            or Odoo::Error->throw( kind => 'config', message => 'config has no runs_dir' );
        $path = File::Spec->catfile( $root, $ref, 'plan.json' );
    }
    return $self->_within_runs( $path, 'plan' );
}

sub _within_runs ($self, $path, $what) {
    return File::Spec->rel2abs($path) if $self->{mode} ne 'daemon';
    my $root = $self->{config}->get('runs_dir')
        or Odoo::Error->throw( kind => 'config', message => 'config has no runs_dir' );
    my $abs  = File::Spec->rel2abs($path);
    my $real_dir  = Cwd::realpath( dirname($abs) );
    my $real_root = Cwd::realpath($root);
    Odoo::Error->throw( kind => 'refused', code => 'path',
        message => "the $what is outside this daemon's runs_dir",
        fix => 'name a run of the daemon\'s runs_dir (its run id, or the path under it)' )
        if !defined $real_dir || !defined $real_root || ( $real_dir ne $real_root && index( $real_dir, "$real_root/" ) != 0 );
    return File::Spec->catfile( $real_dir, basename($abs) );
}

sub _is_nothing ($dir) {
    my $r = Odoo::Ops::Runs->new( dir => dirname($dir) )->peek( basename($dir) );
    return $r && ( $r->{state} // '' ) eq 'nothing';
}

# ---- apply, approve, revert, resume ---------------------------------------------------------------------

sub _apply ($self, $req) {
    my $path = $self->_plan_path( $req->{plan} );
    my $plan = Odoo::Ops::Plan->load($path);
    my $dir  = dirname( File::Spec->rel2abs($path) );
    return { kind => 'nothing', dir => $dir, run_id => basename($dir) } if _is_nothing($dir);
    Odoo::Ops::Trail->note( op => $plan->op, run => basename($dir) ) if $self->{mode} eq 'daemon';
    my $ctx = $self->context($req);
    my $claim = defined $req->{idem} ? $self->_idem_bind( $req, $ctx, $dir ) : undef;
    if ( $claim && ( my $run = $claim->run ) ) {
        return $self->_idem_answer( $ctx, $run, $req->{idem} ) if ref $run->{result};
    }
    $ctx->use_run_dir($dir);
    my $o = ref $req->{options} eq 'HASH' ? $req->{options} : {};
    my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir,
        continue_on_error => $o->{continue_on_error}, batch => $o->{batch} // 1,
        ( $o->{stop_after} ? ( stop_after => $o->{stop_after} ) : () ),
        ( ref $o->{only} eq 'ARRAY' ? ( only => [ @{ $o->{only} } ] ) : () ) );
    my $saved = $result->save( File::Spec->catfile( $dir, 'result.json' ) );
    return { kind => 'result', result => $result, path => $saved, dir => $dir, ( defined $req->{idem} ? ( idem => $req->{idem} ) : () ) };
}

sub _approve ($self, $req) {
    my $cfg = $self->{config};
    Odoo::Ops::Trail->for_config($cfg);
    $cfg->get('runs_dir') or Odoo::Error->throw( kind => 'config', message => 'config has no runs_dir' );
    my $path = $self->_plan_path( $req->{plan} );
    my $plan = Odoo::Ops::Plan->load($path);    # refuses an edited plan
    my $dir  = dirname( File::Spec->rel2abs($path) );
    return { kind => 'nothing', dir => $dir, run_id => basename($dir) } if _is_nothing($dir);
    Odoo::Error->throw( kind => 'refused', code => 'instance',
        message => 'plan was made against a different instance than this config',
        fix => 'approve with the config of the instance the plan was made for, or plan again with this one' )
        if Odoo::Ops::json()->encode( $plan->instance ) ne Odoo::Ops::json()->encode( $cfg->instance );
    my $claim = defined $req->{idem} ? $self->_idem_bind( $req, undef, $dir ) : undef;
    if ( $claim && ( my $run = $claim->run ) ) {
        # approved already (or carried on from there): the first answer again
        Odoo::Ops::Trail->note( repeat => 1 );
        return { kind => 'approved', idem => $req->{idem}, repeat => 1, record => { id => $run->{id}, state => $run->{state}, approval => $run->{approval}, expires => $run->{expires} } }
            if $run->{approval};
    }
    my $rec = Odoo::Ops::Runs->approve_plan( $dir, $plan, by => ( Odoo::Ops::Trail->resolve_actor($cfg) )[0],
        note => $req->{note}, ttl => $cfg->plan_ttl );
    return { kind => 'approved', ( defined $req->{idem} ? ( idem => $req->{idem} ) : () ), record => { id => $rec->{id}, state => $rec->{state}, approval => $rec->{approval}, expires => $rec->{expires} } };
}

sub _journal ($self, $req) {
    my $j = $req->{journal};
    Odoo::Error->throw( kind => 'usage', message => 'the request needs a journal (a path to journal.jsonl)' ) if !defined $j || ref $j || !length $j;
    return $self->_within_runs( $j, 'journal' );
}

sub _revert ($self, $req) {
    my $journal = $self->_journal($req);
    my $ctx  = $self->context($req);
    my $plan = $ctx->guard->with_scope( {}, 'revert', sub {
        Odoo::Ops::Runner->revert_plan( $ctx, $journal );
    } );
    my $check = $req->{check} ? 1 : 0;
    my $dir = $check ? undef : $ctx->run_dir('revert');
    return $self->_emit_plan( $plan, $ctx, $check, $dir, reverts => basename( dirname($journal) ) );
}

sub _resume ($self, $req) {
    my $journal = $self->_journal($req);
    my $ctx  = $self->context($req);
    my $o    = ref $req->{options} eq 'HASH' ? $req->{options} : {};
    my $names = sub ($v) { ref $v eq 'ARRAY' ? ( grep { defined && !ref && length } @$v ) : () };
    my $plan = Odoo::Ops::Runner->resume_plan( $ctx, $journal,
        assume_done     => [ $names->( $o->{assume_done} ) ],
        assume_not_done => [ $names->( $o->{assume_not_done} ) ] );
    my $check = $req->{check} ? 1 : 0;
    my $dir = $check ? undef : $ctx->run_dir( $plan->op );
    return $self->_emit_plan( $plan, $ctx, $check, $dir );
}


1;

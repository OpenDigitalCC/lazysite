package Odoo::Ops::Acting;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops::Config;
use Odoo::Ops::Credential;
use Odoo::Ops::Trail;

=head1 NAME

Odoo::Ops::Acting - an operation that acts for a person, with a service credential

=head1 SYNOPSIS

    package Odoo::Pack::Shop::Basket;
    use parent 'Odoo::Ops::Operation';

    sub acts_for ($class) { 1 }
    sub read_scope  ($class) { { 'sale.order' => ['read'] } }
    sub write_scope ($class) { { 'sale.order' => [ 'write', 'create' ] } }

    sub plan ($self) {
        my $me    = $self->person;                      # who Odoo says the request is
        my @ids   = $self->own( model => 'sale.order', ids => $self->param('orders'), field => 'partner_id' );
        my $plan  = $self->new_plan;                    # records the person, and that the service credential applies it
        ...
    }

=head1 DESCRIPTION

Odoo's own shop reads as the customer and writes with elevated rights that its trusted code scopes to the
signed-in customer. This module is the means for a pack to work the same way; the scoping is the pack's.

An operation declares C<acts_for =E<gt> 1>. A run of it:

=over 4

=item 1. needs a service credential

C<act_as_conf> (an ops config of the same server) in the config, or C<act_as> (a credential label oomd
holds) in an oomd config. With neither, the run is refused before any call:
C<refused/no-service-credential>, naming both keys.

=item 2. verifies the person

The request's own credential (the person's session or key) is asked who it is: C<uid>, C<login>,
C<partner_id> and C<commercial_partner_id>, as Odoo answers them (the identity a session already holds is
used as it is). A credential Odoo does not accept, or no user, is C<refused/no-person>, before anything
else. The person is never read from a parameter: C<< $op-E<gt>person >> has no other source. A request that
runs as the service credential itself is no person either.

=item 3. gives the operation two clients

C<< $op-E<gt>client >> is the person's (for the reads Odoo's own rules scope to them) and
C<< $op-E<gt>service_client >> the service credential's (for writes, and for reads the person may not
make). The operation's C<read_scope> and C<write_scope> bind both.

=back

C<< $op-E<gt>own(model =E<gt> M, ids =E<gt> [...], field =E<gt> 'partner_id') >> is what a pack calls before it
writes a record the person names: it reads the records through the service client and refuses
C<refused/not-yours>, naming the model and the ids, unless every record's C<field> is the person's partner
or their commercial partner. A record of another customer and a record that does not exist are refused in
the same words, and the words name no other partner.

A plan of such an operation records the person (C<uid>, C<login>, C<partner_id>, C<commercial_partner_id>)
and the service login (C<via>) in C<acts_for>, which the plan's seal covers. Apply, revert and resume of it
use the service credential, and are refused C<refused/not-yours> unless the person who applies is the
person who planned: a person's plan is theirs.

Every audit line of such a run (the commands' events and, at the C<transaction> level, each call) has
C<login> and C<uid> of the person, C<via> (the service login) and C<acts_for: 1>; a call line also says
C<client>, C<person> or C<service>. The service credential is held by files and keys as any credential is
and is in no line, plan, journal, report or error.

=head1 METHODS

=head2 source($ctx)

C<< { kind, name, via, ... } >> of the service credential the context can use (C<kind> C<act_as> or
C<act_as_conf>, C<name> its label or its config's file name, C<via> its login), or undef when none is named.

=cut

sub source ($class, $ctx) {
    if ( my $b = $ctx->{service_builder} ) {
        return { kind => 'act_as', name => $b->{name}, via => $b->{via}, builder => $b->{code} };
    }
    my $path = $ctx->config->get('act_as_conf');
    return undef if !defined $path;
    my $conf = $ctx->{act}{conf} //= Odoo::Ops::Config->load($path);
    return { kind => 'act_as_conf', name => File::Basename::basename($path), via => $conf->get('login'), conf => $conf };
}

=head2 require_service($ctx, $op_name)

The source, or C<refused/no-service-credential>.

=cut

sub require_service ($class, $ctx, $op) {
    return $class->source($ctx) // Odoo::Error->throw(
        kind    => 'refused',
        code    => 'no-service-credential',
        message => "$op acts for a person and writes with a service credential, and this configuration names none"
            . ' (act_as_conf in the config, or act_as in the oomd config)',
        fix => 'name the service login: act_as_conf = /path/to/its/ops.conf in the config, or act_as = LABEL in the oomd config (a label of its credentials)',
    );
}

sub _no_person ($class, $why, $e = undef) {
    return Odoo::Error->new(
        kind    => 'refused',
        code    => 'no-person',
        message => 'Odoo does not know the person this request runs as' . ( length $why ? ": $why" : '' ),
        fix     => 'run the request with the person\'s own session or key; a person is never named by a parameter',
    );
}

# an error that says the credential or the read was refused; a transport failure is not a statement about the person
sub _person_error ($class, $e) {
    return $e if !blessed($e) || !$e->isa('Odoo::Error') || $e->kind eq 'transport' || ( $e->kind eq 'refused' && ( $e->code // '' ) eq 'audit-unavailable' );
    return $class->_no_person( $e->message );
}

=head2 person($ctx)

The verified identity, as C<< { uid, login, name, partner_id, commercial_partner_id } >> (asked once per
context). C<refused/no-person> when Odoo does not accept the credential, gives no user or no partner, or
does not let the person read their own partner.

=cut

sub person ($class, $ctx) {
    my $act = $ctx->{act} //= {};
    return $act->{person} if $act->{person};
    my $client = $ctx->client;
    my $uid    = eval { $client->uid };
    die $class->_person_error($@) if $@;
    die $class->_no_person('no user') if !defined $uid || $uid !~ /\A[1-9]\d*\z/;

    # a session carries who it is; a key is asked
    my $id = eval { my $st = $ctx->session_transport; $st ? $st->identity : undef };
    my ( $login, $name, $pid );
    if ( ref $id eq 'HASH' && ( $id->{uid} // 0 ) == $uid && defined $id->{login} && $id->{partner_id} ) {
        ( $login, $name, $pid ) = @$id{qw(login name partner_id)};
    }
    else {
        my $row = eval { $client->model('res.users')->read_one( $uid, [qw(login name partner_id)] ) };
        die $class->_person_error($@) if $@;
        die $class->_no_person('no such user') if ref $row ne 'HASH';
        ( $login, $name, $pid ) = @$row{qw(login name partner_id)};
    }
    $pid = $pid->[0] if ref $pid eq 'ARRAY';
    die $class->_no_person('the user has no partner') if !$pid || $pid !~ /\A[1-9]\d*\z/ || !defined $login || !length $login;

    my $p = eval {
        $ctx->guard->with_scope( { 'res.partner' => ['read'] }, 'person.verify',
            sub { $client->model('res.partner')->read_one( $pid, ['commercial_partner_id'] ) } );
    };
    die $class->_person_error($@) if $@;
    my $cp = ref $p eq 'HASH' ? $p->{commercial_partner_id} : undef;
    $cp = $cp->[0] if ref $cp eq 'ARRAY';
    die $class->_no_person('the user cannot read their own partner') if !$cp || $cp !~ /\A[1-9]\d*\z/;

    return $act->{person} = { uid => 0 + $uid, login => "$login", name => $name, partner_id => 0 + $pid, commercial_partner_id => 0 + $cp };
}

=head2 service($ctx)

The service credential's context (built once, with the person's trail and audit sink, and its guard held to
the scope of the person's). C<refused/no-service-credential> when none is named; C<refused/no-person> when
the request itself runs as the service login.

=cut

sub service ($class, $ctx) {
    my $act = $ctx->{act} //= {};
    return $act->{service} if $act->{service};
    my $src = $class->require_service( $ctx, 'this operation' );
    my $svc = $class->_build( $ctx, $src );
    # its own sign-in is a line of this run too
    $svc->guard->acting( $act->{info}, 'service' ) if $act->{info};
    if ( my $p = $act->{person} ) {
        my $sid = eval { $svc->client->uid };
        die $class->_person_error($@) if $@;
        die $class->_no_person('the request runs as the service login itself') if defined $sid && $sid == $p->{uid};
    }
    $ctx->guard->attach_twin( $svc->guard );
    return $act->{service} = $svc;
}

sub _build ($class, $ctx, $src) {
    my @acting = $ctx->{act}{info} ? ( acting => [ $ctx->{act}{info}, 'service' ] ) : ();
    return $src->{builder}->( trail => $ctx->trail, audit => $ctx->audit, @acting ) if $src->{builder};
    require Odoo::Ops::Context;
    my $conf = $src->{conf};
    my $mine = $ctx->config;
    my $norm = sub ($u) { ( $u // '' ) =~ s{/+\z}{}r };
    Odoo::Error->throw( kind => 'config', message => "act_as_conf $src->{name} names another server than this config (url and db must be the same)",
        fix => 'name an ops config of the same Odoo url and database' )
        if $norm->( $conf->get('url') ) ne $norm->( $mine->get('url') ) || ( $conf->get('db') // '' ) ne ( $mine->get('db') // '' );
    my %cred = Odoo::Ops::Credential->resolve($conf);
    return Odoo::Ops::Context->new(
        config     => $mine,
        credential => {%cred},
        actor      => $ctx->actor,
        trail      => $ctx->trail,
        audit      => $ctx->audit,
        @acting,
        now        => $ctx->{now},
        %{ $ctx->{service_args} // {} },
    );
}

=head2 adopt($ctx)

The service context writes to the audit sink the person's context has now (it changes when the run folder is
made).

=cut

sub adopt ($class, $ctx) {
    my $svc = $ctx->{act}{service} or return;
    $svc->{audit} = $ctx->{audit};
    $svc->{guard}->set_audit( $ctx->{audit} );
    return;
}

sub _mark ($class, $ctx, $info) {
    $ctx->{act}{info} = $info;
    $ctx->guard->acting( $info, 'person' );
    $ctx->trail->acting($info) if $ctx->trail;
    Odoo::Ops::Trail->note( acting => $info );
    return;
}

sub _unmark ($class, $ctx) {
    delete $ctx->{act}{info};
    $ctx->guard->acting(undef);
    my $svc = $ctx->{act}{service};
    $svc->guard->acting(undef) if $svc;
    $ctx->trail->acting(undef) if $ctx->trail;
    return;
}

=head2 around($op, $code)

What C<run> of an operation that declares C<acts_for> does around its report or plan: the service credential
is required, the person verified, the service context built, every audit line marked as the person's, and
C<$code> run. The marking ends when it returns or dies; an error carries who it was for, so the
command's closing lines name them too.

=cut

sub around ($class, $op, $code) {
    my $ctx = $op->ctx;
    my $src = $class->require_service( $ctx, $op->op_name );
    my %info = ( via => $src->{via} );
    $class->_mark( $ctx, \%info );
    my ( @r, $want );
    $want = wantarray;
    my $ok = eval {
        my $p = $class->person($ctx);
        @info{qw(login uid)} = @$p{qw(login uid)};
        my $svc = $class->service($ctx);
        $svc->guard->acting( \%info, 'service' );
        @r = $want ? $code->() : scalar $code->();
        1;
    };
    my $err = $@;
    $class->_unmark($ctx);
    if ( !$ok ) {
        $err->{acting} //= {%info} if blessed($err) && $err->isa('Odoo::Error');
        die $err;
    }
    return $want ? @r : $r[0];
}

=head2 as_service($ctx, $acts, $code, op =E<gt> NAME)

For the apply, revert or resume of a run that was made for a person (C<$acts> is the C<acts_for> its plan or
journal records): requires the service credential, verifies the person, refuses
C<refused/not-yours> unless they are the person who made the run, and runs C<< $code->($service_ctx) >>
with the lines marked as C<around> marks them. The service context writes; the person's context speaks for
the audit.

=cut

sub as_service ($class, $ctx, $acts, $code, %o) {
    my $src = $class->require_service( $ctx, $o{op} // 'this run' );
    my %info = ( via => $src->{via} );
    $class->_mark( $ctx, \%info );
    my ( @r, $want );
    $want = wantarray;
    my $ok = eval {
        my $p = $class->person($ctx);
        @info{qw(login uid)} = @$p{qw(login uid)};
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'not-yours',
            message => 'this run was made for another person; a person\'s plan is theirs to apply, revert or resume',
            fix     => 'plan again as the person the writes are for',
        ) if ref $acts ne 'HASH' || !defined $acts->{uid} || $acts->{uid} != $p->{uid};
        my $svc = $class->service($ctx);
        $svc->guard->acting( \%info, 'service' );
        @r = $want ? $code->($svc) : scalar $code->($svc);
        1;
    };
    my $err = $@;
    $class->_unmark($ctx);
    if ( !$ok ) {
        $err->{acting} //= {%info} if blessed($err) && $err->isa('Odoo::Error');
        die $err;
    }
    return $want ? @r : $r[0];
}

=head2 plan_stamp($op)

The C<acts_for> a plan records: the person and the service login.

=cut

sub plan_stamp ($class, $op) {
    my $ctx = $op->ctx;
    my $p   = $class->person($ctx);
    my $src = $class->require_service( $ctx, $op->op_name );
    return { %$p, via => $src->{via} };
}

=head2 own($op, model =E<gt> M, ids =E<gt> [...], field =E<gt> F)

Reads the records through the service client and returns their ids when every record's C<field> (a
many2one to C<res.partner>) is the person's partner or commercial partner. Otherwise dies
C<refused/not-yours> naming the model and the ids that failed. A record that is not there fails the same
way: the refusal says nothing about another customer, and nothing about whether the record exists. The
operation declares C<read> of the model in its C<read_scope>.

=cut

sub own ($class, $op, %a) {
    my $name = $op->op_name;
    my $bad  = sub ($why) { Odoo::Error->throw( kind => 'usage', message => "$name: own $why", fix => 'own( model => \'sale.order\', ids => [ 12 ], field => \'partner_id\' )' ) };
    defined $a{model} && !ref $a{model} && length $a{model} or $bad->('needs a model');
    defined $a{field} && !ref $a{field} && $a{field} =~ /\A[a-z_][a-z0-9_]*\z/ or $bad->('needs the name of the field that holds the partner');
    ref $a{ids} eq 'ARRAY' && @{ $a{ids} } or $bad->('needs a list of ids');
    my ( @ids, %seen );
    for my $i ( @{ $a{ids} } ) {
        defined $i && !ref $i && $i =~ /\A[1-9]\d*\z/ or $bad->('takes whole-number ids');
        push @ids, 0 + $i if !$seen{ 0 + $i }++;
    }
    my $ctx    = $op->ctx;
    my $person = $class->person($ctx);
    my $model  = $op->physical_model( $a{model} );
    my $svc    = $class->service($ctx);
    my %mine   = ( $person->{partner_id} => 1, $person->{commercial_partner_id} => 1 );
    my %got;
    my $rows = eval { $svc->client->model($model)->read( \@ids, [ $a{field} ] ) };
    if ( my $e = $@ ) {
        # a record that is not there reads as not yours
        die $e if !( blessed($e) && $e->isa('Odoo::Error') && $e->is_missing );
        $rows = [];
        for my $id (@ids) {
            my $one = eval { $svc->client->model($model)->read( [$id], [ $a{field} ] ) };
            die $@ if $@ && !( blessed($@) && $@->isa('Odoo::Error') && $@->is_missing );
            push @$rows, @{ $one // [] };
        }
    }
    for my $r ( @{ $rows // [] } ) {
        my $v = $r->{ $a{field} };
        $v = $v->[0] if ref $v eq 'ARRAY';
        $got{ $r->{id} } = 1 if defined $v && !ref $v && $v =~ /\A\d+\z/ && $mine{$v};
    }
    my @no = grep { !$got{$_} } @ids;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'not-yours',
        message => "$model " . join( ', ', @no ) . ( @no > 1 ? ' are' : ' is' ) . ' not yours',
        fix     => 'name only records that belong to the signed-in person',
    ) if @no;
    return @ids;
}

=head2 describe($ctx)

What the doctor reports of the service credential: C<< { configured, name, kind, login, signs_in, error } >>.
Never a credential.

=cut

sub describe ($class, $ctx) {
    my $src = eval { $class->source($ctx) };
    return { configured => 1, error => ( blessed($@) && $@->can('message') ? $@->message : "$@" ) =~ s/\s+\z//r } if $@;
    return { configured => 0 } if !$src;
    my %out = ( configured => 1, kind => $src->{kind}, name => $src->{name}, login => $src->{via} );
    my $svc = eval { $class->_build( $ctx, $src ) };
    if ( my $e = $@ ) { $out{signs_in} = 0; $out{error} = ( blessed($e) && $e->can('message') ? $e->message : "$e" ) =~ s/\s+\z//r; return \%out }
    my $uid = eval { $svc->client->uid };
    if ( my $e = $@ ) { $out{signs_in} = 0; $out{error} = ( blessed($e) && $e->can('message') ? $e->message : "$e" ) =~ s/\s+\z//r; return \%out }
    $out{signs_in} = 1;
    $out{uid}      = $uid;
    return \%out;
}

1;

package Odoo::Ops::Core::Check;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Check - connection, identity and profile check

=head1 DESCRIPTION

C<core.check>: the first thing to run against a new instance. Reports
the server version and series, who the configured login is, and - with
C<pack> - whether that pack's profile matches the live schema (every
mapped field present), naming anything missing. Needs no rights beyond
reading one's own user and C<fields_get>.

=cut

sub op_name ($class) { 'core.check' }
sub summary ($class) { 'Server version, identity, and profile validation for a pack' }
sub params ($class) {
    { pack => { type => 'str', help => 'profile pack to validate (e.g. crm)' } };
}
# the probes read the module list and the acting user; both may be refused
# to a restricted user, which the report then says
sub read_scope ($class) { { 'ir.module.module' => ['search_read'], 'res.users' => ['read'] } }

sub report ($self) {
    my $client = $self->client;
    my $me     = $client->whoami;
    my %r      = (
        server_version => $client->version->{server_version},
        series         => $client->server_series,
        uid            => $client->uid,
        login          => $me->{login},
        user_name      => $me->{name},
    );
    if ( my $pack = $self->param('pack') ) {
        my $p = $self->ctx->profile($pack);
        $r{profile} = {
            pack             => $p->pack,
            series           => $p->series,
            requested_series => $p->requested_series,
            path             => $p->path,
            warnings         => $p->warnings,
            validation       => $p->validate($client),
        };
        # instance facts the pack's models' behaviours ask for
        my ( %probes, %behaviours );
        for my $lm ( $p->models ) {
            my $b = $self->ctx->behaviour( $p->model_name($lm) );
            next if !$b->known;
            $behaviours{ $b->model } = { path => $b->path, series => $b->series, effects => scalar @{ $b->effects }, invariants => scalar @{ $b->invariants }, warnings => $b->warnings };
            $probes{$_} = 1 for @{ $b->probes };
        }
        $r{behaviours} = \%behaviours;
        $r{instance}   = $self->_probe( [ sort keys %probes ], $me ) if %probes;
    }
    return \%r;
}

# the probes a behaviour file may name: acting_user_email, module:<name>
sub _probe ($self, $names, $me) {
    my %out;
    for my $n (@$names) {
        if ( $n eq 'acting_user_email' ) {
            my $u = eval { $self->client->model('res.users')->read_one( $self->client->uid, ['email'] ) };
            $out{$n} = $u && $u->{email} ? 1 : 0;
        }
        elsif ( $n =~ /^module:(.+)\z/ ) {
            my $rows = eval { $self->client->model('ir.module.module')->search_read( [ [ 'name', '=', $1 ] ], ['state'] ) };
            $out{$n} = !$rows ? 'unreadable' : @$rows ? $rows->[0]{state} : 'absent';
        }
        else { $out{$n} = 'unknown probe' }
    }
    return \%out;
}

1;

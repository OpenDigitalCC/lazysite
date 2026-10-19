package Odoo::Ops::Client::Daemon;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;

use Odoo::Error;
use Odoo::Ops::Calls;
use Odoo::Ops::Daemon::Path;
use Odoo::Ops::File;
use Odoo::Ops::Wire;

our @ISA = ('Odoo::Ops::Calls');

=head1 NAME

Odoo::Ops::Client::Daemon - the same calls as in-process, answered by oomd when it is there

=head1 SYNOPSIS

    my $c = Odoo::Ops::Client::Daemon->new( name => 'site1', config => '/srv/site1/ops.conf' );
    my $r = $c->run( 'core.get', { model => 'res.partner', id => 7 }, credential => { session => $sid } );
    $r->{report}{rows};      # what oom-ops run prints
    $r->{via};               # 'daemon', or 'in-process' when the daemon was not there

=head1 DESCRIPTION

A client of L<oomd|Odoo::Ops::Daemon>. C<run>, C<check>, C<apply>, C<approve>,
C<revert> and C<resume> take the same arguments and answer the same hashes as
the same methods of L<Odoo::Ops::Service>, with a plan or a result as the same
objects, and refuse in the same way (an L<Odoo::Error> with C<kind>, C<code>
and C<fix>), whichever side did the work. C<call($request)> is the general
form.

The daemon is named by C<name> (its socket is found from the name, or from the
record a running daemon keeps) or by a C<socket> path, which may be anywhere;
nothing is scanned for.

A file parameter (see L<Odoo::Ops::File>) is given as C<< { name, bytes, mimetype? } >>
and travels as C<< { name, base64, mimetype } >>; the daemon decodes it before the
operation sees it, and its log never holds it.

The module loads only what talking to a socket needs: JSON, C<IO::Socket::UNIX>,
L<Odoo::Error> and the small L<Odoo::Ops::Daemon::Path>, L<Odoo::Ops::File>, L<Odoo::Ops::Wire> and
L<Odoo::Ops::Calls>. The in-process tree (L<Odoo::Ops::Service> and the registry,
the client, the context) is loaded only when a call falls back.

=head2 Fallback

With C<fallback> (the default when C<config> is given) a call runs in this
process, as without a daemon, when the socket is absent or the daemon's health
verb does not answer (checked at most every five seconds). The answer then
says C<< via => 'in-process' >>. A request that reached the daemon is never
repeated in-process: if the daemon fails after taking it, the call dies with
the C<transport> error, because a write may or may not have been done.
C<config> is an ops config (a path or an L<Odoo::Ops::Config>); C<credentials>
names the key files for labels, as the daemon's config does, for the
fallback's use.

Every answer carries C<via>.

=head2 No fallback

C<< fallback => 0 >> (the default when no C<config> is given) is the way to refuse
rather than fall back: a call made while the socket is absent or nothing answers on
it dies with an L<Odoo::Error> of kind C<transport> and code C<daemon-down>, whose
message names the daemon and its socket and whose C<fix> says how to start it. Nothing
is run in-process. An error from a daemon that took the request is not C<daemon-down>.

=head2 health

The daemon's answer to the health verb: name, version, pid, uptime, instance,
workers, request counts, packs. Dies with a C<transport> error when nothing
answers.

=cut

sub new ($class, %a) {
    Odoo::Error->throw( kind => 'usage', message => 'a daemon client needs a name or a socket' ) if !defined $a{name} && !defined $a{socket};
    my $self = bless {
        name        => $a{name},
        socket      => $a{socket},
        timeout     => $a{timeout} // 600,
        credential  => $a{credential},
        actor       => $a{actor},
        config      => $a{config},
        credentials => $a{credentials} // {},
        fallback    => $a{fallback} // ( defined $a{config} ? 1 : 0 ),
        healthy_at  => 0,
    }, $class;
    return $self;
}

sub socket ($self) { $self->{socket} // Odoo::Ops::Daemon::Path->socket_for( $self->{name} ) }

sub health ($self) { Odoo::Ops::Daemon::Path->health( socket => $self->socket ) }

sub _up ($self) {
    return 1 if time - $self->{healthy_at} < 5;
    my $ok = eval { Odoo::Ops::Daemon::Path->health( socket => $self->socket, timeout => 5 ); 1 };
    $self->{healthy_at} = $ok ? time : 0;
    return $ok ? 1 : 0;
}

sub _local ($self) {
    require Odoo::Ops::Config;
    require Odoo::Ops::Service;
    my $cfg = ref $self->{config} ? $self->{config} : Odoo::Ops::Config->load( $self->{config} );
    return $self->{service} //= Odoo::Ops::Service->new( config => $cfg, mode => 'inproc', credentials => $self->{credentials} );
}

my $SEQ = 0;

sub call ($self, $req) {
    my %r = %$req;
    $r{v} = 1;
    # the daemon's log names a request by this
    $r{id} //= $$ . '-' . ++$SEQ;
    $r{credential} //= $self->{credential} if defined $self->{credential};
    $r{actor}      //= $self->{actor}      if defined $self->{actor};
    for my $k (qw(plan journal)) {
        $r{$k} = File::Spec->rel2abs( $r{$k} ) if defined $r{$k} && !ref $r{$k} && ( $r{$k} =~ m{/} || $r{$k} =~ /\.json(?:l)?\z/ );
    }
    if ( $self->{fallback} && !$self->_up ) {
        my $res = $self->_local->execute( \%r );
        return { %$res, via => 'in-process' };
    }
    # a file's bytes travel as base64 (the daemon decodes them before the operation sees them)
    $r{params} = Odoo::Ops::File->to_wire( $r{params} ) if ref $r{params} eq 'HASH';
    my $sock = $self->socket;
    my $resp = eval { Odoo::Ops::Daemon::Path->ask( $sock, \%r, timeout => $self->{timeout} ) };
    if ( !$resp ) {
        my $e = $@;
        # the daemon is not there: say which, and what to do, so the caller can act without parsing
        if ( ref $e && $e->isa('Odoo::Error') && $e->{unreachable} ) {
            my $who = defined $self->{name} ? "oomd $self->{name}" : 'oomd';
            die Odoo::Error->new( kind => 'transport', code => 'daemon-down',
                message => "$who is not answering at $sock (" . ( $e->{why} // 'no answer' ) . ')' . ( $self->{fallback} ? '' : ' and this client does not fall back to running in-process' ),
                fix => 'start it with oomd --name NAME --config FILE (oomd status lists the daemons), or give the client a config to fall back to in-process' );
        }
        die $e;
    }
    $self->{healthy_at} = time;
    die Odoo::Ops::Wire::error_from_wire( $resp->{error} ) if !$resp->{ok};
    my $res = Odoo::Ops::Wire->from_wire( $resp->{result} );
    return { %$res, via => 'daemon' };
}

1;

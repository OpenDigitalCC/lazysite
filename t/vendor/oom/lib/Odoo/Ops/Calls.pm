package Odoo::Ops::Calls;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

=head1 NAME

Odoo::Ops::Calls - the named calls (run, check, apply, approve, revert, resume) over whatever answers C<call>

=head1 DESCRIPTION

The base class of L<Odoo::Ops::Service> (a call answered in this process) and
L<Odoo::Ops::Client::Daemon> (a call answered by oomd): the same arguments and
the same answers either way. It loads nothing, so the light client can inherit
it without loading the rest of OOM.

=cut

# each call also takes its arguments by name: run( op => N, params => {...}, credential => ..., actor => ... )
sub run ($self, @a) {
    my ( $op, $params, %o ) = @a && $a[0] eq 'op' ? do { my %n = @a; ( delete $n{op}, delete( $n{params} ) // {}, %n ) } : ( $a[0], ref $a[1] ? $a[1] : {}, @a[ ( ref $a[1] ? 2 : 1 ) .. $#a ] );
    return $self->call( { %o, op => $op, phase => 'run', params => $params } );
}

sub check ($self, @a) {
    my ( $op, $params, %o ) = @a && $a[0] eq 'op' ? do { my %n = @a; ( delete $n{op}, delete( $n{params} ) // {}, %n ) } : ( $a[0], ref $a[1] ? $a[1] : {}, @a[ ( ref $a[1] ? 2 : 1 ) .. $#a ] );
    return $self->call( { %o, op => $op, phase => 'check', params => $params } );
}

sub apply ($self, @a) {
    my ( $plan, %o ) = @a && $a[0] eq 'plan' ? do { my %n = @a; ( delete $n{plan}, %n ) } : @a;
    my %opt = map { exists $o{$_} ? ( $_ => delete $o{$_} ) : () } qw(continue_on_error batch stop_after only);
    return $self->call( { %o, phase => 'apply', plan => $plan, ( %opt ? ( options => \%opt ) : () ) } );
}

sub approve ($self, @a) {
    my ( $plan, %o ) = @a && $a[0] eq 'plan' ? do { my %n = @a; ( delete $n{plan}, %n ) } : @a;
    return $self->call( { %o, phase => 'approve', plan => $plan } );
}

sub revert ($self, @a) {
    my ( $journal, %o ) = @a && $a[0] eq 'journal' ? do { my %n = @a; ( delete $n{journal}, %n ) } : @a;
    return $self->call( { %o, phase => 'revert', journal => $journal } );
}

sub resume ($self, @a) {
    my ( $journal, %o ) = @a && $a[0] eq 'journal' ? do { my %n = @a; ( delete $n{journal}, %n ) } : @a;
    return $self->call( { %o, phase => 'resume', journal => $journal } );
}

1;

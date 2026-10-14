package Odoo::Ops::Result;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Result - what an apply actually did

=head1 DESCRIPTION

Always C<< applied => 1 >>, so it cannot be read as a plan. Outcome
counts - C<done skipped held failed not_attempted> - must sum to the
number of changes in the plan; the constructor refuses otherwise.
C<not_verified> counts the done changes that were not read back (a
call with no C<verify>, an unlink), so a zero C<verified> beside a zero
C<failed> can never mean "verified and none matched". C<verified>
counts the done creates and writes whose rows were read
back from the server afterwards.

=cut

my @OUTCOMES = qw(done skipped held failed not_attempted);

sub new ($class, %args) {
    my %counts = map { $_ => $args{counts}{$_} // 0 } @OUTCOMES;
    my $sum    = 0;
    $sum += $_ for values %counts;
    Odoo::Error->throw(
        kind    => 'usage',
        message => "result outcomes sum to $sum but the plan has $args{total} changes",
    ) if $sum != $args{total};
    return bless {
        applied          => 1,
        op               => $args{op},
        plan_fingerprint => $args{plan_fingerprint},
        total            => $args{total},
        counts           => \%counts,
        by_bucket        => $args{by_bucket} // {},
        verified         => $args{verified} // 0,
        not_verified     => $args{not_verified} // 0,
        journal          => $args{journal},
        started          => $args{started},
        finished         => $args{finished},
        stopped_by       => $args{stopped_by},
        invariants       => $args{invariants} // [],
        invariants_failed => $args{invariants_failed} // 0,
    }, $class;
}

sub applied    ($self) { 1 }
sub counts     ($self) { $self->{counts} }
sub total      ($self) { $self->{total} }
sub verified     ($self) { $self->{verified} }
sub not_verified ($self) { $self->{not_verified} }
sub stopped_by ($self) { $self->{stopped_by} }
sub invariants        ($self) { $self->{invariants} }
sub invariants_failed ($self) { $self->{invariants_failed} }
sub ok         ($self) { !$self->{counts}{failed} && !$self->{counts}{not_attempted} && !$self->{invariants_failed} }

sub to_hash ($self) { return { %$self } }

sub save ($self, $path) {
    open my $fh, '>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot write result $path: $!" );
    print {$fh} JSON::PP->new->utf8->canonical->pretty->encode( $self->to_hash );
    close $fh;
    return $path;
}

1;

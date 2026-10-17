package Odoo::Ops::Audit;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use IO::Handle;

use Odoo::Ops;
use Odoo::Error;

=head1 NAME

Odoo::Ops::Audit - one record per RPC call

=head1 DESCRIPTION

A sink for the records L<Odoo::Ops::Guard> writes. Each record has a
fixed shape - C<ts actor login service model method op outcome
fault_category ms> - and the sink refuses any other key, so a payload
or a credential cannot be added to the trail by accident (SM747 OB8).
A C<read> or C<search_read> record also carries C<fields>, the list the
call asked for (null when it named none), and, when the pack's tolerant
read (L<Odoo::Ops::Mailing::Common/search_read_named>) found which of them
this user may not compute, the first, refused call's record carries
C<refused_fields>: the names only, never a value. A write an administrator
makes undoing another login's run also carries C<for_login>, that login
(the other is C<login>, the one the calls are made as).

Outcomes: C<answered>, C<refused> (by scope or HTTP policy, before or
instead of an answer), C<fault> (Odoo said no), C<transport> (no usable
answer).

With C<path> the records are appended as JSON lines; without, they are
kept in memory (C<records>) - which is what the tests use.

=cut

my @FIELDS = qw(ts actor login for_login service model method op outcome fault_category ms fields refused_fields);
my %FIELD  = map { $_ => 1 } @FIELDS;

sub new ($class, %args) {
    my $self = bless { records => [], now => $args{now} // sub { time } }, $class;
    if ( my $path = $args{path} ) {
        open my $fh, '>>', $path
            or Odoo::Error->throw( kind => 'config', message => "cannot open audit $path: $!" );
        $fh->autoflush(1);
        $self->{fh} = $fh;
    }
    return $self;
}

sub fields ($class) { @FIELDS }

sub now ($self) { $self->{now}->() }

sub record ($self, %rec) {
    for my $k ( keys %rec ) {
        Odoo::Error->throw( kind => 'usage', message => "audit record cannot carry '$k'" )
            if !$FIELD{$k};
    }
    $rec{ts} //= $self->{now}->();
    push @{ $self->{records} }, \%rec if !$self->{fh};
    print { $self->{fh} } Odoo::Ops::json()->encode( \%rec ), "\n" if $self->{fh};
    return;
}

sub records ($self) { $self->{records} }

1;

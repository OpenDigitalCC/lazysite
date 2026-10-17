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
A sign-in that needs the second factor and the code step that follows it are
recorded as C<web> calls (C<session.authenticate>, C<session.totp>) carrying
C<second_factor: totp>; the code, the password and the trusted-device value
are never in a record.

Outcomes: C<answered>, C<refused> (by scope or HTTP policy, before or
instead of an answer), C<fault> (Odoo said no), C<transport> (no usable
answer).

A config that asks for a shared audit (C<audit_log>, C<audit_syslog>; see
L<Odoo::Ops::Trail>) gives the sink its trail: every record is counted for the
command's closing line and, at the C<transaction> level, written to the shared
destinations as an C<event: call> line as it happens. The run folder's file
keeps every record whatever the config says. C<event> writes a core line to
the trail.

With C<path> the records are appended as JSON lines; without, they are
kept in memory (C<records>) - which is what the tests use.

=cut

my @FIELDS = qw(ts actor login for_login service model method op outcome fault_category ms fields refused_fields second_factor);
my %FIELD  = map { $_ => 1 } @FIELDS;

sub new ($class, %args) {
    my $self = bless { records => [], now => $args{now} // sub { time }, trail => $args{trail} }, $class;
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
    $self->replay(%rec);
    $self->{trail}->call( \%rec ) if $self->{trail};
    return;
}

# a record into this sink only: what the run folder's file takes when the records
# held before it existed are moved in (the trail has them already)
sub replay ($self, %rec) {
    push @{ $self->{records} }, \%rec if !$self->{fh};
    print { $self->{fh} } Odoo::Ops::json()->encode( \%rec ), "\n" if $self->{fh};
    return;
}

sub trail ($self) { $self->{trail} }

# a core event on the shared audit (nothing when the config asks for none)
sub event ($self, @args) { $self->{trail} ? $self->{trail}->event(@args) : () }

# false-to-throw: with audit_required, the next call to Odoo is not made once a line could not be written
sub ready ($self) { $self->{trail}->check if $self->{trail}; return 1 }

sub records ($self) { $self->{records} }

1;

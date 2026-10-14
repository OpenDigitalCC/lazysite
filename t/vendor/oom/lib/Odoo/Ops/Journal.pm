package Odoo::Ops::Journal;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use IO::Handle;

use Odoo::Error;
use Odoo::Ops;

=head1 NAME

Odoo::Ops::Journal - append-only record of what an apply did

=head1 DESCRIPTION

JSON lines. The first line is the run header (C<< type => 'run' >>:
op, plan fingerprint, instance, actor, started); every following line
is one change (C<< type => 'change' >>: seq, bucket, action, model, id,
before, vals, after, outcome, error). Lines are flushed as they are
written, so a crash mid-apply leaves an exact record of how far it got
- which is what C<revert> reads.

=cut

sub create ($class, $path) {
    Odoo::Error->throw( kind => 'refused', code => 'exists', message => "journal $path already exists" )
        if -e $path;
    open my $fh, '>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot write journal $path: $!" );
    $fh->autoflush(1);
    return bless { fh => $fh, path => $path }, $class;
}

sub path ($self) { $self->{path} }

sub header ($self, %h) { $self->_line( type => 'run', %h ) }
sub change ($self, %c) { $self->_line( type => 'change', %c ) }
sub footer ($self, %f) { $self->_line( type => 'end', %f ) }

sub _line ($self, %rec) {
    print { $self->{fh} } Odoo::Ops::json()->encode( \%rec ), "\n";
    return;
}

=head2 read($path)

Class method: returns C<< ($header, \@changes, $footer) >>. A missing
footer means the apply did not finish.

=cut

sub read ($class, $path) {
    open my $fh, '<', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot read journal $path: $!" );
    my ( $header, @changes, $footer );
    while ( my $line = <$fh> ) {
        my $rec = Odoo::Ops::json()->decode($line);
        if    ( $rec->{type} eq 'run' )    { $header = $rec }
        elsif ( $rec->{type} eq 'change' ) { push @changes, $rec }
        elsif ( $rec->{type} eq 'end' )    { $footer = $rec }
    }
    close $fh;
    Odoo::Error->throw( kind => 'config', message => "journal $path has no run header" ) if !$header;
    return ( $header, \@changes, $footer );
}

1;

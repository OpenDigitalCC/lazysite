package Odoo::Ops::Journal;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename ();
use IO::Handle;

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Blob;

=head1 NAME

Odoo::Ops::Journal - append-only record of what an apply did

=head1 DESCRIPTION

JSON lines. The first line is the run header (C<< type => 'run' >>:
op, plan fingerprint, instance, actor, started); every following line
is one change (C<< type => 'change' >>: seq, bucket, action, model, id,
before, vals, after, outcome, error). Lines are flushed as they are
written, so a crash mid-apply leaves an exact record of how far it got
- which is what C<revert> reads.

A value over C<blob_min> (and the C<datas> and C<raw> of an C<ir.attachment>)
is written once to C<blobs/HEX> in the journal's folder and the line carries
its reference instead, as in L<Odoo::Ops::Blob>; the blob is on disk before the
line that names it.

=cut

sub create ($class, $path, %o) {
    Odoo::Error->throw( kind => 'refused', code => 'exists', message => "journal $path already exists" )
        if -e $path;
    open my $fh, '>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot write journal $path: $!" );
    $fh->autoflush(1);
    return bless { fh => $fh, path => $path, blob_min => $o{blob_min} }, $class;
}

=head2 append($path)

Class method: opens an existing journal to add change lines after its end. How a
later fact about an earlier change is recorded (a change that ended C<unknown> and
was then found made, or assumed so by a person): the journal is never edited, and
a reader that keys changes by C<seq> takes the last line of each.

=cut

sub append ($class, $path, %o) {
    Odoo::Error->throw( kind => 'config', message => "journal $path does not exist" ) if !-e $path;
    open my $fh, '>>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot append to journal $path: $!" );
    $fh->autoflush(1);
    return bless { fh => $fh, path => $path, blob_min => $o{blob_min} }, $class;
}

sub path ($self) { $self->{path} }

sub header ($self, %h) { $self->_line( type => 'run', %h ) }
sub change ($self, %c) {
    my %store;
    my $slim = Odoo::Ops::Blob->externalise( \%c, min => $self->{blob_min} // Odoo::Ops::Blob->min_default, store => \%store );
    Odoo::Ops::Blob->write( File::Basename::dirname( $self->{path} ), \%store ) if %store;
    $self->_line( type => 'change', %$slim );
}

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

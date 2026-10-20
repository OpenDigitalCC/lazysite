package LazysiteTest::OdooCustom::Mark;

# Test pack (SM1207): a WRITE operation whose one change is `custom` and whose apply
# touches no Odoo: it writes the pid of the process that applied it to a file the
# test names. Run through oomd the apply is in the daemon, a process that is not the
# test, and the Runner finds this class again by name there (Registry->new with no
# arguments, so from oomd's own environment and config). The file is the tell.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name     { 'shopc.mark' }
sub summary     { 'Leave the applying process id in a file, as a custom change' }
sub params      { return { file => { type => 'str', required => 1 } } }
sub read_scope  { return {} }
sub write_scope { return {} }
sub writes      { 1 }
sub buckets     { return [ { name => 'marked', meaning => 'a mark left by the applying process' } ] }
sub holds       { return [] }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'marked', action => 'custom', handler => $self->op_name, kind => 'mark',
        model => 'x.mark', id => 1, key => 'mark:1', vals => { file => $self->param('file') } );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    open my $fh, '>', $c->{vals}{file} or die "mark: $!\n";
    print {$fh} "$$\n";
    close $fh;
    return { id => 1, reported => 'mark' };
}

sub undo_custom { return ( {}, undef ) }

1;

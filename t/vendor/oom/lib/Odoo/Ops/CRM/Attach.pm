package Odoo::Ops::CRM::Attach;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(basename);

use Odoo::Error;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Core::Attach';

=head1 NAME

Odoo::Ops::CRM::Attach - attach files (card photos, documents) to one lead

=head1 DESCRIPTION

C<crm.attach>: a thin wrapper over L<Odoo::Ops::Core::Attach> that
speaks the CRM pack's logical names. It plans one attachment per file on
exactly one selected lead - a selector matching none or several is
refused. A file already attached to that lead under the same name with
the same content is C<unchanged>, so re-runs add nothing; the same name
with other content is held C<exists> (this wrapper never replaces; use
C<core.attach> with C<replace>). The plan holds the path and checksum of
each file, not its bytes, and apply refuses a file that changed since.
The read-back checks name, owner, size and checksum, not the content.

=cut

sub op_name ($class) { 'crm.attach' }
sub summary ($class) { 'Attach files to one selected lead' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        files => { type => 'list', required => 1, help => 'comma list of file paths' },
    };
}
sub read_scope  ($class) { { lead => ['search_read'], tag => ['search_read'], 'ir.attachment' => ['search_read'] } }
sub write_scope ($class) { { 'ir.attachment' => ['create'] } }

sub plan ($self) {
    my $model = $self->profile->model_name('lead');
    my $leads = $self->model('lead')->search_read( Odoo::Ops::CRM::Select->domain_for($self), ['id'] );
    Odoo::Error->throw( kind => 'usage', message => 'crm.attach needs exactly one lead; the selector matches ' . scalar(@$leads) )
        if @$leads != 1;
    my $id = $leads->[0]{id};
    my @items = map { { key => basename($_), model => $model, record => $id, file => $_ } } @{ $self->param('files') };
    $self->{models} = { $model => 1 };
    return $self->plan_items( \@items, replace => 0 );
}

1;

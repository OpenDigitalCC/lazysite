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

C<file> is the other way in: one file given as bytes (C<< { name, bytes,
mimetype? } >>, see L<Odoo::Ops::File>) in place of C<files>, with no path on the
host. The plan shows C<< { name, bytes, sha256, mimetype } >> and the bytes wait
in the run's blob store, as for L<Odoo::Ops::Core::Attach>.
The read-back checks name, owner, size and checksum, not the content.

=cut

sub op_name ($class) { 'crm.attach' }
sub summary ($class) { 'Attach files to one selected lead' }
sub pack    ($class) { 'crm' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'attach', meaning => 'a file is attached to the lead' },
        { name => 'unchanged', meaning => 'a file of that name with that content is already on the lead' },
    ];
}
sub holds ($class) {
    return [
        { name => 'exists', meaning => 'a different file of that name is on the lead; this wrapper never replaces (core.attach replace=1 does)' },
        { name => 'file-missing', meaning => 'the file cannot be read' },
        { name => 'too-large', meaning => 'the file is over max_bytes' },
        { name => 'duplicate-in-source', meaning => 'an earlier row names the same lead and file name' },
    ];
}

sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        files => { type => 'list', help => 'comma list of file paths (give files or file)' },
        file  => { type => 'file', max_bytes => 25 * 1024 * 1024, help => 'one file as bytes, in place of files: --file file=PATH on the command line' },
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
    my @paths = @{ $self->param('files') // [] };
    my $given = $self->param('file');
    Odoo::Error->throw( kind => 'usage', message => 'crm.attach: give files or file, not both', fix => 'files takes paths on this host; file takes bytes' ) if @paths && $given;
    Odoo::Error->throw( kind => 'usage', message => 'crm.attach: give files or file', fix => 'oom-ops describe crm.attach lists the parameters' ) if !@paths && !$given;
    my @items = $given ? ( { key => $given->{name}, model => $model, record => $id, file => $given } )
        : map { { key => basename($_), model => $model, record => $id, file => $_ } } @paths;
    $self->{models} = { $model => 1 };
    return $self->plan_items( \@items, replace => 0 );
}

1;

package Odoo::Ops::CRM::Select;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Journal;

=head1 NAME

Odoo::Ops::CRM::Select - which leads an operation acts on

=head1 DESCRIPTION

Shared by operations that act on a set of leads. Selectors combine
(AND); at least one is required, so nothing ever acts on the whole CRM
by omission:

    tag      leads carrying this tag (by name, exact, case-insensitive)
    domain   an Odoo domain on crm.lead (JSON, physical field names)
    run      a journal.jsonl: the leads that run created or wrote
    ids      comma list of lead ids

C<params> returns the parameter spec to merge into an operation's;
C<domain_for($op)> resolves the operation's params to a domain.

=cut

sub params ($class) {
    return (
        tag    => { type => 'str',  help => 'select leads with this tag' },
        domain => { type => 'json', help => 'select by Odoo domain (physical fields)' },
        run    => { type => 'path', help => 'select the leads a run created or wrote (journal.jsonl)' },
        ids    => { type => 'list', help => 'select lead ids' },
    );
}

sub domain_for ($class, $op) {
    my $p = $op->profile;
    my @d;
    if ( defined( my $name = $op->param('tag') ) ) {
        my $name_f = $p->field( tag => 'name' );
        my $tags = $op->model('tag')->search_read( [ [ $name_f, '=ilike', $name ] ], [$name_f] );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-tag', message => "no tag named '$name'", fix => 'name a tag that exists on the instance' ) if !@$tags;
        push @d, [ $p->field( lead => 'tags' ), 'in', [ map { $_->{id} } @$tags ] ];
    }
    push @d, @{ $op->param('domain') } if $op->param('domain');
    if ( my $journal = $op->param('run') ) {
        my ( undef, $changes ) = Odoo::Ops::Journal->read($journal);
        my $lead_model = $p->model_name('lead');
        my %ids = map { $_->{id} => 1 }
            grep { $_->{outcome} eq 'done' && ( $_->{model} // '' ) eq $lead_model && $_->{id} } @$changes;
        push @d, [ 'id', 'in', [ sort { $a <=> $b } keys %ids ] ];
    }
    push @d, [ 'id', 'in', [ map { 0 + $_ } @{ $op->param('ids') } ] ] if $op->param('ids');
    Odoo::Error->throw(
        kind    => 'usage',
        message => $op->op_name . ' needs a selector: tag, domain, run or ids',
    ) if !@d;
    return \@d;
}

1;

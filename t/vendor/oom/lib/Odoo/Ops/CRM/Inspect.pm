package Odoo::Ops::CRM::Inspect;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Inspect - the shape of a CRM, in aggregates only

=head1 DESCRIPTION

C<crm.inspect>: validates the crm profile against the server, reports
which CRM-related modules are installed (where the account may read
the module list), and counts leads - active and archived, by type,
stage, tag, source, team and salesperson, with and without an email
address, and how many email addresses are shared by more than one
lead. No lead is listed: the output is counts and configuration names
only, safe to show in a conversation.

=cut

my @MODULES = qw(crm utm mass_mailing mass_mailing_crm crm_iap_enrich crm_iap_mine
    mail website_crm sales_team);

sub op_name ($class) { 'crm.inspect' }
sub summary ($class) { 'Profile check, installed modules, and lead counts (aggregates only)' }
sub pack    ($class) { 'crm' }
sub params ($class) { {} }
sub read_scope ($class) {
    {   lead               => [qw(search_count read_group search_read)],
        'ir.module.module' => ['search_read'],
    };
}

sub report ($self) {
    my $p      = $self->profile;
    my $client = $self->client;
    my %r      = (
        server_version => $client->version->{server_version},
        profile        => {
            pack       => $p->pack,
            series     => $p->series,
            warnings   => $p->warnings,
            validation => $p->validate($client),
        },
    );

    $r{modules} = $self->_modules;

    my $lead = $self->model('lead');
    my $f    = sub ($lf) { $p->has_field( lead => $lf ) ? $p->field( lead => $lf ) : undef };
    my $archived = [ [ $f->('active'), '=', JSON::PP::false ] ];

    $r{leads}{active}   = $lead->count( [] );
    $r{leads}{archived} = $lead->count($archived);
    if ( my $email = $f->('email') ) {
        $r{leads}{with_email}    = $lead->count( [ [ $email, '!=', JSON::PP::false ] ] );
        $r{leads}{without_email} = $r{leads}{active} - $r{leads}{with_email};
        $r{leads}{emails_shared_by_several} = $self->_shared_emails($email);
    }
    for my $lf (qw(type stage tags source medium campaign team salesperson)) {
        my $pf = $f->($lf) or next;
        next if !$p->validated || !$p->descriptor( lead => $lf );
        $r{by}{$lf} = $self->_group( $lead, $pf );
    }
    return \%r;
}

sub _modules ($self) {
    my $rows = eval {
        $self->client->model('ir.module.module')
            ->search_read( [ [ 'name', 'in', \@MODULES ] ], [qw(name state)] );
    };
    if ( !$rows ) {
        my $err = $@;
        return { unreadable => blessed($err) && $err->isa('Odoo::Error')
                ? ( $err->fault_category // $err->kind ) : 'error' };
    }
    my %state = map { $_->{name} => $_->{state} } @$rows;
    return { map { $_ => $state{$_} // 'not present' } @MODULES };
}

# { label => count }, with "(none)" for the empty group. Works with the
# 16 row shape (<field>_count) and the 17+ one (__count).
sub _group ($self, $model, $pf) {
    my $rows = $model->read_group( [], [$pf], [$pf], lazy => 1 );
    my %out;
    for my $row (@$rows) {
        my $v = $row->{$pf};
        my $label = ref $v eq 'ARRAY' ? $v->[1] : ( defined $v && $v ne '0' && $v ne '' ) ? $v : '(none)';
        $out{$label} += $row->{__count} // $row->{"${pf}_count"} // 0;
    }
    return \%out;
}

sub _shared_emails ($self, $pf) {
    my $rows = $self->model('lead')->all( [ [ $pf, '!=', JSON::PP::false ] ], [$pf] );
    my %n;
    $n{ lc( $_->{$pf} =~ s/^\s+|\s+\z//gr ) }++ for grep { $_->{$pf} } @$rows;
    return scalar grep { $_ > 1 } values %n;
}

1;

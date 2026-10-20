package Odoo::Test::Ops::MayAsk;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';
use Odoo::Ops::Pack;

# What the login may do, by Odoo::Ops::Pack->may and ->has_groups (live tests of lab-36 O-29; ODOO_OPS_NAMESPACES=Odoo::Test::Ops).

sub op_name ($class) { 'test.mayask' }
sub summary ($class) { 'What the login may do on some models, as Odoo answers' }
sub pack    ($class) { undef }
sub params  ($class) { { models => { type => 'list', required => 1, help => 'physical models' }, groups => { type => 'list', help => 'group xml ids' } } }

sub read_scope ($class) {
    my %s = ( 'res.users' => ['has_group'] );
    push @{ $s{$_} }, 'check_access_rights', 'has_access' for qw(res.partner ir.cron ir.model res.users res.partner.category);
    return \%s;
}

sub report ($self) {
    my %may = map { my $m = $_; ( $m => { map { $_ => Odoo::Ops::Pack->may( $self, $m, $_ ) } qw(read write create unlink) } ) } @{ $self->param('models') };
    my $groups = $self->param('groups');
    return { may => \%may, ( $groups && @$groups ? ( has => Odoo::Ops::Pack->has_groups( $self, @$groups ) ) : () ) };
}

1;

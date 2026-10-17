package Odoo::Accounts;
use strict; use warnings; use Odoo::Tools::Accounts; our @ISA = ('Odoo::Tools::Accounts'); our $VERSION = $Odoo::Tools::Accounts::VERSION;
warn "Odoo::Accounts is now Odoo::Tools::Accounts (package odoo-oom-tools); the old name is kept for one release\n";
1;
__END__

=head1 NAME

Odoo::Accounts - the old name of L<Odoo::Tools::Accounts>, kept for one release

=cut

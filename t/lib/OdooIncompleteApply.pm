package OdooIncompleteApply;

# SM1148: makes OOM's apply report what an invariant failure after a write
# reports (OOM's O-4: the record WAS made and the result is not `ok`), in a CHILD
# process, beside OdooInject. The real apply runs against the fake Odoo and
# makes the record; only the verdict on the result is changed, by ODOO_FAKE_APPLY:
#
#   invariant   the invariants failed after the write: done, but not `ok`
#   failed      the change itself failed: nothing done (a contrast - that one is
#               not a delivery)
use strict;
use warnings;

BEGIN {
    require Odoo::Ops::Runner;
    my $real = \&Odoo::Ops::Runner::apply;
    no warnings 'redefine';
    *Odoo::Ops::Runner::apply = sub {
        my $r    = $real->(@_);
        my $mode = $ENV{ODOO_FAKE_APPLY} // '';
        if ( $mode eq 'invariant' ) {
            $r->{invariants_failed} = 1;
        }
        elsif ( $mode eq 'failed' ) {
            $r->{counts}{failed} = 1;
            $r->{counts}{done}   = 0;
        }
        return $r;
    };
}

1;

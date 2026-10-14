package OdooInject;

# SM747 E: OOM's fake Odoo, injected into a CHILD process - the MCP server and
# the manager API run as separate scripts, and a test reaches them only as one.
# Loaded with PERL5OPT=-MOdooInject (and t/lib on the path) by the test that
# starts the child, so nothing in the product looks for it: the engine sees
# $Lazysite::Odoo::TRANSPORT set, exactly as an in-process test sets it.
#
# Each child starts a fresh fake shop (products seeded), so a test asks one
# thing per request. No network: the transport is OOM's own test double.
use strict;
use warnings;
use OdooTest ();

BEGIN {
    my $lib = OdooTest::oom_lib();
    if ( -f "$lib/Odoo/Ops.pm" ) {
        unshift @INC, $lib, OdooTest::oom_test_lib();
        OdooTest::pretend_released();
        no warnings 'once';
        $Lazysite::Odoo::TRANSPORT = OdooTest::fake_shop();
    }
}

1;

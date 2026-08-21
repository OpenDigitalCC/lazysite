#!/usr/bin/perl
# SM446: adding a domain must say that TLS is not part of the step.
#
# The add flow provisions a content folder, seeds a page and reports success -
# so every signal the operator receives says ready. The first thing that
# disagrees is a visitor's browser. On the reported case the certificate served
# covered a different host entirely, and nothing in the manager had mentioned
# it.
#
# NOT a request for lazysite to issue certificates - it does not and should
# not; the certificate is the front end's business. The gap was that nothing
# said so at the moment it mattered, and domain-check ALREADY diagnoses it
# precisely. So this is a prompt, not a feature: it runs the existing check and
# reports what the check found.
#
# THREE THINGS IT MUST NOT DO, all asserted, because each would be worse than
# the silence it replaces.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/domains.md';
plan skip_all => 'domains page missing' unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

my ($create) = $src =~ /function createDomain\(\)\s*\{(.*?)\n\}/s;
ok( defined $create, 'createDomain is present' ) or BAIL_OUT('cannot find it');

like( $create, qr/showTlsNotice\(host\)/,
    'a successful add prompts the reachability check' )
    or diag( 'Without it the operator learns from a visitor.' );

my ($fn) = $src =~ /function showTlsNotice\(host\)\s*\{(.*?)\n\}\n/s;
ok( defined $fn, 'showTlsNotice is present' );

like( $fn, qr/does NOT set up DNS or a TLS certificate/,
    'it says plainly that this step did not do TLS' )
    or diag( 'That sentence is the whole finding: the operator believed the '
        . 'domain was ready because every signal said so.' );

like( $fn, qr/action=domain-check/,
    'and runs the check that already answers well' )
    or diag( 'Restating the diagnosis here would be a second, worse copy of '
        . 'a message that is already good.' );

like( $fn, qr/first\.label.*first\.detail/s,
    "reporting the check's OWN wording rather than a summary" );

# It must not report a failed CHECK as a failed ADD - the domain was added.
like( $fn, qr/\.catch\(/, 'a check that cannot run is handled' );
like( $fn, qr/Added\. The reachability check could not run/,
    'and says the domain WAS added even when the check fails' )
    or diag( 'Telling an operator their domain failed when it did not would '
        . 'send them to undo work that succeeded.' );

# And it must not cry wolf on a domain that is fine.
like( $fn, qr/is live and served by this instance/,
    'a reachable domain is confirmed, not just left silent' )
    or diag( 'Silence after a check is indistinguishable from no check.' );

done_testing();

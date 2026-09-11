#!/usr/bin/perl
# N13-04, then SM842: the audit trail's switch has one reader.
#
# N13-04 found two writers of the audit trail - Lazysite::Audit, and
# plugins/form-handler.pl, which wrote form submissions to the same file
# directly because it loaded no modules - and pinned the handler's marked copy
# of the switch reader to the module's, so `audit_trail: off` could not stop one
# and not the other.
#
# SM842 removed the reason for the copy. The form handler now loads the module
# tree (delivery is Lazysite::Handlers', which the timer calls too), so it writes
# its submission line through Lazysite::Audit and the copy is gone. What this
# holds now is that it STAYS gone: a second writer, or a second reading of the
# switch, is the drift N13-04 existed to catch, and the cheapest way to prevent
# two readers disagreeing is to have one.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Audit ();

my $root = repo_root();
open my $fh, '<:utf8', "$root/plugins/form-handler.pl" or die $!;
my $src = do { local $/; <$fh> };
close $fh;
( my $code = $src ) =~ s/^\s*#.*$//mg;

unlike( $code, qr/sub _audit_trail_off/, 'the form handler carries no copy of the switch reader' );
unlike( $code, qr/audit\.log/, 'and opens no audit file of its own' );
like( $code, qr/Lazysite::Audit::audit_log\(/, 'it writes the submission line through the module' );

my $h = do { open my $x, '<', "$root/lib/Lazysite/Handlers.pm" or die $!; local $/; <$x> };
( my $hcode = $h ) =~ s/^\s*#.*$//mg;
like( $hcode, qr/Lazysite::Audit::audit_log\(/, 'and so does every handler delivery' );
unlike( $hcode, qr/audit\.log|audit_trail/, 'with no reading of the switch of its own' );

# And the direction a reader can get wrong: absence is ON.
my $d = site_tempdir();
make_path("$d/lazysite");
open my $o, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$o} "site_name: T\n";
close $o;
is( Lazysite::Audit::audit_trail_state("$d/lazysite"), 'on',
    'a site that never set the key is recording - absence is on, not off' );

done_testing();

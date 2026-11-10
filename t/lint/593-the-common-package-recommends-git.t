#!/usr/bin/perl
# SM1426: lazysite-common RECOMMENDS git.
#
# Content history (SM085) runs `git`, and the container image installs it (SM1423). The
# package that ships the engine must say the same, or a host installed from the .deb has
# a feature switch that cannot work. It is Recommends, not Depends: history is off until
# a site turns it on, and the engine saves without git (`lazysite check` warns). The field
# is read from debian/control's lazysite-common stanza, the one `dpkg-deb` is built from.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
open my $fh, '<', "$root/debian/control" or die "debian/control: $!";
my $control = do { local $/; <$fh> };
close $fh;

my ($stanza) = grep { /^Package:\s*lazysite-common$/m } split /\n\n+/, $control;
ok( defined $stanza, 'a lazysite-common stanza' ) or BAIL_OUT('no stanza');

my ($recommends) = $stanza =~ /^Recommends:\n((?:[ \t].*\n?)*)/m;
ok( defined $recommends, 'it has a Recommends field' ) or BAIL_OUT('no Recommends');
like( $recommends, qr/^\s*git,?\s*$/m, 'git is recommended' );

my ($depends) = $stanza =~ /^Depends:\n((?:[ \t].*\n?)*)/m;
unlike( $depends // '', qr/^\s*git\b/m, 'and not required' );

done_testing();

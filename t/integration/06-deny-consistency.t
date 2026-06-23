#!/usr/bin/perl
# Single canonical agent-facing deny list. The deny set is expressed in three
# places that drifted apart historically (CAI reconciliation, 2026-06): the
# .well-known/ai-partner machine block, the onboarding brief, and the dav's
# enforcement. This test is the source of record: it pins the two agent-facing
# copies to one canonical list and checks the dav backs them, so they can no
# longer diverge silently.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# THE canonical agent-facing deny list. Change it here, in lock-step with the
# two rendered copies below, or this test fails.
my @CANONICAL = sort qw(
    /cgi-bin/ /manager/ /lazysite/auth/ /lazysite/forms/ /lazysite/cache/
    /lazysite/logs/ /lazysite/manager/ /lazysite/templates/
    /lazysite/lazysite.conf *.pl
);

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

# Pull the quoted entries out of a `deny: [ ... ]` / `"deny": [ ... ]` array.
sub deny_set {
    my ( $file, $marker ) = @_;
    my $text = slurp($file);
    $text =~ /$marker\s*\[(.*?)\]/s or die "no deny array in $file";
    my @items = $1 =~ /"([^"]+)"/g;
    return [ sort @items ];
}

my $wk = deny_set( "$root/starter/.well-known/ai-partner.md", qr/"deny"\s*:/ );
my $br = deny_set( "$root/tools/lazysite-users.pl",           qr/\bdeny:/ );

is_deeply( $wk, \@CANONICAL,
    '.well-known/ai-partner deny list matches the canonical set' );
is_deeply( $br, \@CANONICAL,
    'onboarding-brief deny list matches the canonical set' );
is_deeply( $wk, $br,
    'the two agent-facing deny lists are identical to each other' );

# The dav is the enforcement: confirm its default blocked_paths cover the
# non-lazysite/ entries the agent-facing list advertises (the whole lazysite/
# subtree is denied structurally, so only cgi-bin + the docroot manager need
# to appear as explicit blocked_paths).
my $dav = slurp("$root/lazysite-dav.pl");
$dav =~ /blocked_paths\s*=>\s*\[\s*qw\((.*?)\)/s
    or die "no default blocked_paths in lazysite-dav.pl";
my %bp = map { $_ => 1 } split ' ', $1;
ok( $bp{'cgi-bin'}, 'dav blocked_paths includes cgi-bin' );
ok( $bp{'manager'}, 'dav blocked_paths includes the docroot manager' );

# whoami reports scope.deny to agents; it must be the same canonical set, or
# an agent trusting whoami sees a different denied set than the dav enforces
# (e.g. believing all of lazysite/forms/ is writable bar the smtp password).
my $mapi_src = slurp("$root/lazysite-manager-api.pl");
$mapi_src =~ /deny\s*=>\s*\[(.*?)\]/s
    or die "no whoami scope.deny in lazysite-manager-api.pl";
is_deeply( [ sort ( $1 =~ /'([^']+)'/g ) ], \@CANONICAL,
    'whoami scope.deny matches the canonical set' );

done_testing();

#!/usr/bin/perl
# DRIFT GUARD (0.8.1 cross-plane consistency): lazysite-dav.pl is a deliberately
# self-contained CGI (docs/architecture/code-quality.md: the manager helpers are
# duplicated here by convention, not imported). That convention is a standing
# drift risk - a security list updated in the canonical Lazysite::Manager::Common
# but not in the DAV copy silently opens a hole (exactly the class the SM127 bug
# belonged to). This test mechanically pins the duplicated SECURITY data equal to
# its canonical source, and asserts the DAV scope match keeps its boundary-safe
# idiom, without forcing the DAV to import the module.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use Lazysite::Manager::Common ();

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; <$fh> }
my $dav = slurp("$root/lazysite-dav.pl");

# --- @DANGEROUS_EXT: the executable/config-file extension blocklist -------------
# Canonical list from the module; DAV keeps a copy in `our @DANGEROUS_EXT = qw(...)`.
my @canon = @Lazysite::Manager::Common::DANGEROUS_EXT;
cmp_ok( scalar @canon, '>=', 10, 'canonical @DANGEROUS_EXT is populated' );

my ($dav_ext_block) = $dav =~ /our \@DANGEROUS_EXT\s*=\s*qw\(([^)]*)\)/s;
ok( $dav_ext_block, 'lazysite-dav.pl declares its own @DANGEROUS_EXT copy' );
my @dav_ext = split ' ', ( $dav_ext_block // '' );

is_deeply(
    [ sort @dav_ext ],
    [ sort @canon ],
    'DAV @DANGEROUS_EXT is identical to Lazysite::Manager::Common (no drift - a new dangerous extension must be added to BOTH)'
) or diag "canonical: @{[sort @canon]}\nDAV copy:  @{[sort @dav_ext]}";

# --- scope match keeps the boundary-safe idiom ---------------------------------
# The shared outside_all_scopes / path_out_of_scope compare with `$rel eq $s ||
# index($rel, "$s/") == 0` so a scope of 'content/a' does NOT match 'content/ab'.
# The DAV reimplements the union match inline; assert it kept the boundary-safe
# form (a naive index($rel,$s)==0 would be a scope-escape).
like( $dav, qr{index\(\s*\$rel\s*,\s*"\$s/"\s*\)\s*==\s*0},
    'DAV scope match uses the boundary-safe "$s/" idiom (not a bare prefix match)' );
unlike( $dav, qr{index\(\s*\$rel\s*,\s*\$s\s*\)\s*==\s*0},
    'DAV scope match does NOT use a bare index($rel,$s) prefix (would let content/a match content/ab)' );

# --- and the DAV scope match agrees with the shared helper behaviourally --------
# Replicate a matrix through Common::outside_all_scopes and assert the expected
# allow/deny, documenting the contract the DAV inline copy must uphold.
my @scopes = ('content/a');
is( Lazysite::Manager::Common::outside_all_scopes( \@scopes, 'content/a/x.md' ), 0, 'inside scope: allowed' );
is( Lazysite::Manager::Common::outside_all_scopes( \@scopes, 'content/ab/x.md' ), 1, 'sibling-prefix: denied' );
is( Lazysite::Manager::Common::outside_all_scopes( \@scopes, 'content/b/x.md' ), 1, 'other tree: denied' );
is( Lazysite::Manager::Common::outside_all_scopes( [], 'anything' ), 0, 'empty scope set: unconfined' );

done_testing;

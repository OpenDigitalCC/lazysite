#!/usr/bin/perl
# SM237 DRIFT GUARD: %KNOWN_ACTION in lazysite-manager-api.pl is the full set of
# action names the dispatch chain recognises, and it exists so the token-client
# gate (which runs BEFORE dispatch and knows only %need, the token subset) can
# tell "exists, but cookie-only" from "no such action". Those answers send an
# agent in opposite directions, so the set being wrong is worse than not having
# it: a new action missing from the list would be reported as a typo.
#
# The dispatch is an if/elsif chain rather than a table, so the list is a literal
# and cannot be derived at runtime. This test derives it from the source instead
# and pins the two equal, which makes drift impossible without making the chain a
# table (worth doing, and a separate request).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $path = "$root/lazysite-manager-api.pl";
open my $fh, '<', $path or die "$path: $!";
my $src = do { local $/; <$fh> };
close $fh;

# The dispatch chain: every `$action eq '<name>'` comparison.
my %dispatched = map { $_ => 1 } ( $src =~ /\$action\s+eq\s+'([a-z0-9_-]+)'/g );
cmp_ok( scalar keys %dispatched, '>=', 90,
    'the dispatch chain was found and parsed' );

# The declared set: the qw list inside `my %KNOWN_ACTION = map { $_ => 1 } qw( ... );`
my ($block) = $src =~ /my\s+%KNOWN_ACTION\s*=\s*map\s*\{[^}]*\}\s*qw\((.*?)\)\s*;/s;
ok( defined $block, '%KNOWN_ACTION is declared as a qw list' );
my %declared = map { $_ => 1 } grep { length } split /\s+/, ( $block // '' );

# Equal in both directions. A missing entry makes a real action look like a typo;
# a stale entry makes a removed action look callable.
for my $a ( sort keys %dispatched ) {
    ok( $declared{$a}, "dispatched action '$a' is declared in %KNOWN_ACTION" );
}
for my $a ( sort keys %declared ) {
    ok( $dispatched{$a}, "declared action '$a' is really dispatched" );
}

# The gate must actually consult it, and must give two distinct answers.
like( $src, qr/if\s*\(\s*\$KNOWN_ACTION\{\$action\}\s*\)/,
    'the token gate consults %KNOWN_ACTION' );
like( $src, qr/Action not available to token clients/,
    'a recognised-but-cookie-only action keeps its message' );
like( $src, qr/Unrecognised action name/,
    'an unrecognised name gets a distinct message' );

done_testing();

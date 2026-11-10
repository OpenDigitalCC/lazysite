#!/usr/bin/perl
# SM1424 (n804): THE UPGRADE NOTE FOR THE LAYER ROLES HOLDS TO THE ADOPTION'S
# CONDITIONS.
#
# The 0.16.9 note said opening the Groups page "now adds analysts and
# lead-readers on an older site", with none of the conditions
# _adopt_layer_roles (tools/lazysite-users.pl) holds to, and a tester expected
# them on a site that has no bundle groups. The note now says: an operator group
# and a shipped bundle group; a role the site lacks and has not had; none where
# the operator group carries the `seeded` mark; no members.
#
# The conditions are also read from the code, so the note cannot drift from them:
# the adoption must still return without a shipped bundle, and without a
# bootstrapped store.
#
# With the note reverted the first four assertions fail.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my $up = slurp("$root/UPGRADE.md");
my ($i) = $up =~ /(- The Groups page adds the two roles too.*?)(?=\n- )/s;
ok( defined $i, 'the note is there' ) or BAIL_OUT('no note');
$i =~ s/\s+/ /g;
like( $i, qr/at least one shipped bundle group/,                  'it names the bundle group the roles need' );
like( $i, qr/a site without the bundle layer gets neither/,       'and says a site without the layer gets none' );
like( $i, qr/has not had before/,                                 'and that a role the site had is not added again' );
like( $i, qr/with no members/,                                    'and that they arrive with no members' );

my $code = slurp("$root/tools/lazysite-users.pl");
my ($sub) = $code =~ /(sub _adopt_layer_roles \{.*?\n\})/s;
like( $sub // '', qr/return unless _bootstrapped\(\$gs\);/,                       'the code still needs a bootstrapped store' );
like( $sub // '', qr/return unless grep \{ \$shipped->\{\$_\} \} keys %\{\$nesting\};/, 'and a shipped bundle group' );

done_testing;

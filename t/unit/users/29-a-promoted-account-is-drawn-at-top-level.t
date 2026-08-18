#!/usr/bin/perl
# SM376: a promoted account must stop being drawn under its creator.
#
# REPORTED FROM THE MANAGER UI on 0.10.14: a human user "still doesn't have the
# option to move to top level". Both halves of that are true at once, which is
# what made it confusing:
#
#   the TREE      drew the account nested under its creator
#   the CONTROL   "top level (no parent)" was hidden, correctly by its own
#                 lights, because the account already WAS top level
#
# account-promote clears managed_by to the EMPTY STRING - a deliberate "no
# parent" - and created_by is immutable and never clears. The page computed the
# parent as `s.managed_by || s.created_by` in SIX places, and "" is falsy in
# JavaScript, so every one of them re-parented a promoted account to its creator
# permanently.
#
# THE JAVASCRIPT IS RUN, NOT READ. The defect is entirely in what the expression
# evaluates to, so a test that greps for the fixed source would pass on any
# string containing the right words. This extracts the function from the shipped
# page and executes it in node against the states the CLI actually writes.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $page = "$root/starter/manager/users.md";
plan skip_all => "no $page" unless -f $page;

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

my ($fn) = $src =~ /(function parentOfSettings\s*\(.*?\n\}\n)/s;
ok( $fn, 'the page carries parentOfSettings' ) or do { done_testing(); exit };

# The states the CLI writes, taken from what account-create and account-promote
# actually store rather than from what they are described as storing:
#   sub-user   managed_by "boss"        created_by "boss"   top_level false
#   promoted   managed_by ""            created_by "boss"   top_level TRUE
#   operator   no provenance at all                         top_level true
my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/t.js" or die $!;
print {$js} <<"JS";
$fn
var cases = {
  sub_user: { managed_by: 'boss', created_by: 'boss', top_level: false },
  promoted: { managed_by: '',     created_by: 'boss', top_level: true  },
  operator: {                                          top_level: true },
  reparented: { managed_by: 'other', created_by: 'boss', top_level: false }
};
var out = {};
for (var k in cases) out[k] = parentOfSettings(cases[k]);
console.log(JSON.stringify(out));
JS
close $js;

my $json = `\Q$node\E \Q$dir/t.js\E 2>&1`;
my $got  = eval { require JSON::PP; JSON::PP::decode_json($json) };
ok( $got, 'the function ran' ) or do { diag($json); done_testing(); exit };

is( $got->{sub_user}, 'boss',
    'a sub-user is drawn under the account that manages it' );

is( $got->{promoted}, '',
    'a PROMOTED account is drawn at top level, not under its creator' )
    or diag( 'This is the defect: created_by is immutable, so falling back to '
        . 'it re-parents a promoted account forever. The operator sees it '
        . 'nested with no control to move it, because the control is hidden '
        . 'on the grounds that it is already top level.' );

is( $got->{operator}, '', 'an operator-created account has no parent' );

is( $got->{reparented}, 'other',
    'a reassigned account follows managed_by, not the creator it came from' )
    or diag( 'managed_by must still win when it is SET - the fix must not '
        . 'collapse into "always use created_by" or reassignment stops '
        . 'showing.' );

done_testing();

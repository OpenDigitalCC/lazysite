#!/usr/bin/perl
# SM742 follow-up: the NOT NULL translation is reached through a real insert,
# not only through a synthetic error string.
#
# THE GAP THIS CLOSES, and it was found in the field rather than here. SM742
# maps four SQLite constraint shapes onto our own sentences, and
# t/unit/data/52 proves each mapping by handing _clean_db_error the string the
# driver would emit. That proves the translation. It does not prove the string
# can ever arrive.
#
# The field agent testing 0.13.0 reached the UNIQUE branch easily and then
# reported, precisely, that they could not reach NOT NULL: a descriptor field
# marked `required` is refused by Value.pm's own check before any SQL runs, so
# the database never gets the chance to object. They could not construct the
# case from the descriptor surface and said so rather than reporting the value
# layer's sentence as proof of the translator.
#
# They were right, and the answer is stronger than either of us could see from
# where we were standing. THE NOT NULL BRANCH IS NOT REACHABLE THROUGH ANY
# SUPPORTED INSERT PATH.
#
# SQLite.pm emits NOT NULL for exactly two things: a field marked `required`,
# and a non-auto key (auto_key being true only when the key is literally named
# `id`). Value.pm refuses BOTH before any SQL runs - `required` at its own
# check, and a missing key at a dedicated one with a better sentence than the
# translator's. Those two conditions are the same two, so nothing that would
# violate the constraint ever reaches the database.
#
# I looked for the gap in the obvious place and found one: a key not named
# `id`, carrying NOT NULL without being `required`. That is a common shape -
# the agent's own probe table was keyed on `code`. It is also already guarded.
#
# WHAT THIS FILE IS FOR, THEREFORE. It pins the behaviour that actually
# happens, so the earlier check cannot be removed as redundant by somebody
# reading SQLite.pm and concluding the constraint will catch it. And it records
# the reachability answer where the next person to wonder will find it, rather
# than in a filing they would have to know exists.
#
# WHAT IT MEANS FOR SM742: t/unit/data/52 proves the NOT NULL mapping against
# the string a driver would emit, and that mapping is correct. It does not
# prove the string can arrive, and today it cannot. The branch is kept as a
# safety net for a store altered outside lazysite or a future backend - but it
# is DEAD CODE on every path this engine offers, and its test should not be
# read as coverage of a live one. That distinction is the whole of SM732.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");

# Keyed on `code`, NOT `id` - so auto_key is false and `code` carries NOT NULL.
# `code` is deliberately NOT marked required: that is the whole point. A
# required key would be caught by the value layer and never reach the database.
open my $fh, '>', "$docroot/lazysite/db/tables/parts.yaml" or die $!;
print {$fh} <<'YAML';
title: Parts
key: code
fields:
  code:
    type: text
    max: 20
  label:
    type: text
YAML
close $fh;

my $applied = apply_schema( $docroot, 'parts' );
plan skip_all => 'cannot apply schema here: ' . ( $applied->{error} // '?' )
    unless $applied->{ok};

subtest 'a row missing its non-auto key is refused BEFORE the constraint'
    => sub {
    my $r = insert_row( $docroot, 'parts', { label => 'no key given' } );

    ok( !$r->{ok}, 'the insert is refused' ) or return;

    # AND IT IS THE VALUE LAYER THAT ANSWERS, not the constraint. Value.pm has
    # a dedicated key check whose sentence is better than the translator's -
    # it says WHY the key is needed rather than only that it is missing - and
    # it runs before any SQL.
    like( $r->{error}, qr/identifies the row and is required/,
        'the key check answers, and explains why the key is needed' )
        or diag("got: $r->{error}");

    unlike( $r->{error}, qr/NOT NULL|constraint|SQLite|DBD/i,
        'with no trace of the driver' );

    is( $r->{field}, 'code', 'the column comes back as data either way' );
    is( $r->{rule},  'key',  'and the rule names which check refused it' );
    };

subtest 'the ordinary insert still works, so the table is real' => sub {
    # Without this the subtest above could pass on a table that rejects
    # everything, which would prove nothing about the constraint.
    my $ok = insert_row( $docroot, 'parts',
        { code => 'AA1', label => 'a part' } );
    ok( $ok->{ok}, 'a complete row inserts' )
        or diag( $ok->{error} // 'no error' );
};

done_testing();

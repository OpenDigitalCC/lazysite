#!/usr/bin/perl
# N141E (SM852's remaining MISS row, verified): a submissions store that lives
# in a PROTECTED folder is still found, read and rewritten.
#
# SM852 listed this as a MISS - "Plugins::_rewrite_store (finds no store once
# its folder is gated - fixed by S1, since it reads through store_path; to
# verify)". A MISS is the harmless direction of the SM852 shape: it can fail to
# find the private copy, never create a public one. But "harmless" here means an
# operator is told "No such submissions store" about a store that is there, and
# the rows they came to delete cannot be deleted.
#
# THIS IS THE VERIFICATION THE ROW ASKED FOR, and it is a behavioural one. The
# structural argument was already sound - _submissions_path builds its absolute
# path through Handlers::store_path, and store_path sends a non-`lazysite/` path
# through resolve_for_write - but "reads through the right function" is not the
# same claim as "finds the file", and the row said `to verify` for that reason.
#
# WHERE IT ACTUALLY BITES, which the structural reading does not show: the
# DEFAULT store is `lazysite/forms/submissions`, and store_path resolves
# anything under `lazysite/` into the engine tree, which is never gated. So this
# can only matter for a store a sysop has configured into a CONTENT folder -
# a handler with its own `path:` - and that folder then being protected. That is
# the fixture below; a test using the default path would have proved nothing and
# passed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Private;
use Lazysite::Manager::Plugins;
use Lazysite::Handlers;

sub w {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
}

my $d    = site_tempdir();
my $priv = Lazysite::Private::private_root($d);
make_path("$d/lazysite/forms");

# A file handler whose store is a CONTENT folder, not the default under
# lazysite/ - which is the only arrangement this row can affect.
w( "$d/lazysite/forms/handlers.conf",
        "handlers:\n"
      . "  - id: jsonl\n    type: file\n    name: Local\n"
      . "    enabled: true\n    path: client-data\n" );

# The store is GATED: its rows are in the private store, and there is no public
# copy at all.
make_path("$priv/client-data");
# NO `_id` FIELD in the fixture, and the reason is worth recording. The response
# sets `_id` from a hash of the raw line so a row can be deleted by it, and then
# maps the row's own columns over the top - so a stored row that happens to
# carry an `_id` SHADOWS the derived one and cannot be deleted by the id the UI
# was given. A client cannot send it (%PROTOCOL_KEY limits underscore keys), but
# a connector or an import can. Noticed here because my first fixture did
# exactly that and the delete answered "A row id is required". Narrow, real, and
# not this row's business - recorded rather than fixed in passing.
w( "$priv/client-data/contact.jsonl",
        qq({"name":"Ada","message":"first"}\n)
      . qq({"name":"Bob","message":"second"}\n) );

no warnings 'once';
$Lazysite::Manager::Plugins::DOCROOT = $d;
$Lazysite::Handlers::DOCROOT         = $d;
use warnings 'once';

ok( !-e "$d/client-data/contact.jsonl",
    'the store has no public copy - it is genuinely gated' );
ok( -f "$priv/client-data/contact.jsonl", 'and a real one in the private store' );

# --- the store is FOUND ------------------------------------------------------
my $r = Lazysite::Manager::Plugins::action_form_submissions('client-data/contact.jsonl');
ok( $r->{ok}, 'a gated submissions store is found and read' )
    or diag( 'The MISS row: "finds no store once its folder is gated". If this '
        . 'answers "No such submissions store" then S1 did not reach this '
        . "path after all.\n  error: " . ( $r->{error} // '-' ) );

is( scalar @{ $r->{rows} || $r->{submissions} || [] }, 2,
    'and both rows come back' )
    or diag explain $r;

# --- and a DELETE rewrites the private copy, not a new public one ------------
#
# This is the half _rewrite_store owns: it renames a temp file over the absolute
# path it was handed. If that path were the public one, the delete would write a
# partial copy of protected rows into the served tree - which would turn a MISS
# into the exposure shape SM852 is actually about.
my $rows = $r->{rows} || $r->{submissions} || [];
my $id = ref $rows->[0] eq 'HASH' ? ( $rows->[0]{_id} // $rows->[0]{id} ) : undef;

SKIP: {
    skip 'the row shape carries no id to delete by', 3 unless defined $id;

    my $del = Lazysite::Manager::Plugins::action_form_submission_delete(
        'client-data/contact.jsonl', $id );
    ok( $del->{ok}, 'a row in a gated store can be deleted' )
        or diag( 'error: ' . ( $del->{error} // '-' ) );

    ok( !-e "$d/client-data/contact.jsonl",
        'and NO public copy of the store is created by the rewrite' )
        or diag( 'This would be the MISS turning into the exposure: a rewrite '
            . 'that writes protected rows into the served tree.' );

    open my $fh, '<', "$priv/client-data/contact.jsonl" or die $!;
    my @left = <$fh>;
    close $fh;
    is( scalar @left, 1, 'the private copy is the one that was rewritten' );
}

done_testing();

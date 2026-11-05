#!/usr/bin/perl
# SM1347 (ruling 103), the browser half: starter/assets/lazysite-odoo.js draws, as
# text, each change an applied answer says Odoo did not keep (`not_kept`, `note`)
# into the page's [data-ls-odoo-not-kept] - for a write(), a confirm() and a resume
# settled from the unknown slot - and says `kept` when there is none. A page without
# the slot is answered as before. Run under node with a stand-in DOM
# (t/lib/odoo-not-kept-harness.js).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
my ($node) = grep { -x } map { "$_/node" } split /:/, ( $ENV{PATH} // '' );
plan skip_all => 'node is not installed' unless $node;

my $r = run_child( [ $node, "$root/t/lib/odoo-not-kept-harness.js", $asset ], stderr => 'merge' );
my $f = eval { decode_json( $r->{out} ) };
ok( $f && !$f->{error}, 'the harness ran' ) or BAIL_OUT( 'harness: ' . $r->{out} );

my $NOTE = 'Odoo did not keep this change as asked: name';
is( $f->{write}{state}, 'not-kept', 'a write Odoo did not keep is drawn as not-kept' );
is( $f->{write}{text},  $NOTE,      'with the server\'s sentence' );
is( $f->{write}{lines}, 1,          'one line, for the one change not kept' );
is( $f->{write}{api},   1,          'notKept() returns the changes not kept' );
is( $f->{confirm}{text}, $NOTE, 'a confirm draws the same' );
is( $f->{kept}{state}, 'kept', 'a write Odoo kept is drawn as kept' );
is( $f->{kept}{lines}, 0,      'with nothing in it' );
like( $f->{resume}{unknown}, qr/Done\..*\Q$NOTE\E/, 'a settled resume says what its carried changes left not kept' );
is( $f->{resume}{state}, 'settled', 'and is settled' );
is( $f->{resume}{notKept}, $NOTE, 'and draws it into the not-kept slot too' );
is( $f->{markup}{tags}, 0, 'a note that is markup makes no element' );
like( $f->{markup}{text}, qr/<img src=x/, 'and is shown as its characters' );
is( $f->{no_slot}{status}, 200,   'a page with no slot is answered as before' );
is( $f->{no_slot}{note},   $NOTE, 'with the note in the answer' );
is( $f->{no_slot}{drawn},  0,     'and nothing drawn' );

done_testing;

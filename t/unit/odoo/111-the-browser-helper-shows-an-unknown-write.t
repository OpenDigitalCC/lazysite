#!/usr/bin/perl
# SM1277 (rulings 10a, 10b), the browser half: extensions/odoo/assets/lazysite-odoo.js shows a
# person what their write left unknown - its request was sent and no answer came -
# with "Check again", and "It was made" / "It was not made" only where the answer
# says they may say (`may_assume`). resume() sends {run, resume: true} with the
# token and the assume lists. A write() or confirm() whose answer names a run left
# unknown is drawn into the page's [data-ls-odoo-unknown], as text; each button
# resumes the run and draws the next answer in its place. Run under node with a
# stand-in DOM (t/lib/odoo-unknown-harness.js).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);

my $root  = repo_root();
my $asset = "$root/extensions/odoo/assets/lazysite-odoo.js";
my ($node) = grep { -x } map { "$_/node" } split /:/, ( $ENV{PATH} // '' );
plan skip_all => 'node is not installed' unless $node;

my $r = run_child( [ $node, "$root/t/lib/odoo-unknown-harness.js", $asset ], stderr => 'merge' );
my $f = eval { decode_json( $r->{out} ) };
ok( $f && !$f->{error}, 'the harness ran' ) or BAIL_OUT( 'harness: ' . $r->{out} );

my $RUN = 'a' x 32;
is_deeply( $f->{resume}, [
        { run => $RUN, resume => JSON::PP::true, visitor_token => 'VT' },
        { run => $RUN, resume => JSON::PP::true, assume_done => ['line:1'], visitor_token => 'VT' },
        { run => $RUN, resume => JSON::PP::true, assume_not_done => [ 'line:1', 'line:2' ], visitor_token => 'VT' },
    ], 'resume() sends the run, the token and the assume lists' );

is( $f->{drawn}{state}, 'unknown', 'a write left unknown is drawn into the page' );
like( $f->{drawn}{text}, qr/not known whether Odoo made this change/, 'saying it is not known' );
like( $f->{drawn}{text}, qr/line:1 create x\.basket/, 'naming the change' );
unlike( $f->{drawn}{text}, qr/rename:1/, 'and only the unknown one' );
is_deeply( $f->{drawn}{buttons}, [ 'It was made', 'It was not made', 'Check again' ], 'its maker is offered the choices' );

is_deeply( $f->{not_mine}{buttons}, ['Check again'], 'one who may not say is offered Check again alone' );
is_deeply( $f->{not_mine}{sent}, { run => $RUN, resume => JSON::PP::true, visitor_token => 'VT' }, 'which sends no assume list' );
is( $f->{not_mine}{after}{state}, 'unknown', 'a refusal unknown-outcome is drawn again' );
is_deeply( $f->{not_mine}{after}{buttons}, ['Check again'], 'with no choices still' );

is_deeply( $f->{made}{sent}{assume_done}, ['line:1'], 'It was made sends assume_done for that change' );
is( $f->{made}{state}, 'settled', 'and a settled answer is drawn as settled' );

is_deeply( $f->{again}{first}{assume_not_done}, ['line:1'], 'It was not made sends assume_not_done' );
is( $f->{again}{second}{run}, 'c' x 32, 'and a new run left unknown is the one checked next' );

is( $f->{markup}{tags}, 0, 'a key that is markup makes no element' );
like( $f->{markup}{text}, qr/<img src=x/, 'and is shown as its characters' );

is( $f->{no_slot}{status}, 207,  'a page with no slot is answered as before' );
is( $f->{no_slot}{run},    $RUN, 'with the run in the answer' );
is( $f->{no_slot}{drawn},  0,    'and nothing drawn' );

done_testing;

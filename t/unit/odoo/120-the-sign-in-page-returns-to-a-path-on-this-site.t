#!/usr/bin/perl
# SM1299 (ruled 2026-10-23, #37): /odoo-signin FOLLOWS ?next= ONCE THE PERSON IS
# SIGNED IN, SAME-SITE ONLY.
#
# The page's button (data-ls-odoo-next, the ::: odoo-signin component) sends the
# page's own ?next= with the sign-in; the endpoint answers the path to go to
# through Lazysite::Util::sanitise_next, the check /login's return uses
# (t/unit/odoo/63 holds the endpoint's answers, open-redirect cases included);
# the script goes to that answer and never to what it read itself. Driven under
# node by t/lib/odoo-next-harness.js. Before, the page stayed where it was.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $r = run_child( [ $node, "$root/t/lib/odoo-next-harness.js", "$root/extensions/odoo/assets/lazysite-odoo.js" ],
    stderr => 'merge' );
my $f = eval { decode_json( $r->{out} ) };
ok( $f && !$f->{error}, 'the harness ran' ) or BAIL_OUT( "harness: " . ( $r->{out} // '' ) );

is( $f->{same}{sent}, '/wholesale', 'the page\'s ?next= is sent with the sign-in, decoded' );
is_deeply( $f->{same}{went}, ['/wholesale'], 'and a path on this site is where it goes' );
is( $f->{host}{sent}, '//evil.example/', 'another host is sent as it was written' );
is_deeply( $f->{host}{went}, ['/'], '...and the page goes to /' );
is( $f->{scheme}{sent}, 'https://evil.example', 'a scheme, found among other parameters' );
is_deeply( $f->{scheme}{went}, ['/'], '...goes to /' );
is( $f->{none}{sent}, '', 'no ?next= sends an empty one' );
is_deeply( $f->{none}{went}, ['/'], '...and the page goes to /' );
is( $f->{plus}{sent}, '/a b', 'a + in the query is a space, as a browser writes it' );
is_deeply( $f->{follows_answer}{went}, ['/'], 'the script goes where the endpoint says, not where it read' );
is_deeply( $f->{no_answer}{went}, [], 'an endpoint that answers no next leaves the page where it is' );
ok( !$f->{unmarked}{has_next}, 'a sign-in button without data-ls-odoo-next sends no next' );
is_deeply( $f->{unmarked}{went}, [], '...and goes nowhere, as before' );
is_deeply( $f->{two_factor}{after_password}, [], 'two-factor: the password step goes nowhere' );
is( $f->{two_factor}{code_next}, '/wholesale', '...the code step carries next' );
is_deeply( $f->{two_factor}{went}, ['/wholesale'], '...and the page goes once it signs in' );

done_testing;

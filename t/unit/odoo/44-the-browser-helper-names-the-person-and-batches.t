#!/usr/bin/perl
# SM1145 and SM1146, the browser half (t/unit/odoo/31 holds the rest of the
# helper): the page fills `data-ls-odoo-name` from the token fetch it makes at
# load, so who is signed in costs no Odoo call, and `batch` sends several calls
# as one request and sends again only the calls that need it, once.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
my $node  = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $out = `$node "$root/t/lib/odoo-helper-harness.js" "$asset" 2>&1`;
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the behaviour harness ran' ) or BAIL_OUT("harness: $out");

subtest 'the name is filled from the token fetch, as text, and only where there is a place for it' => sub {
    is( $f->{name}{text}, '<b>Jane</b>', 'the display name, as text (the characters, not markup)' );
    is_deeply( $f->{name}{requests}, ['GET /cgi-bin/lazysite-odoo.pl?csrf=1'],
        'one request, at load, and it is the token fetch every page makes anyway' );
    is_deeply( $f->{name}{who}, { name => '<b>Jane</b>' }, 'who() says the name' );
    is( $f->{name_nobody}{text}, 'Guest', 'nobody signed in: the node is left as the page wrote it' );
    is( $f->{name_no_node}{requests}, 0, 'a page with no name node asks for nothing' );
};

subtest 'a batch is one POST, and sends again only the calls that need it, once' => sub {
    is( $f->{batch}{status}, 200, 'answered' );
    is_deeply( $f->{batch}{order}, [qw(a stale c)], 'the answers are in the order the calls were sent' );
    is_deeply( $f->{batch}{statuses}, [ 200, 200, 200 ], 'a call refused for a stale token recovered' );
    is_deeply( $f->{batch}{posts}, [ [qw(a stale c)], ['stale'] ], 'one POST of all three, then one of the stale call alone' );
    is_deeply( $f->{batch}{tokens}, [ 'T1', 'T2' ], 'the second carries the fresh token' );
    is_deeply( $f->{batch}{first_params}, { x => 1 }, 'a call\'s params go as given' );
    is( $f->{batch_csrf_twice}{posts},  2,   'refused twice: two POSTs and no more' );
    is( $f->{batch_csrf_twice}{status}, 403, 'and the refusal is the answer' );

    is( $f->{batch_signin}{asked}, 1, 'the person is asked once for a whole batch of sign-ins' );
    is( $f->{batch_signin}{posts}, 2, 'two POSTs' );
    is_deeply( $f->{batch_signin}{second}, [ 'mine', 'mine' ], 'the second carries the two calls that needed it, not the whole batch' );
    is( $f->{batch_prompt_why}, 'sign in', 'with the server\'s words' );
    is_deeply( $f->{batch_signin}{statuses}, [ 401, 200, 401 ], 'a second refusal is the answer, never looped on' );

    is( $f->{batch_refused}{status}, 400, 'a refused batch (too many) is returned as it came' );
    is( $f->{batch_refused}{posts},  1,   'and not sent again' );
};

done_testing;

#!/usr/bin/perl
# SM1162, the browser half: starter/assets/lazysite-odoo.js sends a binding call
# whose params hold a File, a Blob or a list of them as multipart/form-data - the
# JSON body as the part named json (the token with it), each file a part named for
# its field, the binding in the query so the server knows its cap before it reads -
# and every call without a file goes exactly as it did (a JSON POST). The retry
# rules are the JSON path's: one fresh-token retry, one sign-in retry, each with a
# FormData built afresh. A batch carries no files.
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

my $out = `$node "$root/t/lib/odoo-file-harness.js" "$asset" 2>&1`;
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the file harness ran' ) or BAIL_OUT("harness: $out");

subtest 'a File among the params goes as multipart/form-data' => sub {
    is( $f->{upload}{status}, 200, 'answered' );
    is( $f->{upload}{n_posts}, 1, 'one POST' );
    is( $f->{upload}{url}, '/cgi-bin/lazysite-odoo.pl?binding=expense', 'the binding is in the query, for the size cap' );
    is( $f->{upload}{kind}, 'form', 'the body is a FormData' );
    ok( $f->{upload}{content_type}, 'no Content-Type is set by the helper: the browser writes it with the boundary' );
    is_deeply( $f->{upload}{json}, { binding => 'expense', params => { note => 'lunch' }, visitor_token => 'VT1' },
        'the json part holds the binding, the plain params and the token - and no file' );
    ok( !$f->{upload}{json_has_filename}, 'the json part is text, not a file' );
    is_deeply( $f->{upload}{files}, [ [ 'photo', 'file', 13 ], [ 'shots', 'file', 1 ], [ 'shots', 'file', 2 ] ],
        'a part per file, named for the field (a list repeats the name), with a file name' );
    is( $f->{upload_photo_type}, 'image/jpeg', 'a File keeps the type it has' );
    ok( !$f->{upload_in_json}, 'the bytes are in no JSON' );
    is( $f->{named}, 'receipt.jpg', 'a File keeps its own name' );
};

subtest 'a call with no file is the JSON POST it always was' => sub {
    is_deeply( $f->{json_path}, { url => '/cgi-bin/lazysite-odoo.pl', kind => 'json', ct => 'application/json',
            params => { product => 1 }, token => 'T' }, 'unchanged' );
    is( $f->{empty_list}, 'json', 'an empty list is not a file' );
};

subtest 'the retries are the JSON path\'s: one, with a fresh body' => sub {
    is( $f->{csrf_retry}{status}, 200, 'a stale token recovers' );
    is_deeply( $f->{csrf_retry}{tokens}, [ 'T1', 'T2' ], 'the second POST carries the fresh token' );
    is_deeply( $f->{csrf_retry}{file_both_times}, [ 'abc', 'abc' ], 'and the whole file again' );
    is( $f->{csrf_twice}{posts}, 2, 'stale twice: two POSTs and no more' );
    is( $f->{csrf_twice}{status}, 403, 'the refusal is the answer' );
    is( $f->{signin}{asked}, 1, 'sign-in required: asked once' );
    is( $f->{signin}{posts}, 2, 'and the call sent once more' );
    is( $f->{signin}{file_second}, 'abc', 'with its file' );
};

subtest 'a batch carries no files' => sub {
    like( $f->{batch}{err}, qr/a batch carries no files/, 'refused by name' );
    is( $f->{batch}{sent}, 0, 'before anything is sent' );
};

done_testing;

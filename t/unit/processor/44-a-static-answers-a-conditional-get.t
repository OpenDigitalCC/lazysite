#!/usr/bin/perl
# SM388: an engine-served static carries a validator and answers 304.
#
# SM387 settled that these must revalidate: a static served by the engine is
# public NOW and can be protected at any moment, so a long cache would outlive
# the protection in a visitor's browser. That is right, and it has a cost -
# which without a validator is a FULL RE-DOWNLOAD on every navigation. The
# expensive way to be correct.
#
# AND THE FRONT DOOR CLAIMED THIS ALREADY WORKED. lazysite-front.pl justified
# not reimplementing the static path on the grounds that the engine "already
# gets right" byte ranges, conditional GETs and content types. Two of the three
# did not exist anywhere. A justification resting on a capability that is not
# there is worse than none, because it stops the next reader looking.
#
# BYTE RANGES ARE STILL ABSENT, deliberately unfixed here and recorded rather
# than denied - media seeking fails wherever the engine answers a static.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# SM223: the engine serves statics only when the site has an ACL store.
make_path("$docroot/lazysite/auth");
open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$acl} "{}\n";
close $acl;

make_path("$docroot/lazysite-assets/probe");
my $asset = "$docroot/lazysite-assets/probe/site.css";
open my $css, '>', $asset or die $!;
print {$css} "body{color:red}\n";
close $css;

my $URI = '/lazysite-assets/probe/site.css';

my $first = run_processor( $docroot, $URI );
my ($etag) = $first =~ /^ETag:\s*(\S+)/mi;

subtest 'the fixture served the stylesheet, not a 404' => sub {
    like( $first, qr{^Content-type: text/css}mi, 'the engine served it' )
        or diag($first);
};

subtest 'a validator is offered' => sub {
    ok( $etag, 'an ETag is emitted' )
        or diag( 'Without one the client has nothing to revalidate WITH, so '
            . 'must-revalidate costs a full re-download every time.' );
    like( $etag // '', qr{^W/"},
        'weak, because mtime and size cannot assert byte-identity' )
        or diag( 'A strong validator would claim more than stat() supports: '
            . 'two writes inside one second break that claim.' );
};

subtest 'and a matching conditional GET is answered 304, with no body' => sub {
    plan skip_all => 'no ETag to revalidate with' unless $etag;

    local $ENV{HTTP_IF_NONE_MATCH} = $etag;
    my $second = run_processor( $docroot, $URI );

    like( $second, qr/^Status:\s*304/mi, '304 Not Modified' );
    my ($body) = $second =~ /\n\r?\n(.*)\z/s;
    is( length( $body // '' ), 0, 'and no body at all' )
        or diag( 'A 304 that still sends the bytes has saved nothing, which is '
            . 'the whole point of the exercise.' );
    like( $second, qr/^X-Content-Type-Options: nosniff/mi,
        'the 304 still carries the security header set' )
        or diag( 'A 304 is a response like any other - SM381 is about exactly '
            . 'this class of path answering without the headers.' );
};

subtest 'a stale validator gets the file' => sub {
    plan skip_all => 'no ETag to revalidate with' unless $etag;

    local $ENV{HTTP_IF_NONE_MATCH} = 'W/"deadbeef-1"';
    my $third = run_processor( $docroot, $URI );
    like( $third, qr/^Status:\s*200/mi,  '200, not 304' );
    like( $third, qr/body\{color:red\}/, 'and the content is sent' )
        or diag( 'Answering 304 to a validator that does not match would serve '
            . 'the visitor a file they do not have.' );
};

done_testing();

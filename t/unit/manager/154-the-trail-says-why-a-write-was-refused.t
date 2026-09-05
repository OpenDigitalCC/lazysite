#!/usr/bin/perl
# SM750: a refused write leaves a trail a reader can act on.
#
# A partner agent read the audit page to learn why its writes failed and found
# `raw-content-refused`, `invalid arguments`, `Invalid path` - each a verdict,
# none a cause, so it fetched the page over WebDAV and recognised the shape by
# hand. The refusal's SENTENCE had the cause and the remedy all along; the
# trail recorded the class. This file drives three refusals through the real
# manager API and reads the audit log back:
#   - raw HTML page: the trail names the front-matter key and the content type
#   - a blocked path: the trail names the path and the tree it is in
#   - a traversal path: the trail names the path and the `..` segment
# and asserts the caller's own answer carries kind + audit_detail too.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . q{/lazysite-manager-api.pl};

my @ALL = qw(ui manage_content manage_config);
my $s   = new_site( root => repo_root() );
$s->add_user('writer');
$s->grant( 'writer', 'writers', [ 'ui', 'manage_content' ], \@ALL );
my $d = $s->docroot;

sub audit_tail {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return '';
    my @l = <$fh>;
    close $fh;
    return $l[-1] // '';
}

subtest 'a raw HTML page: the trail names the key and the type' => sub {
    my $r = $s->call( 'writer', 'save',
        query => 'action=save&path=' . 'raw-probe.md',
        body => { content => "---\ntitle: x\napi: true\ncontent_type: text/html\n---\n<html><body>hi</body></html>\n" } );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'raw-content-refused', 'the class is still the kind' );
    like( $r->{audit_detail}, qr/^raw-content-refused: front matter has api: true with content_type text\/html - /,
        'the caller sees the detail line too' );

    my $row = audit_tail();
    like( $row, qr/\| fail \|/, 'the trail has the failure' );
    like( $row, qr/raw-content-refused: front matter has api: true with content_type text\/html/,
        'and it says WHICH key and WHICH type, not the class alone' );
    like( $row, qr/ - publish a self-contained HTML file as a static \.html/,
        'and what to do instead' );
    unlike( $row, qr/\| raw-content-refused\s*$/, 'the bare verdict is gone' );
};

subtest 'a blocked path: the trail names the path and the tree' => sub {
    my $r = $s->call( 'writer', 'save',
        query => 'action=save&path=lazysite/auth/probe.txt',
        body  => { content => "x\n" } );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'blocked', 'kind: blocked' );
    like( $r->{error}, qr/'lazysite\/auth\/probe\.txt' is inside the reserved lazysite\/ tree/,
        'the error names the path and the rule - it used to say "Path is blocked"' );
    like( audit_tail(), qr/blocked: 'lazysite\/auth\/probe\.txt' is inside the reserved lazysite\/ tree/,
        'and so does the trail' );
};

subtest 'a traversal path: the trail names the path and the segment' => sub {
    my $r = $s->call( 'writer', 'save',
        query => 'action=save&path=pages/../lazysite/x.md',
        body  => { content => "x\n" } );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'invalid-path', 'kind: invalid-path' );
    like( $r->{error}, qr/contains a '\.\.' segment/, 'the error names the segment' );
    like( audit_tail(), qr/invalid-path: '[^']*\.\.[^']*' contains a \.\. segment - send a docroot-relative forward path/,
        'the trail echoes the path and says what a valid one looks like' );
};

done_testing();

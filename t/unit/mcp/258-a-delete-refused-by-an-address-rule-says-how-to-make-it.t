#!/usr/bin/perl
# SM1424 (n804): A DELETE THE ADDRESS RULE REFUSES SAYS WHY AND WHAT TO DO.
#
# delete_page on a page in a folder whose rule names an address profile, from an
# address outside it, answered ok:false with "This page is not available from
# your address." - the read sentence, which does not say a change is what the
# rule limits. It now says the rule limits changes to its allowed addresses and
# that the change is made from an allowed address, naming no address and no
# profile; kind stays `address` and retryable false. The same page, read, keeps
# the read sentence; from an allowed address the delete goes through.
#
# With the change reverted the write sentence assertion fails.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $root = "$FindBin::Bin/../../..";
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/addr" );
sub put { my ( $rel, $text ) = @_; open my $f, '>', "$d/$rel" or die "$rel: $!"; print {$f} $text; close $f }
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'lazysite/auth/users',    "agent:x\n" );
put( 'index.md',               "---\ntitle: Home\n---\nhi\n" );
put( 'addr/p.md',              "---\ntitle: P\n---\nhi\n" );
put( 'lazysite/auth/address-profiles.json',
    encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => 'HQ' } ] } } ) );
put( 'lazysite/auth/acls.json', encode_json( { 'addr/' => { owner => 'agent', addresses => ['office'] } } ) );
put( 'users-stub.pl',
    "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\nprint encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });\n" );
chmod 0755, "$d/users-stub.pl";

sub call {
    my ( $tool, $args, $addr ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = "$d/users-stub.pl";
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    $ENV{REMOTE_ADDR}         = $addr;
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json($jb) } || {};
    return $r->{result} ? $r->{result}{structuredContent} : $r;
}

my $WRITE = 'The access rule on this path limits changes to its allowed addresses; make the change from an allowed address.';

my $no = call( 'delete_page', { slug => 'addr/p' }, '192.0.2.77' );
ok( !$no->{ok}, 'a delete from outside the rule is refused' ) or diag explain $no;
is( $no->{kind},      'address', 'as an address refusal' );
is( $no->{error},     $WRITE,    'saying the rule limits changes and where to make them from' );
is( $no->{retryable}, JSON::PP::false, 'not retryable' );
unlike( $no->{error}, qr/192\.0\.2\.77|203\.0\.113|office/, 'naming no address and no profile' );
ok( -f "$d/addr/p.md", 'and the page is still there' );

my $rd = call( 'read_file', { path => '/addr/p.md' }, '192.0.2.77' );
is( $rd->{error}, 'This page is not available from your address.', 'a read keeps the read sentence' );

my $yes = call( 'delete_page', { slug => 'addr/p' }, '203.0.113.5' );
ok( $yes->{ok}, 'from an allowed address the delete goes through' ) or diag explain $yes;
ok( !-f "$d/addr/p.md", 'and the page is gone' );

done_testing;

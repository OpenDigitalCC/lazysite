#!/usr/bin/perl
# GS11 (SM492): an opening ::: fence that is never closed is reported by
# validate_page, at the file line, naming the fence.
#
# The processor's behaviour on an unbalanced fence is "leave as-is" - the
# three colons and the name land on the page as literal text, and the WARN it
# logs goes to stderr, which an author working over MCP never sees. The
# estate survey found the same hero built twice by hand; the step before
# that is an author who tried the fence, saw ':::hero' on the page, and
# concluded the mechanism did not work.
#
# A page that DOCUMENTS fences inside ``` blocks must not trip the check.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nmcp_enabled: true\n";
close $c;
my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
    . "print encode_json({ ok => 1, settings => { manage_content => 1, mcp => 1 } });\n";
close $sf;
chmod 0755, $stub;

sub validate {
    my ($content) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'validate_page', arguments => { content => $content } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;     $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body; $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION} = 'Bearer tester:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body; close $in;
    my $resp = do { local $/; <$out> }; close $out; waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d    = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}
sub kind { my ( $r, $k ) = @_; grep { $_->{kind} eq $k } @{ $r->{warnings} || [] } }

my $fm = "---\ntitle: Fences\nsubtitle: s\n---\n";    # 2 lines + 2 fences = offset 4

subtest 'AN UNCLOSED FENCE IS NAMED, AT ITS LINE' => sub {
    my $r = validate( $fm . "Intro.\n\n::: hero eyebrow=\"x\"\n# Big\n\nstill open\n" );
    my @w = kind( $r, 'component-fence-unmatched' );
    is( scalar @w,    1,      'one unmatched-fence warning' ) or diag explain $r;
    is( $w[0]{fence}, 'hero', 'names the fence' );
    is( $w[0]{line}, 7, 'line counted from the top of the file (fm 2 + fences 2 + body 3)' );
};

subtest 'a balanced page, nested, is clean' => sub {
    my $r = validate( $fm . "::: hero\n# Big\n\n::: actions\n[Go](/)\n:::\n:::\n" );
    is( scalar kind( $r, 'component-fence-unmatched' ), 0, 'nested and closed: nothing' );
    is( scalar kind( $r, 'fence-close-unmatched' ),     0, 'and no stray-close warning' );
};

subtest 'one missing close in a nest reports the OUTER fence' => sub {
    my $r = validate( $fm . "::: hero\n# Big\n\n::: actions\n[Go](/)\n:::\n" );
    my @w = kind( $r, 'component-fence-unmatched' );
    is( scalar @w,    1,      'one warning' );
    is( $w[0]{fence}, 'hero', 'the inner pair closed; the outer is what is open' )
        or diag( 'Reported ' . ( $w[0]{fence} // 'nothing' ) );
};

subtest 'a stray closing fence is reported too' => sub {
    my $r = validate( $fm . "Text.\n:::\nMore.\n" );
    my @w = kind( $r, 'fence-close-unmatched' );
    is( scalar @w,   1, 'one stray-close warning' );
    is( $w[0]{line}, 6, 'at its line' );
};

subtest 'A PAGE THAT DOCUMENTS FENCES IN A CODE BLOCK IS NOT A BROKEN PAGE' => sub {
    my $r = validate( $fm . "Use it like this:\n\n```\n::: hero\n# Big\n```\n\nDone.\n" );
    is( scalar kind( $r, 'component-fence-unmatched' ), 0,
        'an unclosed fence INSIDE ``` is an example, not a defect' )
        or diag('The check that makes fences safe must not fire on the page that explains them.');
};

done_testing();

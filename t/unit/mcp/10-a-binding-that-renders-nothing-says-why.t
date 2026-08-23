#!/usr/bin/perl
# SM481: a `db:` binding that will render nothing says so where the author is
# looking.
#
# WHAT THIS COST. A site agent spent an afternoon on a page rendering zero rows
# while the API returned three from the same table at the same moment. That
# pair of symptoms is what a permissions fault looks like, and what a
# WAL/writability fault looks like, and what SM476's publication gate looks
# like - and nothing in the empty result said which.
#
# The engine DOES log the reason. It logs it to STDERR, which on a real install
# is the web server's error log, which an agent working over MCP cannot read.
# A diagnostic the person who needs it cannot reach is not a diagnostic.
#
# So it is answered in validate_page, statically: the descriptor already knows
# whether a visitor would see anything, without rendering the page.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use IPC::Open2 qw(open2);
use TestHelper qw(repo_root);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nmcp_enabled: true\nplugins:\n  - plugins/data.pl\n";
close $c;

sub declare {
    my ( $name, $public ) = @_;
    open my $f, '>', "$docroot/lazysite/db/tables/$name.yaml" or die $!;
    print {$f} ( $public ? "public: true\n" : '' )
        . "key: code\nfields:\n  code:\n    type: text\n";
    close $f;
    apply_schema( $docroot, $name );
}
declare( 'shown',  1 );
declare( 'hidden', 0 );

# validate_page over the MCP surface. The harness is the one t/unit/mcp/09
# uses - a POST body over open2 with a users stub for capabilities - because a
# hand-rolled invocation just returns 404 and reports nothing about the tool.
my $mcp  = "$root/lazysite-mcp.pl";
my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
print encode_json({ ok => 1,
    settings => { manage_content => 1, manage_data => 1, mcp => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub validate {
    my ($content) = @_;
    my $body = encode_json(
        {   jsonrpc => '2.0', id => 1, method => 'tools/call',
            params  => { name => 'validate_page',
                arguments => { content => $content } },
        }
    );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $docroot;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer tester:lzs_tok';

    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;

    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    my $text = $d->{result}{content}[0]{text} // '';
    return eval { decode_json($text) } || {};
}

sub kinds {
    my ($r) = @_;
    return map { $_->{kind} }
        ( @{ $r->{issues} || [] }, @{ $r->{warnings} || [] } );
}

subtest 'AN UNPUBLISHED TABLE IS THE HEADLINE' => sub {
    my $r = validate(
        "---\ntitle: T\ntt_page_var:\n  rows: db:hidden\n---\n\nHello.\n" );
    my @k = kinds($r);
    ok( ( grep { $_ eq 'db-table-not-published' } @k ),
        'the binding is reported' )
        or diag( 'Reply: ' . encode_json($r) );

    my ($issue) = grep { $_->{kind} eq 'db-table-not-published' }
        @{ $r->{issues} || [] };
    like( $issue->{message}, qr/\bhidden\b/, 'naming the table' );
    like( $issue->{message}, qr/public:\s*true/, 'and the fix' )
        or diag( 'An author told only "it renders nothing" has learnt what '
            . 'they already knew.' );

    # THE SENTENCE THAT WOULD HAVE SAVED THE AFTERNOON: the page looks broken
    # and the data looks fine, which is why the two readings disagreed.
    like( $issue->{message}, qr/API and the manager still read it/,
        'and explains why the API disagrees with the page' );
};

subtest 'a published table is not reported' => sub {
    my $r = validate(
        "---\ntitle: T\ntt_page_var:\n  rows: db:shown\n---\n\nHello.\n" );
    my @k = kinds($r);
    ok( !( grep { /^db-table/ } @k ), 'nothing is said about a working binding' )
        or diag( 'A check that fires on correct pages trains an author to '
            . 'skim past it, and this one has to be read the day it matters.' );
};

subtest 'a table that does not exist is reported differently' => sub {
    my $r = validate(
        "---\ntitle: T\ntt_page_var:\n  rows: db:nosuch\n---\n\nHello.\n" );
    ok( ( grep { $_ eq 'db-table-missing' } kinds($r) ),
        'a missing table is its own kind' )
        or diag( 'Not-declared and not-published need different remedies, so '
            . 'they cannot share one message.' );
};

subtest 'a page with no binding is untouched' => sub {
    my $r = validate("---\ntitle: T\n---\n\nJust words.\n");
    ok( !( grep { /^db-/ } kinds($r) ), 'no db issues' );
    ok( $r->{ok} || exists $r->{issues}, 'and validation still answered' );
};

subtest 'the full binding grammar is recognised, not just a bare table' => sub {
    # DP-2 bindings carry modifiers and scalars. A checker that only matched
    # `db:name` alone would fall silent on exactly the pages that do most work.
    for my $spec ( 'db:hidden(order=code,limit=5)', 'db:hidden.count()',
        'db:hidden sort=code asc' )
    {
        my $r = validate(
            "---\ntitle: T\ntt_page_var:\n  rows: $spec\n---\n\nHi.\n" );
        ok( ( grep { $_ eq 'db-table-not-published' } kinds($r) ),
            "recognised in '$spec'" );
    }
};

done_testing();

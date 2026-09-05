#!/usr/bin/perl
# SM714: tools/list over the bearer path returned whoami and describe_capabilities
# and nothing else, with no nextCursor, and a partner concluded the MCP surface
# was nearly empty. The listing is filtered to what the presenting credential may
# call (SM196/SM210) - the design - and nothing said so from outside.
#
# SM653 fixed the other end of the same falsehood (a tool listed without saying
# where it can be called) in the description, because the description is what
# the caller reads. This does the same: a reduced listing says WHY in the two
# descriptions it does return, with the remedy; the connector instructions say
# the listing is filtered before they name a tool; and a full listing carries
# no such prefix.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $t    = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $d = "$t/site/public_html";
mkdir $d;
mkdir "$d/lazysite";
mkdir "$d/lazysite/auth";
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

# The users tool, stubbed: the account's name decides its grants.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
print( encode_json({ ok => 0, error => 'unknown' } ) ), exit 0 if $u =~ /unknown/;
my %caps = (manage_content=>1, ui=>1);
$caps{mcp} = 1 unless $u =~ /nomcp/;
$caps{manager_ui} = 1 if $u =~ /mgr/;
$caps{ui} = 0 if $u =~ /agent/;
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub rpc {
    my ( $payload, $auth ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $auth if defined $auth;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub list { my $r = rpc( { jsonrpc => '2.0', id => 1, method => 'tools/list' }, $_[0] ); return $r->{result}{tools} || [] }
sub names { return join ',', sort map { $_->{name} } @{ $_[0] } }
sub desc_of { my ( $tools, $n ) = @_; my ($t) = grep { $_->{name} eq $n } @$tools; return $t ? $t->{description} : '' }

subtest 'no credential: two tools, and they say why' => sub {
    my $tools = list(undef);
    is( names($tools), 'describe_capabilities,whoami', 'introspection only' );
    for my $n (qw(whoami describe_capabilities)) {
        like( desc_of( $tools, $n ), qr/^THIS LISTING IS REDUCED TO INTROSPECTION: no credential was recognised/,
            "$n: says the listing is reduced and why" );
        like( desc_of( $tools, $n ), qr/Send a valid bearer/, "$n: and what to do" );
        like( desc_of( $tools, $n ), qr/appear here once your credential reaches them/,
            "$n: and that the tools named elsewhere do exist" );
    }
};

subtest 'an unrecognised token reads as no credential' => sub {
    my $tools = list('Bearer unknownclient:lzs_tok');
    is( names($tools), 'describe_capabilities,whoami', 'introspection only' );
    like( desc_of( $tools, 'whoami' ), qr/unknown, revoked or rotated out/, 'names the token as the likely cause' );
};

subtest 'an account without mcp: the reason is the missing grant' => sub {
    my $tools = list('Bearer nomcpagent:lzs_tok');
    is( names($tools), 'describe_capabilities,whoami', 'introspection only' );
    like( desc_of( $tools, 'whoami' ), qr/does not hold the mcp capability/, 'says which capability' );
    like( desc_of( $tools, 'whoami' ), qr/Ask the sysop to grant mcp/, 'and the remedy' );
};

subtest 'an interactive manager account: the reason is the account kind' => sub {
    my $tools = list('Bearer mgrclient:lzs_tok');
    is( names($tools), 'describe_capabilities,whoami', 'introspection only' );
    like( desc_of( $tools, 'whoami' ), qr/interactive manager account/, 'says so' );
    like( desc_of( $tools, 'whoami' ), qr/dedicated non-interactive account/, 'and what a partner token should belong to' );
};

subtest 'a full listing carries no prefix' => sub {
    my $tools = list('Bearer agentok:lzs_tok');
    cmp_ok( scalar @$tools, '>', 2, 'more than the introspection pair' );
    for my $tl (@$tools) {
        unlike( $tl->{description}, qr/THIS LISTING IS REDUCED/, "$tl->{name}: no reduced-listing prefix" ) or last;
    }
};

subtest 'the connector instructions say the listing is filtered before naming a tool' => sub {
    my $r = rpc( { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} }, undef );
    my $ins = $r->{result}{instructions} // '';
    like( $ins, qr/tools\/list shows only the tools your credential can call/, 'the rule is stated' );
    like( $ins, qr/their descriptions say why/, 'and where the reason is' );
    my $rule       = index( $ins, 'tools/list shows only' );
    my $first_tool = index( $ins, 'create_form' );
    cmp_ok( $rule, '<', $first_tool, 'stated BEFORE the first tool is named' );
};

subtest 'the bootstrap document states the rule' => sub {
    my $src = do { local ( @ARGV, $/ ) = "$root/lazysite-processor.pl"; <> };
    like( $src, qr/tools\/list is filtered to what .{0,20}the presenting credential may call/s,
        'the ai-partner document explains a short listing' );
};

done_testing();

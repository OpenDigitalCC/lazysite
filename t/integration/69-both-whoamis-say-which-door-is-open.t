#!/usr/bin/perl
# SM491, the half a landing lost: BOTH whoamis emit `reachable`.
#
# The fix shipped in 0.10.28 with the MCP half only - the API edit existed
# in the worktree and was not in the commit, and t/unit/lib/26 could not
# notice because it tests the derivation, not either surface's emission.
# The field verification caught it: pass on MCP, absent on the control API,
# which is exactly the surface the partner briefs tell an agent to try
# first. This file drives both doors and requires the block on each.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

# One stub answers for both doors: a grant holding analytics + manage_content,
# api on, mcp off - the reporter's shape, where `reachable` earns its keep.
my $stub = "$docroot/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
    . "print encode_json({ ok => 1, settings => { analytics => 1, "
    . "manage_content => 1, api => 1, mcp => 0 } });\n";
close $sf;
chmod 0755, $stub;

sub api_whoami {
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'tester',
        LAZYSITE_AUTH_TRUSTED => 1,
        LAZYSITE_USERS_TOOL   => $stub,
        REQUEST_METHOD        => 'GET',
        QUERY_STRING          => 'action=whoami',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}

sub mcp_whoami {
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'whoami', arguments => {} } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
    );
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d    = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}

my $api = api_whoami();
my $mcp = mcp_whoami();

subtest 'the control API carries reachable - the door that was lost' => sub {
    ok( $api->{ok},                      'whoami answers' ) or diag explain $api;
    ok( ref $api->{reachable} eq 'HASH', 'reachable present' )
        or diag( 'This is the half the 0.10.28 landing lost: the partner '
            . 'briefs send agents to the control API FIRST.' );
    is_deeply( $api->{reachable}{analytics}{via}, ['api'],
        'the reporter\'s case: analytics reachable via the api channel' );
    is_deeply( $api->{reachable}{analytics}{requires}, ['mcp'],
        'and mcp is named as the door that is off' );
};

subtest 'the MCP carries it too' => sub {
    ok( ref $mcp->{reachable} eq 'HASH', 'reachable present' ) or diag explain $mcp;
};

subtest 'THE TWO DOORS AGREE - one derivation, no drift' => sub {
    plan skip_all => 'a surface is missing the block; the parity question is moot'
        unless ref $api->{reachable} eq 'HASH' && ref $mcp->{reachable} eq 'HASH';
    is_deeply( $api->{reachable}, $mcp->{reachable},
        'byte-for-byte the same answer for the same grant' );
};

done_testing();

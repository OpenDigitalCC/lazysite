#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): MCP IS A MACHINE DOOR, AND A SITE IN MAINTENANCE
# REFUSES IT TO A CALLER WITHOUT `maintenance_access`.
#
# A tools/call from an account that does not hold it is HTTP 503 with Retry-After
# and a JSON-RPC error of its own code (-32004: not -32002, which tells an agent a
# capability is missing, and not -32001, which tells it to reissue a credential).
# The account that holds it is answered as it always was. Discovery (initialize,
# tools/list) acts on nothing and stays open. Off, nobody is refused; per domain,
# the Host decides.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
plan skip_all => 'mcp missing' unless -f "$root/lazysite-mcp.pl";

my $d = site_tempdir();
make_path("$d/lazysite/auth");
sub write_conf {
    my ($extra) = @_;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nmcp_enabled: true\n$extra";
    close $cf;
}
write_conf("maintenance: on\n");
open my $pf, '>', "$d/index.md" or die $!;
print {$pf} "---\ntitle: Home\n---\nHome\n";
close $pf;

# A stand-in credential authority: every bearer verifies, holding the mcp channel
# and content; only `holder` also holds maintenance_access.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my %caps = ( mcp => 1, manage_content => 1 );
$caps{maintenance_access} = 1 if ( $r->{username} // '' ) eq 'holder';
print encode_json( { ok => 1, settings => \%caps } );
STUB
close $sf;
chmod 0755, $stub;

# One JSON-RPC call. Returns ( http code, headers, decoded body ).
sub mcp {
    my ( $method, $params, %o ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params || {} } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_AUTHORIZATION)};
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{HTTP_HOST}           = $o{host} // 'site.test';
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $o{who}:lzs_tok" if defined $o{who};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ( $head, $jb ) = split /\r?\n\r?\n/, $resp // '', 2;
    my ($code) = ( $head // '' ) =~ /^Status:\s*(\d+)/mi;
    my %h;
    $h{ lc $1 } = $2 while ( $head // '' ) =~ /^([A-Za-z-]+):\s*(.*?)\r?$/mg;
    return ( $code // 200, \%h, eval { decode_json( $jb // '' ) } // {} );
}
sub call { my ( $who, $tool, %o ) = @_; return mcp( 'tools/call', { name => $tool, arguments => {} }, who => $who, %o ) }

sub refused {
    my ( $name, @c ) = @_;
    my ( $code, $h, $j ) = @c;
    is( $code, 503, "$name: HTTP 503" );
    like( $h->{'retry-after'} // '', qr/\A\d+\z/, "$name: Retry-After" );
    is( $j->{error}{code}, -32004, "$name: the maintenance error code" );
    like( $j->{error}{message} // '', qr/in maintenance/i, "$name: the message" );
    is( $j->{error}{data}{kind}, 'maintenance', "$name: kind maintenance" );
    return;
}
sub served {
    my ( $name, @c ) = @_;
    my ( $code, $h, $j ) = @c;
    isnt( $code, 503, "$name: not a 503" );
    ok( !$j->{error}, "$name: no error" ) or diag( encode_json($j) );
    return $j;
}

subtest 'a caller without the capability is refused every tool' => sub {
    refused( 'plain, whoami',     call( 'plain', 'whoami' ) );
    refused( 'plain, list_pages', call( 'plain', 'list_pages' ) );
    refused( 'plain, list_files', call( 'plain', 'list_files' ) );
};

subtest 'a caller with it is answered as always' => sub {
    served( 'holder, whoami',     call( 'holder', 'whoami' ) );
    served( 'holder, list_pages', call( 'holder', 'list_pages' ) );
};

subtest 'discovery acts on nothing and stays open' => sub {
    served( 'initialize', mcp( 'initialize', { protocolVersion => '2025-03-26' } ) );
    served( 'tools/list', mcp( 'tools/list', {} ) );
    my ( $code, undef, $j ) = call( undef, 'whoami' );
    is( $code, 401, 'an unauthenticated tool call is still a 401 (the credential comes first)' );
};

subtest 'maintenance off: nobody is refused' => sub {
    write_conf("maintenance: off\n");
    served( 'plain', call( 'plain', 'list_pages' ) );
    write_conf('');
    served( 'plain, no key', call( 'plain', 'list_pages' ) );
};

subtest 'per domain' => sub {
    write_conf("alias_hosts: a.example, b.example\nalias.a.example.maintenance: on\n");
    refused( 'plain on the domain in maintenance', call( 'plain', 'list_pages', host => 'a.example' ) );
    served( 'plain on its sibling', call( 'plain', 'list_pages', host => 'b.example' ) );
    served( 'plain on the default host', call( 'plain', 'list_pages' ) );
    served( 'holder on the domain in maintenance', call( 'holder', 'list_pages', host => 'a.example' ) );
    write_conf("alias_hosts: a.example, b.example\nmaintenance: on\n");
    refused( 'plain once the instance switch is on', call( 'plain', 'list_pages', host => 'b.example' ) );
};

done_testing;

#!/usr/bin/perl
# SM1263 (ruled 2026-10-22): MCP's remove_permissions, the twin of the control
# API's acl-remove and `lazysite acl remove`. Before it, an agent could set a rule
# and never take one off: set_permissions with empty lists leaves an owner-only
# rule behind. It runs the same function (Files::action_acl_remove), so the same
# capability, the same owner refusal and the same audit action.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;
open my $pf, '>', "$d/content/a.md" or die $!;
print {$pf} "---\ntitle: A\n---\nA.\n";
close $pf;
open my $uf, '>', "$d/lazysite/auth/users" or die $!;
print {$uf} "agent:x\nother:x\nnav:x\n";
close $uf;

# Every caller holds mcp; agent and other hold manage_content, nav holds only manage_nav.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my $u  = $r->{username} // '';
my %caps = ( mcp => 1, dav_scopes => ['content'] );
if ( $u eq 'nav' ) { $caps{manage_nav} = 1 } else { $caps{manage_content} = 1 }
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, $auth ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $auth;
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub call { mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call', params => { name => $_[0], arguments => $_[1] || {} } }, $_[2] ) }
sub sc   { my $r = shift; $r && $r->{result} ? $r->{result}{structuredContent} : undef }
sub acls {
    open my $f, '<', "$d/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = <$f>;
    close $f;
    return eval { decode_json($j) } || {};
}

my ( $agent, $other, $nav ) = map {"Bearer $_:lzs_tok"} qw(agent other nav);

subtest 'it is listed for a manage_content caller, and not for one without it' => sub {
    my $l = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/list' }, $agent );
    my %t = map { $_->{name} => $_ } @{ $l->{result}{tools} || [] };
    ok( $t{remove_permissions}, 'listed' );
    ok( $t{remove_permissions} && $t{remove_permissions}{annotations}
            && !$t{remove_permissions}{annotations}{readOnlyHint}, 'and not marked read-only' );
    my $ln = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/list' }, $nav );
    ok( !grep( { $_->{name} eq 'remove_permissions' } @{ $ln->{result}{tools} || [] } ),
        'not listed for a caller without manage_content' );
};

subtest 'a rule is set, refused to another account, and removed by its owner' => sub {
    my $s = sc( call( 'set_permissions', { path => '/content/a.md', draft => JSON::PP::true() }, $agent ) );
    ok( $s && $s->{ok}, 'agent drafts the page' ) or diag explain $s;
    ok( acls()->{'content/a.md'}, 'the rule is in the store' );
    ok( !-e "$d/content/a.md", 'and the page left the document root' );

    my $no = sc( call( 'remove_permissions', { path => '/content/a.md' }, $other ) );
    ok( $no && !$no->{ok}, 'another account is refused' );
    like( $no->{error} // '', qr/Only the owner may remove permissions/, 'with acl-remove\'s own refusal' );
    ok( acls()->{'content/a.md'}, 'and the rule stays' );

    my $r = sc( call( 'remove_permissions', { path => '/content/a.md' }, $agent ) );
    ok( $r && $r->{ok}, 'the owner removes it' ) or diag explain $r;
    is( $r->{removed}, 1, 'removed: 1' );
    ok( !exists acls()->{'content/a.md'}, 'the rule is gone from the store' );
    ok( -f "$d/content/a.md", 'and the page is back in the document root' );

    my $again = sc( call( 'remove_permissions', { path => '/content/a.md' }, $agent ) );
    ok( $again && $again->{ok}, 'a path with no rule is not an error' );
    is( $again->{removed}, 0, 'removed: 0' );
};

subtest 'without manage_content it is refused' => sub {
    my $r = call( 'remove_permissions', { path => '/content/a.md' }, $nav );
    my $s = sc($r);
    ok( !( $s && $s->{ok} ), 'refused' ) or diag explain $r;
};

subtest 'the audit line is the control API\'s' => sub {
    open my $a, '<', "$d/lazysite/logs/audit.log" or do { fail('no audit log'); return };
    my @l = grep { /acl-remove/ && m{content/a\.md} } <$a>;
    close $a;
    ok( scalar @l, 'an acl-remove line names the path' ) or diag('no acl-remove line in the audit log');
    ok( ( grep { /\bmcp\b/ } @l ), 'with MCP as its origin' );
    ok( ( grep { /\bfail\b/ } @l ), 'and the refused attempt is recorded as a failure' );
};

done_testing;

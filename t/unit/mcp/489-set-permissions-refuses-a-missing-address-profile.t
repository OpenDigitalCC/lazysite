#!/usr/bin/perl
# n812 (O-2 of the 0.16.10 edge run): MCP's set_permissions refuses an address
# profile the store does not hold, naming it, and writes nothing. It answered
# ok: true for addresses: ["zz92-allow"] with no such profile, and the rule then
# refused every write to the path. The same function as the manager API and the
# CLI (Files::action_acl_set; t/integration/730 holds those doors).
#
# Sabotage: restore the warning in place of _address_profile_refusal's call in
# Files::action_acl_set and the refusal subtest fails.
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

spit_profiles();
sub spit_profiles {
    open my $p, '>', "$d/lazysite/auth/address-profiles.json" or die $!;
    print {$p} encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } );
    close $p;
}

my $agent = 'Bearer agent:lzs_tok';

subtest 'a profile the store lacks is refused, naming it, and nothing is written' => sub {
    for my $f (qw(addresses addresses_deny)) {
        my $r = sc( call( 'set_permissions', { path => '/content/a.md', $f => 'zz92-allow' }, $agent ) );
        ok( $r && !$r->{ok}, "$f: refused" ) or diag explain $r;
        like( $r->{error} // '', qr/zz92-allow/, "$f: naming the profile" );
        ok( !acls()->{'content/a.md'}, "$f: no rule written" );
    }
};

subtest 'a profile the store holds is accepted' => sub {
    my $r = sc( call( 'set_permissions', { path => '/content/a.md', addresses => 'office' }, $agent ) );
    ok( $r && $r->{ok}, 'accepted' ) or diag explain $r;
    is_deeply( acls()->{'content/a.md'}{addresses}, ['office'], 'and stored' );
};

done_testing;

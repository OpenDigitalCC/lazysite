#!/usr/bin/perl
# n812 (ruling 234): a page's `addresses:` is a rule, so MCP's write_file refuses a
# page naming an address profile the store does not hold, naming it, and writes
# nothing; and validate_page reports it as an issue (valid: false), as it would be
# refused when saved. The same function as the manager save and WebDAV
# (Manager::Common::page_address_profile_refusal; t/integration/731 holds those).
#
# Sabotage: drop the page_address_profile_refusal call from _content_write_refusal and
# the write_file and validate_page subtests fail.
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
sub page { return "---\ntitle: P\n$_[0]---\nbody\n" }

subtest 'write_file refuses a missing profile, naming it, and writes nothing' => sub {
    my $r = sc( call( 'write_file', { path => '/content/m.md', content => page("addresses: [zz92-allow]\n") }, $agent ) );
    ok( $r && !$r->{ok}, 'refused' ) or diag explain $r;
    like( $r->{error} // '', qr/zz92-allow/, 'naming the profile' );
    ok( !-e "$d/content/m.md", 'nothing written' );
    $r = sc( call( 'write_file', { path => '/content/h.md', content => page("addresses_deny: [office]\n") }, $agent ) );
    ok( $r && $r->{ok}, 'a held profile is written' ) or diag explain $r;
};

subtest 'validate_page reports it as an issue, and a held profile as valid' => sub {
    my $r = sc( call( 'validate_page', { path => '/content/v.md', content => page("addresses: [zz92-allow, office]\n") }, $agent ) );
    ok( $r && !$r->{valid}, 'not valid' ) or diag explain $r;
    my ($i) = grep { $_->{kind} eq 'address-profile-missing' } @{ $r->{issues} || [] };
    ok( $i, 'with an address-profile-missing issue' ) or diag explain $r;
    like( $i->{message} // '', qr/zz92-allow/, 'naming the profile' );
    unlike( $i->{message} // '', qr/\boffice\b/, 'and not the one that exists' );
    $r = sc( call( 'validate_page', { path => '/content/v.md', content => page("addresses: [office]\n") }, $agent ) );
    ok( $r && $r->{valid}, 'a held profile is valid' ) or diag explain $r;
};

done_testing;

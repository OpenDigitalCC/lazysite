#!/usr/bin/perl
# SM852: create_page refuses a page that exists - including one in the private
# store.
#
# create_page checks "does this page exist?" before writing, and refuses with
# "use write_file to overwrite". It asked the docroot only. A protected page
# lives in the private store, so it read as absent, and the save that followed
# resolved - correctly - to the private file and replaced it: a page lost,
# through a tool whose promise is that it never overwrites.
#
# Found by the SM836 review of every write path; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $mcp  = repo_root() . '/lazysite-mcp.pl';
my $d    = site_tempdir();
my $priv = "$d-lazysite-private";
make_path( "$d/lazysite/auth", "$priv/members" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

spit( "$d/lazysite/lazysite.conf", "site_name: X\nmcp_enabled: true\n" );
spit( "$d/about.md",               "---\ntitle: About\n---\nPUBLIC\n" );
spit( "$priv/members/handbook.md", "---\ntitle: Handbook\n---\nTHE-ONLY-COPY\n" );

my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok=>1, settings=>{ mcp=>1, manage_content=>1 } });
STUB
chmod 0755, $stub;

sub create_page {
    my ($slug) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'create_page', arguments => { slug => $slug, title => 'New' } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $resp // '';
}

like( create_page('about'), qr/page already exists/, 'the canary: a public page that exists is refused' );

my $r = create_page('members/handbook');
like( $r, qr/page already exists/, 'a protected page that exists is refused too' );
like( slurp("$priv/members/handbook.md"), qr/THE-ONLY-COPY/, 'and its only copy is untouched' );
ok( !-e "$d/members", 'and nothing was made in the public tree' );

like( create_page('members/new'), qr/"ok"\s*:\s*(?:1|true)/, 'while a new page in the protected section is still created' );
ok( -f "$priv/members/new.md", '... in the private store, with its section' );

done_testing();

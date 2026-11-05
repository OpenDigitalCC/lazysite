#!/usr/bin/perl
# SM1335 and SM1339 (ruling 81, T-39), over MCP.
#
# The 05/11 filing: an agent uploaded six photographs into the docroot's copy of
# a theme (/lazysite-assets/harmony/harmony-r3/), the page it edited was served
# by a secondary domain whose own copy was untouched, and nothing it could read
# said which of the three copies a host serves - list_files showed them alike.
#
# So: list_files marks a served copy with its source and the hosts that serve it,
# each with whether the theme is active there; write_file and upload_file into a
# copy are refused naming the source; and a write_file to the source reaches
# every host's copy.
#
# With the fix reverted the listing carries no mark, both writes land in the
# copy, and the source write leaves the secondary copy on the old bytes.
use strict;
use warnings;
use Test::More;
use JSON::PP      qw(encode_json decode_json);
use File::Path    qw(make_path);
use MIME::Base64  qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir run_child);
use Lazysite::Manager::Themes ();

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
sub put {
    my ( $rel, $text ) = @_;
    ( my $dir = "$d/$rel" ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $fh, '<', "$d/$_[0]" or return undef; local $/; <$fh> }

# harmony2050.org has its own root and serves the harmony layout with base;
# harmony-r3 is pinned by its pages and active nowhere.
put( 'lazysite/lazysite.conf', <<'CONF' );
site_name: T
mcp_enabled: true
alias_hosts: harmony2050.org
alias.harmony2050.org.content_root: sites/harmony2050.org
alias.harmony2050.org.layout: harmony
alias.harmony2050.org.theme: base
CONF
put( 'lazysite/layouts/harmony/layout.tt', "[% content %]\n" );
for my $t (qw(base harmony-r3)) {
    put( "lazysite/layouts/harmony/themes/$t/theme.json", qq({"name":"$t"}) );
    put( "lazysite/layouts/harmony/themes/$t/assets/main.css", "/* $t v1 */\n" );
}
{
    local $Lazysite::Manager::Themes::DOCROOT      = $d;
    local $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    Lazysite::Manager::Themes::_mirror_theme_assets( 'harmony', $_ ) for qw(base harmony-r3);
}

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1, manage_themes => 1 } });
STUB
chmod 0755, $stub;

sub call {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'discard' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $j && $j->{result} ? ( $j->{result}{structuredContent} // {} ) : { raw => $resp };
}

my $SCOPY = '/sites/harmony2050.org/lazysite-assets/harmony/harmony-r3';
my $SRC   = 'lazysite/layouts/harmony/themes/harmony-r3/assets';

subtest 'list_files names the copy\'s source and the host that serves it' => sub {
    my $l = call( 'list_files', { path => '/sites/harmony2050.org/lazysite-assets/harmony' } );
    my %e = map { $_->{name} => $_ } @{ $l->{entries} || [] };
    my $r3 = $e{'harmony-r3'}{served_copy};
    ok( $r3, 'harmony-r3\'s copy is marked as a served copy' ) or diag explain $l;
    is( $r3->{source}, "$SRC/", 'naming its source' );
    is( $r3->{served_by}[0]{host}, 'harmony2050.org', 'served to harmony2050.org' );
    ok( !$r3->{served_by}[0]{theme_active}, 'where it is not the active theme' );
    ok( $e{base}{served_copy}{served_by}[0]{theme_active}, 'and base is' );
};

subtest 'write_file and upload_file into a copy are refused, naming the source' => sub {
    my $w = call( 'write_file', { path => "$SCOPY/main.css", content => "x\n" } );
    ok( !$w->{ok}, 'write_file refused' ) or diag explain $w;
    is( $w->{kind}, 'served-artifact-refused', 'by the served-artifact rule' );
    like( $w->{error} // '', qr{\Q$SRC\E/main\.css}, 'naming the source file' );
    my $u = call( 'upload_file', { path => '/lazysite-assets/harmony/harmony-r3/photo.jpg',
            content_base64 => encode_base64( 'JPEG', '' ) } );
    ok( !$u->{ok}, 'upload_file into the docroot\'s copy refused' ) or diag explain $u;
    like( $u->{error} // '', qr{\Q$SRC\E/photo\.jpg}, 'naming where the photograph belongs' );
    ok( !-e "$d/lazysite-assets/harmony/harmony-r3/photo.jpg", 'nothing landed' );
};

subtest 'write_file to the source reaches every host\'s copy' => sub {
    my $w = call( 'write_file', { path => "/$SRC/main.css", content => "/* r3 v2 */\n" } );
    ok( $w->{ok}, 'written' ) or diag explain $w;
    is( slurp('lazysite-assets/harmony/harmony-r3/main.css'), "/* r3 v2 */\n", 'the docroot\'s copy' );
    is( slurp("$SCOPY/main.css"), "/* r3 v2 */\n", 'the secondary domain\'s copy' );
    is_deeply( $w->{mirrors_refreshed}{themes}, ['harmony/harmony-r3'], 'and the reply says so' );
};

done_testing;

#!/usr/bin/perl
# SM1354: A PAGE'S COPY IS IN ITS PAGE'S SCOPE.
#
# The copy of content/clientB/secret.md lives at
# lazysite/copies/pages/content/clientB/secret.md - in the engine tree, which
# the scope check skips (the layouts carve-out is not content). A grant confined
# to content/clientA must not reach clientB's copies through that skip: the scope
# check asks the copy's PAGE. With the change reverted the scoped partner reads
# and writes clientB's copy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";

my $d = site_tempdir();
make_path( "$d/content/clientA", "$d/content/clientB", "$d/lazysite/auth",
    "$d/lazysite/copies/pages/content/clientB" );
sub put { open my $f, '>', "$d/$_[0]" or die "$_[0]: $!"; print {$f} $_[1]; close $f }
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'content/clientA/ok.md',     "---\ntitle: A\n---\nA\n" );
put( 'content/clientB/secret.md', "---\ntitle: B\n---\nB\n" );
put( 'lazysite/copies/pages/content/clientB/secret.md', "---\ntitle: B\n---\nB draft\n" );
put( 'lazysite/copies/records.json', encode_json( { 'content/clientB/secret.md' => {
    page => 'content/clientB/secret.md', copy => 'lazysite/copies/pages/content/clientB/secret.md',
    taken_by => 'wide', taken_at => time, taken_from => { digest => 'x' }, changed_by => [] } } ) );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my %s = ( manage_content => 1, mcp => 1 );
$s{dav_scopes} = ['content/clientA'] if ( $r->{username} // '' ) =~ /scoped/;
print encode_json( { ok => 1, settings => \%s } );
STUB
chmod 0755, $stub;

sub call {
    my ( $tool, $args, $user ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $user:lzs_x";
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

my $copy = '/lazysite/copies/pages/content/clientB/secret.md';

my $r = call( 'read_file', { path => $copy }, 'scoped' );
is( $r->{error}{code}, -32002, 'a grant scoped to clientA is refused clientB\'s copy' )
    or diag explain $r;
my $w = call( 'write_file', { path => $copy, content => "---\ntitle: B\n---\nmine\n" }, 'scoped' );
is( $w->{error}{code}, -32002, '...and cannot write it' );
like( do { open my $f, '<', "$d$copy" or die; local $/; <$f> }, qr/B draft/, 'the copy is unchanged' );
is( call( 'discard_copy', { path => '/content/clientB/secret.md' }, 'scoped' )->{error}{code}, -32002,
    '...nor discard it' );
my $wide = call( 'read_file', { path => $copy }, 'wide' );
ok( !$wide->{error} && $wide->{result}{structuredContent}{ok}, 'an unscoped grant reads it' )
    or diag explain $wide;

# The carve-out names the copies folder as a literal (lint 272: the warm-fork parent
# holds no computed value); it is the folder Lazysite::PageCopy writes copies into.
require Lazysite::Manager::Common;
require Lazysite::PageCopy;
ok( ( grep { $_ eq Lazysite::PageCopy::copy_prefix() } @Lazysite::Manager::Common::LAZYSITE_OPEN_PREFIXES ),
    'the carve-out is the folder the copies live in' );

done_testing();

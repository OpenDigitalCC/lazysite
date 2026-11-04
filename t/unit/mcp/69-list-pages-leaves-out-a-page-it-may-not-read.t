#!/usr/bin/perl
# SM1312 (ruling 60): list_pages asks a page's rule before it reads the title. A
# page under a read rule left in the document root - a section protected before
# 0.10.8 and not re-applied, or one a pull put back - had its title listed to a
# grant read_page refuses.
#
# With the fix reverted, the gated page and its title are listed to both grants
# that may not read it. The reader named in the rule is the control.
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
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content/mine" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'content/mine/open.md',   "---\ntitle: Open\n---\nOpen.\n" );
put( 'content/mine/legacy.md', "---\ntitle: SECRET-TITLE\n---\nGated.\n" );
put( 'lazysite/auth/acls.json',
    encode_json( { 'content/mine/legacy.md' => { owner => 'reader', read => ['reader'] } } ) );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my %caps = ( mcp => 1, manage_content => 1 );
$caps{dav_scopes} = ['content/mine'] if ( $r->{username} // '' ) ne 'wide';
print encode_json({ ok => 1, settings => \%caps });
STUB
chmod 0755, $stub;

sub pages {
    my ($user) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'list_pages', arguments => {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $user:lzs_tok";
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    my $s = $j && $j->{result} ? $j->{result}{structuredContent} : {};
    return [ sort map { $_->{path} } @{ $s->{pages} || [] } ], join( ',', map { $_->{title} } @{ $s->{pages} || [] } );
}

for my $user (qw(agent wide)) {
    my ( $p, $titles ) = pages($user);
    ok( ( grep { $_ eq '/content/mine/open.md' } @$p ), "$user: an open page is listed" );
    ok( !( grep { $_ eq '/content/mine/legacy.md' } @$p ), "$user: the gated page is not" ) or diag explain $p;
    unlike( $titles, qr/SECRET-TITLE/, "$user: nor its title" );
}
my ( $p, $titles ) = pages('reader');
ok( ( grep { $_ eq '/content/mine/legacy.md' } @$p ), 'the reader its rule names sees it (control)' );
like( $titles, qr/SECRET-TITLE/, '...with its title' );

done_testing;

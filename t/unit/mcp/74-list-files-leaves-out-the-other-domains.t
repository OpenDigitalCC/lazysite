#!/usr/bin/perl
# SM1372 (ruling 137): A LISTING LEAVES OUT THE OTHER DOMAINS' CONTENT ROOTS,
# over MCP list_files, run through the real CGI.
#
# Ruling 126 refused an account that reaches the primary's content (granted
# nothing, or the primary's row) every path inside another domain's content
# root, and the register entry recorded that the folder names stayed visible: a
# listing of sites/ named them. Ruling 137: the listing leaves them out for a
# caller refused them; an account granted the domain still sees its folder.
# The manager's file browser: t/unit/manager/446. WebDAV PROPFIND: t/unit/dav/39.
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

sub put {
    my ( $d, $rel, $text ) = @_;
    ( my $dir = "$d/$rel" ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}

# A site with two secondary domains rooted under sites/, a folder of the
# primary's own beside them, and an MCP grant of the scopes given.
sub site {
    my (@scopes) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    put( $d, 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\nalias_hosts: alpha.test, beta.test\n"
            . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n" );
    put( $d, 'about.md',             "# about\n" );
    put( $d, 'sites/alpha/index.md', "# alpha\n" );
    put( $d, 'sites/beta/index.md',  "# beta\n" );
    put( $d, 'sites/shared/note.md', "# the primary's own folder under sites/\n" );
    my $caps = encode_json( { mcp => 1, manage_content => 1, dav_scopes => \@scopes } );
    put( $d, 'users-stub.pl', "#!/usr/bin/perl\nprint q{{\"ok\":1,\"settings\":$caps}};\n" );
    chmod 0755, "$d/users-stub.pl";
    return $d;
}

sub list_names {
    my ( $d, $path ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'list_files', arguments => { path => $path } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = "$d/users-stub.pl";
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'discard' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    my $sc = $j && $j->{result} ? $j->{result}{structuredContent} : undef;
    return undef unless ref $sc eq 'HASH' && $sc->{ok};
    return join ' ', sort map { $_->{name} } @{ $sc->{entries} || [] };
}

subtest 'granted nothing: sites/ lists the primary\'s own folder, not the domains\'' => sub {
    my $d = site();
    is( list_names( $d, '/sites' ), 'shared', 'alpha and beta are left out' );
    like( list_names( $d, '/' ) // '', qr/\babout\.md\b.*\bsites\b/, 'the docroot still lists the primary\'s content' );
};

subtest 'granted the primary row: the same' => sub {
    is( list_names( site('/'), '/sites' ), 'shared', 'alpha and beta are left out' );
};

subtest 'granted the primary and alpha: alpha is listed, beta is not' => sub {
    is( list_names( site( '/', 'sites/alpha' ), '/sites' ), 'alpha shared', 'its granted domain is listed' );
};

done_testing();

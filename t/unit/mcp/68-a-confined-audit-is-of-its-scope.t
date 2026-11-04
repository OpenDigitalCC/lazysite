#!/usr/bin/perl
# SM1311 (ruling 59): audit_site for a grant confined to a scope audits the scope.
# It walked the whole site - every domain's titles, links, statics and rule keys -
# for a grant read_file confines to one. Confining the page walk alone would have
# called every link to a page outside the scope broken, so such a link is listed
# in outside_scope_links, never in broken_links, and is never looked up. A link
# that names a path on a domain served from the scope root (a content root's URLs
# are relative to it) is read there.
#
# With the fix reverted, the confined audit lists the other folder's broken link,
# missing title, stale HTML and rule key, and has no outside_scope_links. The
# unconfined grant's audit is the control.
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
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content/mine", "$d/other" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'content/mine/a.md', "---\ntitle: A\n---\n[c](/content/mine/c) [gone](/content/mine/gone) "
        . "[short](/c) [b](/other/b) [nothing](/other/nothing)\n" );
put( 'content/mine/c.md',     "---\ntitle: C\n---\nC.\n" );
put( 'content/mine/old.html', "<p>old</p>\n" );
put( 'other/b.md',            "---\n---\n[zzz](/other/zzz)\n" );
put( 'other/stale.html',      "<p>stale</p>\n" );
put( 'lazysite/auth/acls.json', encode_json( {
    'content/mine/nokey' => { owner => 'x', read => ['x'] },
    'other/nokey'        => { owner => 'x', read => ['x'] },
} ) );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my %caps = ( mcp => 1, manage_content => 1 );
$caps{dav_scopes} = ['content/mine'] if ( $r->{username} // '' ) eq 'agent';
print encode_json({ ok => 1, settings => \%caps });
STUB
chmod 0755, $stub;

sub audit {
    my ($user) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'audit_site', arguments => {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $user:lzs_tok";
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $j && $j->{result} ? $j->{result}{structuredContent} : $j;
}
sub tos   { [ sort map { $_->{to} } @{ $_[0] || [] } ] }
sub keys_ { [ sort map { $_->{key} } @{ $_[0] || [] } ] }

subtest 'a confined grant is audited within its scope' => sub {
    my $a = audit('agent');
    ok( $a && $a->{ok}, 'answered' ) or diag explain $a;
    is_deeply( $a->{scope_roots}, ['content/mine'], 'naming its scope' );
    is_deeply( tos( $a->{broken_links} ), ['/content/mine/gone'], 'the one broken link is the one in its scope' );
    is_deeply( $a->{missing_title}, [], 'no page outside the scope is reported' );
    ok( ( grep { $_ eq '/content/mine/old.html' } @{ $a->{stale_html} } ), 'stale HTML in the scope is found' );
    ok( !( grep { m{^/other/} } @{ $a->{stale_html} } ), 'and none outside it' );
    is_deeply( keys_( $a->{acl_keys_matching_nothing} ), ['content/mine/nokey'], 'rule keys only in the scope' );
};

subtest 'a link to a page outside the scope is outside the scope, never broken' => sub {
    my $a = audit('agent');
    is_deeply( tos( $a->{outside_scope_links} ), [ '/other/b', '/other/nothing' ],
        'both outside links are listed there, the existing page and the missing one alike' );
    ok( !( grep { m{^/other/} } @{ tos( $a->{broken_links} ) } ), 'and neither is called broken' );
    ok( !( grep { $_ eq '/c' } @{ tos( $a->{broken_links} ) }, @{ tos( $a->{outside_scope_links} ) } ),
        'a path on the domain the scope root serves is read there' );
};

subtest 'an unconfined grant is audited as before (control)' => sub {
    my $w = audit('wide');
    ok( $w && $w->{ok}, 'answered' );
    ok( !exists $w->{outside_scope_links} && !exists $w->{scope_roots}, 'no scope keys' );
    ok( ( grep { $_ eq '/other/zzz' } @{ tos( $w->{broken_links} ) } ),     'the other folder\'s broken link is found' );
    ok( ( grep { $_ eq '/other/nothing' } @{ tos( $w->{broken_links} ) } ), 'and a missing target anywhere is broken' );
    ok( ( grep { $_ eq '/other/b' } @{ $w->{missing_title} } ),            'every page\'s title is checked' );
    ok( ( grep { $_ eq '/other/stale.html' } @{ $w->{stale_html} } ),      'and every stale file' );
};

done_testing;

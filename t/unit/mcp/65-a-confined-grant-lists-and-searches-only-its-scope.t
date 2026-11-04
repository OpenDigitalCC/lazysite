#!/usr/bin/perl
# SM1308 (ruling 47, T-01): A GRANT CONFINED TO A SCOPE IS ANSWERED FROM ITS
# SCOPE. The dispatcher's scope pass skips an argument that is not given, so a
# grant that is refused '/' when it names it was shown the whole docroot when
# it named nothing: list_files defaulted to '/', search_files walked the
# docroot and list_pages takes no path at all. The search also printed lines
# of a file whose rule the caller does not pass, which read_file refuses.
#
# With the fix reverted, the no-path listings and searches here name the files
# outside the scope, the in-scope search returns the gated page's line, and the
# link rewrite and the delete report reach the page outside the scope. The
# explicit paths, inside and outside the scope, are the controls: the scope pass
# answered them before, and still does.
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
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content/mine", "$d/content/theirs", "$d/other" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'lazysite/auth/users',    "agent:x\nwide:x\nsomeoneelse:x\n" );
put( 'index.md',               "---\ntitle: Home\n---\nMARKER home\n" );
put( 'content/mine/a.md',      "---\ntitle: Mine A\n---\nMARKER mine\n" );
put( 'content/mine/c.md',      "---\ntitle: Mine C\n---\nSee [A](/content/mine/a) - MARKER\n" );
put( 'content/mine/secret.md', "---\ntitle: Gated\n---\nMARKER gated line\n" );
put( 'content/theirs/t.md',    "---\ntitle: Theirs\n---\nMARKER theirs\n" );
put( 'other/b.md',             "---\ntitle: Other B\n---\nSee [A](/content/mine/a) - MARKER\n" );

# A rule the agent does not pass, on a page inside its scope, left in the
# document root as a site protected before 0.10.8 (or after a pull) has it.
put( 'lazysite/auth/acls.json',
    encode_json( { 'content/mine/secret.md' => { owner => 'someoneelse', read => ['someoneelse'] } } ) );

# agent: confined to content/mine. wide: a grant with no scope (the control).
my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my $u  = $r->{username} // '';
my %caps = ( mcp => 1, manage_content => 1 );
$caps{dav_scopes} = ['content/mine'] if $u eq 'agent';
print encode_json({ ok => 1, settings => \%caps });
STUB
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
sub refused {
    my $r = shift;
    return 1 if $r && $r->{error};
    my $s = sc($r);
    return ( $s && !$s->{ok} ) ? 1 : 0;
}
sub paths_of { my $s = shift; return [ sort map { $_->{path} } @{ ( $s || {} )->{ $_[0] } || [] } ] }
sub slurp { open my $f, '<', "$d/$_[0]" or return ''; local $/; my $c = <$f>; close $f; return $c }

my ( $agent, $wide ) = map {"Bearer $_:lzs_tok"} qw(agent wide);

subtest 'list_files with no path is the scope roots, never the docroot' => sub {
    for my $args ( {}, { path => '' } ) {
        my $what = %$args ? 'an empty path' : 'no path';
        my $s    = sc( call( 'list_files', $args, $agent ) );
        ok( $s && $s->{ok}, "$what is answered" ) or diag explain $s;
        is_deeply( paths_of( $s, 'entries' ), ['/content/mine'], "$what lists the scope root alone" );
    }
    my $w = sc( call( 'list_files', {}, $wide ) );
    ok( ( grep { $_ eq '/other' } @{ paths_of( $w, 'entries' ) } ),
        'a grant with no scope is still shown the docroot (control)' );
};

subtest 'list_files with a path: outside the scope refused, inside it listed (controls)' => sub {
    ok( refused( call( 'list_files', { path => '/other' }, $agent ) ), 'a path outside the scope is refused' );
    ok( refused( call( 'list_files', { path => '/' }, $agent ) ),      'and so is / named outright' );
    my $in = sc( call( 'list_files', { path => '/content/mine' }, $agent ) );
    ok( $in && $in->{ok}, 'a path inside the scope is listed' );
    ok( ( grep { $_ eq '/content/mine/a.md' } @{ paths_of( $in, 'entries' ) } ), '...with its files' );
};

subtest 'list_pages answers the pages within the scope' => sub {
    my $s = sc( call( 'list_pages', {}, $agent ) );
    ok( $s && $s->{ok}, 'answered' ) or diag explain $s;
    my @p = @{ paths_of( $s, 'pages' ) };
    ok( ( grep { $_ eq '/content/mine/a.md' } @p ), 'a page in the scope is listed' );
    is_deeply( [ grep { !m{^/content/mine/} } @p ], [], 'and no page outside it' ) or diag explain \@p;
    my $w = sc( call( 'list_pages', {}, $wide ) );
    ok( ( grep { $_ eq '/other/b.md' } @{ paths_of( $w, 'pages' ) } ), 'a grant with no scope sees every page (control)' );
};

subtest 'search_files with no path searches the scope roots' => sub {
    my $s = sc( call( 'search_files', { query => 'MARKER' }, $agent ) );
    ok( $s && $s->{ok}, 'answered' ) or diag explain $s;
    my @p = @{ paths_of( $s, 'matches' ) };
    ok( ( grep { $_ eq '/content/mine/a.md' } @p ), 'a hit in the scope is returned' );
    is_deeply( [ grep { !m{^/content/mine/} } @p ], [], 'and none outside it' ) or diag explain \@p;
};

subtest 'search_files with a path: outside refused (control), inside answered' => sub {
    ok( refused( call( 'search_files', { query => 'MARKER', path => '/other' }, $agent ) ),
        'a path outside the scope is refused' );
    my $s = sc( call( 'search_files', { query => 'MARKER', path => '/content/mine' }, $agent ) );
    ok( $s && $s->{ok}, 'a path inside the scope is searched' );
    ok( ( grep { $_ eq '/content/mine/c.md' } @{ paths_of( $s, 'matches' ) } ), '...and its hits returned' );
};

subtest 'a hit in a file whose rule the caller does not pass is left out' => sub {
    my $r = sc( call( 'read_file', { path => '/content/mine/secret.md' }, $agent ) );
    ok( $r && !$r->{ok}, 'read_file refuses the gated page (control)' );
    for my $args ( { query => 'gated line' }, { query => 'gated line', path => '/content/mine' } ) {
        my $s = sc( call( 'search_files', $args, $agent ) );
        ok( $s && $s->{ok}, 'the search answers' );
        is( $s->{count}, 0, 'and returns no line of the gated page' . ( $args->{path} ? ' (path given)' : '' ) )
            or diag explain $s;
    }
    my $w = sc( call( 'search_files', { query => 'gated line' }, $wide ) );
    is( $w->{count}, 0, 'a grant with no scope does not read it through the search either' );
};

subtest 'delete_page names the references only within the scope' => sub {
    put( 'content/mine/d.md',  "---\ntitle: D\n---\nD.\n" );
    put( 'content/mine/e.md',  "---\ntitle: E\n---\n[D](/content/mine/d)\n" );
    put( 'other/f.md',         "---\ntitle: F\n---\n[D](/content/mine/d)\n" );
    my $s = sc( call( 'delete_page', { slug => 'content/mine/d' }, $agent ) );
    ok( $s && $s->{ok}, 'deleted' ) or diag explain $s;
    my @r = @{ $s->{still_referenced_in} || [] };
    ok( ( grep { $_ eq '/content/mine/e.md' } @r ), 'a reference in the scope is named' );
    ok( !( grep { $_ eq '/other/f.md' } @r ), 'a page outside the scope is not' ) or diag explain \@r;
};

subtest 'rename_page rewrites links only within the scope' => sub {
    my $s = sc( call( 'rename_page', { old => 'content/mine/a', new => 'content/mine/a2', update_links => JSON::PP::true() }, $agent ) );
    ok( $s && $s->{ok}, 'renamed' ) or diag explain $s;
    like( slurp('content/mine/c.md'), qr{/content/mine/a2\)}, 'a link in the scope is rewritten' );
    like( slurp('other/b.md'), qr{/content/mine/a\)}, 'a page outside the scope is not written' );
};

done_testing;

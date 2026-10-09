#!/usr/bin/perl
# SM977 (ruled 2026-10-09, "Refuse existing target"): MCP copy_file copies to a
# NEW path, as its description says and as the manager's copy does; an existing
# destination is refused and left as it was. write_file is the way to replace.
#
# Found in Q15g (tmp/q15g-other-tools-probe.out): copy_file to /about.md
# overwrote the existing page. It reads the source and writes through
# action_save, so it skipped action_copy's refusal of an existing target.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/docs" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmcp_enabled: true\n" );
my $stub = "$d/users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_content => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST',
        CONTENT_LENGTH     => length $body, LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION => 'Bearer tester:lzs_tok' );
    my $pid = open2( my $out, my $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

my $TEMPLATE = "---\ntitle: Template\n---\n\nThe template.\n";
my $ABOUT    = "---\ntitle: About us\n---\n\nReal content.\n";
spit( "$d/template.md", $TEMPLATE );
spit( "$d/about.md",    $ABOUT );
spit( "$d/docs/a.md",   "---\ntitle: A\n---\nA\n" );

my $r = mcp( 'copy_file', { from => '/template.md', to => '/about.md' } );
ok( !$r->{ok}, 'copy_file onto an existing page is refused' ) or diag explain $r;
is( $r->{kind}, 'exists', '...as the manager\'s copy refuses it' );
like( $r->{error}, qr/target 'about\.md' already exists/, '...naming the target' );
like( $r->{error}, qr/write_file/, '...and the way to replace a file' );
is( slurp("$d/about.md"), $ABOUT, 'the page is unchanged' );

my $r2 = mcp( 'copy_file', { from => '/template.md', to => '/docs/a.md' } );
ok( !$r2->{ok} && slurp("$d/docs/a.md") =~ /title: A/, 'in a folder too' ) or diag explain $r2;

my $r3 = mcp( 'copy_file', { from => '/template.md', to => '/team.md' } );
ok( $r3->{ok}, 'a copy to a new path is written' ) or diag explain $r3;
is( slurp("$d/team.md"), $TEMPLATE, '...with the source\'s text' );

my $r4 = mcp( 'copy_file', { from => '/missing.md', to => '/about.md' } );
ok( !$r4->{ok} && slurp("$d/about.md") eq $ABOUT, 'a missing source is refused before the target is looked at' );

my $w = mcp( 'write_file', { path => '/about.md', content => $TEMPLATE } );
ok( $w->{ok}, 'write_file still replaces a file' ) or diag explain $w;
is( slurp("$d/about.md"), $TEMPLATE, '...with the new text' );

my $tools = do {
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/list' } );
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST',
        CONTENT_LENGTH     => length $body, LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION => 'Bearer tester:lzs_tok' );
    my $pid = open2( my $out, my $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    ( eval { decode_json($jb) } || {} )->{result}{tools} || [];
};
my ($cf) = grep { $_->{name} eq 'copy_file' } @$tools;
like( $cf->{description} // '', qr/Refuses a destination that already exists/, 'the description says so' );

done_testing();

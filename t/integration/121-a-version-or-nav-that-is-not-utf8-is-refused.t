#!/usr/bin/perl
# SM976 Q15k (ruled 2026-10-10, "Fix both"): the two findings Q15j did not
# change, on both surfaces.
#
# (1) Restoring a recorded version whose bytes are not valid UTF-8 - MCP
#     restore_version, the control API's git-restore - is refused with the
#     encoding error (kind page-encoding-refused, the first invalid byte's
#     offset, how to fix it) and leaves the page as it is. Before, the version's
#     bytes were written back as they were (tmp/q15j-single-page-probe.after.out,
#     hist.md): a text write producing a page that is not UTF-8.
# (2) The structured nav read - MCP read_nav, the control API's nav-read - of a
#     nav.conf that is not UTF-8 answers the encoding error naming nav.conf.
#     Before, MCP answered "Tool error: read_nav" (the encoder died on the
#     labels) and the control API no JSON body.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use Lazysite::Git  ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui mcp manage_content manage_nav);
my $s   = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\ngit_history: enabled\n" );
my $d = $s->docroot;
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or die "$p: $!"; local $/; return scalar <$fh> }

$s->add_user('op');
$s->grant( 'op', 'g-op', \@ALL, \@ALL );
# SM1057: the manager's door needs `ui`, which a group granting mcp/api may not
# also grant (SM127) - so the cookie calls below are a manager-UI account's.
$s->add_user('ed');
$s->grant( 'ed', 'g-ed', [qw(ui manage_content manage_nav)], [qw(ui manage_content manage_nav)] );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my $tok = uapi( { action => 'token', username => 'op' } )->{token} // '';
ok( length $tok, 'the MCP caller has a token' );

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer op:$tok";
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/lazysite-mcp.pl" );
    print {$i} $body;
    close $i;
    my $resp = do { local $/; <$o> };
    waitpid $pid, 0;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, error => "JSON-RPC error: $j->{error}{message}" } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

# The answer the ruling asks for: the encoding error, as a page or file it
# cannot read (Manager::Common::page_read_refusal).
sub encoding_error {
    my ( $r, $label, $at, $what ) = @_;
    is( $r->{kind}, 'page-encoding-refused', "$label: refused with the encoding error" )
        or diag explain $r;
    ok( !$r->{ok}, "$label: not ok" );
    like( $r->{error} // '', qr/$what is not valid UTF-8/, "$label: names what is not UTF-8" );
    like( $r->{error} // '', qr/first invalid byte is at offset $at\b/, "$label: and the offset ($at)" );
    like( $r->{error} // '', qr/To fix it, /, "$label: and how to fix it" );
    return;
}

SKIP: {
    skip 'git not available', 4 unless Lazysite::Git::git_available();

    # A page whose recorded version is not UTF-8 (offset 24) and whose current
    # one is. The bytes reach history as git or SSH would put them there.
    spit( "$d/hist.md", "---\ntitle: H\n---\nold caf\xE9 text\n" );
    spit( "$d/good.md", "---\ntitle: G\n---\nold caf\xC3\xA9 text\n" );
    Lazysite::Git::init( $d, 'operator' )->{ok} or die 'history init failed';
    my $sha  = Lazysite::Git::file_log( $d, 'hist.md' )->[0]{sha};
    my $gsha = Lazysite::Git::file_log( $d, 'good.md' )->[0]{sha};
    my $now  = "---\ntitle: H\n---\nnew text\n";
    # The current text recorded too, so a restore that wrote would be a commit.
    ok( mcp( write_file => { path => '/hist.md', content => $now } )->{ok}, 'the current page is saved' );
    spit( "$d/good.md", "---\ntitle: G\n---\nnew text\n" );
    my $commits = Lazysite::Git::count_commits($d);

    subtest 'restore of a version that is not UTF-8 is refused and writes nothing' => sub {
        my $r = mcp( restore_version => { path => '/hist.md', version => $sha } );
        encoding_error( $r, 'MCP restore_version', 24, qr/Version [0-9a-f]{7} of the page 'hist\.md'/ );
        like( $r->{error} // '', qr/left as it is/, 'MCP: says the page is left as it is' );
        is( slurp("$d/hist.md"),              $now,     'MCP: the page is as it was' );
        is( Lazysite::Git::count_commits($d), $commits, 'MCP: no restore was recorded' );

        spit( "$d/hist.md", $now );
        $r = $s->call( 'ed', 'git-restore', query => "action=git-restore&path=/hist.md&sha=$sha", body => {} );
        encoding_error( $r, 'API git-restore', 24, qr/Version [0-9a-f]{7} of the page 'hist\.md'/ );
        is( slurp("$d/hist.md"),              $now,     'API: the page is as it was' );
        is( Lazysite::Git::count_commits($d), $commits, 'API: no restore was recorded' );
    };

    subtest 'restore of a UTF-8 version restores as before (the control)' => sub {
        my $r = mcp( restore_version => { path => '/good.md', version => $gsha } );
        ok( $r->{ok}, 'MCP restore_version restores' ) or diag explain $r;
        is( slurp("$d/good.md"), "---\ntitle: G\n---\nold caf\xC3\xA9 text\n", '...the version, byte for byte' );
        spit( "$d/good.md", "---\ntitle: G\n---\nnew text\n" );
        $r = $s->call( 'ed', 'git-restore', query => "action=git-restore&path=/good.md&sha=$gsha", body => {} );
        ok( $r->{ok}, 'API git-restore restores' ) or diag explain $r;
        is( slurp("$d/good.md"), "---\ntitle: G\n---\nold caf\xC3\xA9 text\n", '...the version, byte for byte' );
    };

    subtest 'a version that is not there still answers first' => sub {
        my $r = mcp( restore_version => { path => '/hist.md', version => 'abcdef1' } );
        ok( !$r->{ok}, 'refused' );
        isnt( $r->{kind} // '', 'page-encoding-refused', 'for its own reason' );
    };
}

subtest 'the structured nav read of a nav.conf that is not UTF-8' => sub {
    spit( "$d/lazysite/nav.conf", "Home | /\nCaf\xE9 | /cafe\n" );    # offset 12
    my $r = mcp( read_nav => {} );
    encoding_error( $r, 'MCP read_nav', 12, qr/The file 'lazysite\/nav\.conf'/ );
    like( $r->{error} // '', qr/set_nav/, 'MCP: the remedy names set_nav' );
    $r = $s->call( 'ed', 'nav-read' );
    encoding_error( $r, 'API nav-read', 12, qr/The file 'lazysite\/nav\.conf'/ );
};

subtest 'a UTF-8 nav.conf reads as before (the control)' => sub {
    spit( "$d/lazysite/nav.conf", "Home | /\nCaf\xC3\xA9 | /cafe\n" );
    for my $c ( [ 'MCP read_nav', mcp( read_nav => {} ) ], [ 'API nav-read', $s->call( 'ed', 'nav-read' ) ] ) {
        my ( $label, $r ) = @$c;
        ok( $r->{ok}, "$label reads it" ) or diag explain $r;
        is( join( ',', map { $_->{label} } @{ $r->{items} || [] } ), "Home,Caf\x{e9}", '...its labels decoded' );
    }
};

done_testing();

#!/usr/bin/perl
# SM1354 (ruling 155): COPY A PAGE, CHANGE THE COPY, PUBLISH IT OVER THE PAGE.
#
# copy_page writes a private copy at lazysite/copies/pages/<page>; it is changed
# with write_file like any page and previewed with preview_page at its path,
# rendered as the page would be; publish_copy puts it over the page as one
# recorded version naming the publisher and the door, refused when the page
# changed after the copy was taken (both versions named); restore_version of
# the version the answer names undoes it; discard_copy leaves no trace in the
# page's history. Publishing needs publish_copies as well as manage_content.
# Only those who may change the page reach its copy, and the copies folder takes
# no file but an open copy's.
#
# With the change reverted the tools do not exist, the copy path is a blocked
# engine path, and every subtest below fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir grant_caps run_child run_cmd);
use Lazysite::Git ();

plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mcp   = "$root/lazysite-mcp.pl";

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $f, '<', "$d/$_[0]" or return undef; local $/; my $t = <$f>; close $f; $t }
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\ngit_history: enabled\n" );
put( 'lazysite/auth/groups-settings.json', '{"admins":{"label":"Admins","ui":1,"manage_users":1}}' );
put( 'content/page.md', "---\ntitle: Page\n---\n\nThe original text.\n" );
put( 'content/other.md', "---\ntitle: Other\n---\n\nOther text.\n" );
Lazysite::Git::reset_cache();
my $init = Lazysite::Git::init( $d, 'test' );
ok( $init->{ok}, 'content history initialised' ) or diag explain $init;

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}
sub mcp_call {
    my ( $auth, $name, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{HTTP_AUTHORIZATION}  = $auth;
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $r && $r->{result} ? $r->{result}{structuredContent}
        : { ok => 0, error => ( $r && $r->{error} ? $r->{error}{message} : 'no answer' ) };
}
sub history {
    my ($rel) = @_;
    my ( undef, $out ) = Lazysite::Git::run_git( $d, 'log', '--format=%s', '--', $rel );
    return [ grep { length } split /\n/, ( $out // '' ) ];
}

for my $u (qw(agent reader)) {
    uapi( { action => 'add', username => $u, password => 'x-long-enough-pw' } );
    uapi( { action => 'settings-set', username => $u, key => 'ui', value => 'off' } );
}
grant_caps( $d, 'agent',  'mcp', 'manage_content' );
grant_caps( $d, 'reader', 'mcp', 'manage_content' );
my $agent  = 'Bearer agent:' . uapi( { action => 'token', username => 'agent' } )->{token};
my $reader = 'Bearer reader:' . uapi( { action => 'token', username => 'reader' } )->{token};
my $copy   = 'lazysite/copies/pages/content/page.md';

subtest 'copy_page takes one private copy, and a second is refused' => sub {
    my $r = mcp_call( $agent, 'copy_page', { path => '/content/page.md' } );
    ok( $r->{ok}, 'copied' ) or diag explain $r;
    is( $r->{copy}, $copy, 'the copy path is named' );
    like( $r->{taken_from}{digest} // '', qr/\Asha256:[0-9a-f]{64}\z/, 'with the page version it was taken from' );
    like( $r->{taken_from}{history_version} // '', qr/\A[0-9a-f]{40}\z/, '...and its history version' );
    is( slurp($copy), slurp('content/page.md'), 'the copy is the page' );
    my $again = mcp_call( $agent, 'copy_page', { path => '/content/page.md' } );
    ok( !$again->{ok}, 'a second open copy is refused' );
    is( $again->{kind}, 'copy-open', '...as copy-open' ) or diag explain $again;
};

subtest 'the copy is changed like any page, and the page is not' => sub {
    my $w = mcp_call( $agent, 'write_file',
        { path => "/$copy", content => "---\ntitle: Page\n---\n\nThe CHANGED text.\n" } );
    ok( $w->{ok}, 'write_file on the copy' ) or diag explain $w;
    like( mcp_call( $agent, 'read_file', { path => "/$copy" } )->{content} // '', qr/CHANGED/, 'read back' );
    like( slurp('content/page.md'), qr/original text/, 'the page is untouched' );
    is( scalar @{ history('lazysite/copies') }, 0, 'and no copy reached content history' );
};

subtest 'preview_page renders the copy as the page would be' => sub {
    my $p = mcp_call( $agent, 'preview_page', { path => "/$copy" } );
    ok( $p->{ok}, 'rendered' ) or diag explain $p;
    like( $p->{html} // '', qr/CHANGED/, 'the copy\'s text' );
    is( $p->{path}, '/content/page.md', 'at the page\'s path' );
};

subtest 'publishing needs publish_copies, and manage_content beside it' => sub {
    my $no = mcp_call( $agent, 'publish_copy', { path => '/content/page.md' } );
    ok( !$no->{ok}, 'refused without publish_copies' );
    like( $no->{error} // '', qr/publish_copies/, '...naming it' );
    grant_caps( $d, 'agent', 'mcp', 'publish_copies' );
    TestHelper::revoke_caps( $d, 'agent', 'manage_content' );
    my $half = mcp_call( $agent, 'publish_copy', { path => '/content/page.md' } );
    ok( !$half->{ok}, 'refused with publish_copies alone' ) or diag explain $half;
    like( slurp('content/page.md'), qr/original text/, 'the page is untouched' );
    grant_caps( $d, 'agent', 'mcp', 'manage_content', 'publish_copies' );
};

subtest 'a copy of a page that changed since is not published, and both are named' => sub {
    my $c = mcp_call( $agent, 'copy_page', { path => '/content/other.md' } );
    ok( $c->{ok}, 'copied other.md' ) or diag explain $c;
    mcp_call( $agent, 'write_file', { path => '/content/other.md', content => "---\ntitle: Other\n---\n\nSomeone else's edit.\n" } );
    my $r = mcp_call( $agent, 'publish_copy', { path => '/content/other.md' } );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'stale-copy', '...as stale-copy' ) or diag explain $r;
    ok( $r->{taken_from}{digest} && $r->{current}{digest} && $r->{taken_from}{digest} ne $r->{current}{digest},
        'both versions are named, and differ' );
    like( slurp('content/other.md'), qr/Someone else/, 'the newer page stands' );
};

subtest 'discard_copy leaves no trace in the page\'s history' => sub {
    my $before = history('content/other.md');
    my $r = mcp_call( $agent, 'discard_copy', { path => '/content/other.md' } );
    ok( $r->{ok}, 'discarded' ) or diag explain $r;
    ok( !-e "$d/lazysite/copies/pages/content/other.md", 'the copy is gone' );
    is_deeply( history('content/other.md'), $before, 'the page\'s history is as it was' );
};

my $undo;
subtest 'publish_copy puts the copy over the page as one recorded change' => sub {
    my $before = history('content/page.md');
    my $r = mcp_call( $agent, 'publish_copy', { path => '/content/page.md', via => 'wizard' } );
    ok( $r->{ok}, 'published' ) or diag explain $r;
    like( slurp('content/page.md'), qr/CHANGED/, 'the page carries the copy\'s text' );
    ok( !-e "$d/$copy", 'the copy is closed' );
    my $after = history('content/page.md');
    is( scalar @$after, scalar(@$before) + 1, 'one new version' );
    like( $after->[0], qr/publish content\/page\.md from its copy - by agent \(agent via wizard\)/,
        'naming the publisher and where the change came from' );
    is( $r->{from}, 'agent via wizard', 'the answer says so too' );
    $undo = $r->{undo};
    ok( $undo && $undo->{version}, 'Undo is offered' ) or diag explain $r;
};

subtest 'undo restores the previous version through content history' => sub {
    my $r = mcp_call( $agent, 'restore_version', { path => '/content/page.md', version => $undo->{version} } );
    ok( $r->{ok}, 'restored' ) or diag explain $r;
    like( slurp('content/page.md'), qr/original text/, 'the page is as it was' );
};

subtest 'only an open copy is written in the copies folder' => sub {
    my $w = mcp_call( $agent, 'write_file', { path => "/$copy", content => "x\n" } );
    ok( !$w->{ok}, 'a save with no open copy is refused' );
    is( $w->{kind}, 'no-copy', '...as no-copy' ) or diag explain $w;
    ok( !-e "$d/$copy", 'nothing was written' );
    ok( mcp_call( $agent, 'copy_page', { path => '/content/page.md' } )->{ok}, 'a fresh copy' );
    ok( !mcp_call( $agent, 'delete_file', { path => "/$copy" } )->{ok}, 'delete_file of a copy is refused' );
    ok( !mcp_call( $agent, 'move_file', { from => "/$copy", to => '/content/moved.md' } )->{ok},
        'move_file out of the folder is refused' );
    ok( !-e "$d/content/moved.md", '...and nothing moved' );
};

subtest 'only those who may change the page reach its copy' => sub {
    my $acl = mcp_call( $agent, 'set_permissions', { path => '/content/page.md', write => ['agent'] } );
    ok( $acl->{ok}, 'the page is writable by agent alone' ) or diag explain $acl;
    my $rd = mcp_call( $reader, 'read_file', { path => "/$copy" } );
    ok( !$rd->{ok}, 'another manage_content holder cannot read the copy' ) or diag explain $rd;
    ok( !mcp_call( $reader, 'copy_page', { path => '/content/page.md' } )->{ok}, 'nor take one' );
    ok( !mcp_call( $reader, 'discard_copy', { path => '/content/page.md' } )->{ok}, 'nor discard it' );
    ok( mcp_call( $agent, 'read_file', { path => "/$copy" } )->{ok}, 'the page\'s writer can' );
};

done_testing();

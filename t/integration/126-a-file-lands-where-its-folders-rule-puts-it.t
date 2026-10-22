#!/usr/bin/perl
# SM981 (ruled 2026-10-11, "Land where save would"): a file written into a folder
# whose rule relocates content (a read list, or draft) lands in the private
# store - by save, move, copy, upload, MCP and WebDAV alike - and `acl reapply`
# repairs a folder that is in both trees.
#
# Reported from a local 0.15.3 site: a post moved into a draft folder with
# `move?path=/post/NAME.md&to=/drafts/USER--NAME.md` landed in the PUBLIC docroot
# and an anonymous request for it answered 200 with its text; `save` to the same
# folder went to the private store. `acl reapply --apply` refused to repair it:
# "the private store already holds this path".
#
# Measured on main (tmp/probe3.pl, .main.out): a move of a file WITHOUT a rule of
# its own lands privately. A file CARRYING one - an owner-only rule, which every
# copy gets and a move re-keys - was moved back OUT of the store, because the
# movers judged placement by the moved path's own rule (Files::_sync_private_store,
# DAV _sync_acl_store) and an owner-only rule "does not gate". In a draft folder
# with no read list the processor then served it to anyone: the owner-only entry
# also hid the folder's draft flag (_acl_is_draft asked for the nearest entry of
# any kind). And once the stray had recreated the folder in the docroot, every
# later save into it went public too ("a public ancestor settles it").
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root env_passthrough run_child);
use ManagerSession    qw(new_site);
use Lazysite::Private ();

my $root = repo_root();
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nwebdav_enabled: true\nmcp_enabled: true\n" );
my $d    = $s->docroot;
my $priv = Lazysite::Private::private_root($d);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; return $t }
sub where {
    my ($rel) = @_;
    return join '+', ( -e "$d/$rel" ? 'public' : () ), ( -e "$priv/$rel" ? 'private' : () );
}
sub anon {
    my ($uri) = @_;
    my $out = TestHelper::run_processor( $d, $uri, HTTP_X_REMOTE_USER => undef,
        HTTP_X_REMOTE_GROUPS => undef, LAZYSITE_AUTH_TRUSTED => undef, HTTP_COOKIE => undef );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, ( $out =~ /POST-TEXT/ ? 1 : 0 ) );
}
sub acl {
    my $cmd = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-acl.pl", @_, '--docroot', $d;
    my $out = qx($cmd 2>&1);
    return wantarray ? ( $? >> 8, $out ) : $? >> 8;
}

my @ALL = qw(ui manage_content webdav api mcp);
$s->add_user('ann');
$s->grant( 'ann', 'authors', [qw(ui manage_content)], \@ALL );
$s->add_user('dav');
$s->grant( 'dav', 'publishers', [qw(webdav manage_content)], \@ALL );

make_path( "$d/post", "$d/drafts", "$d/members", "$d/held" );
spit( "$d/drafts/old.md", "---\ntitle: Old\n---\nold\n" );
spit( "$d/members/m.md",  "---\ntitle: M\n---\nm\n" );
spit( "$d/held/h.md",     "---\ntitle: H\n---\nh\n" );
spit( "$d/post/$_.md",    "---\ntitle: $_\n---\nPOST-TEXT $_\n" ) for qw(a b c d e f g);
is( acl( 'set', 'drafts', '--actor', 'local', '--read', '@authors', '--write', '@authors', '--draft' ), 0,
    'the canary: a draft folder with a read list (the reported rule)' );
is( acl( 'set', 'members', '--actor', 'local', '--read', '@authors', '--write', '@authors' ), 0,
    'a read-list folder' );
is( acl( 'set', 'held', '--actor', 'local', '--draft' ), 0, 'a draft-only folder' );
ok( !-e "$d/drafts" && -e "$priv/drafts/old.md", 'the canary: setting them moved the content out' );
# Each post carries a rule of its own - an owner-only one, as every copy gets.
is( acl( 'set', "post/$_.md", '--actor', 'local', '--owner', 'ann', '--write', 'ann' ), 0,
    "post/$_.md carries an owner-only rule" ) for qw(a b c d e);

my %g = ( groups => 1 );

subtest 'the reported case: a move into a draft folder lands where save would' => sub {
    my $r = $s->call( 'ann', 'move', %g, query => 'action=move&path=post/a.md&to=drafts/ann--a.md', body => {} );
    ok( $r->{ok}, 'the move succeeds' ) or diag( explain $r );
    is( where('drafts/ann--a.md'), 'private', 'into the private store' );
    my ( $st, $body ) = anon('/drafts/ann--a');
    is( $st, 404, 'a visitor with no session gets 404' );
    ok( !$body,          'and none of the text' );
    ok( !-e "$d/drafts", 'and the folder is not recreated in the docroot' );

    $r = $s->call( 'ann', 'save', %g, query => 'action=save&path=drafts/saved.md',
        body => { content => "---\ntitle: S\n---\nPOST-TEXT saved\n" } );
    is( where('drafts/saved.md'), 'private', 'the canary: save lands there too' );
};

subtest 'and so does every other way a file arrives' => sub {
    my $r = $s->call( 'ann', 'move', %g, query => 'action=move&path=post/b.md&to=members/b.md', body => {} );
    is( where('members/b.md'), 'private', 'a move into a read-list folder' ) or diag( explain $r );
    is( ( anon('/members/b') )[1], 0, 'which serves none of it anonymously' );
    $r = $s->call( 'ann', 'copy', %g, query => 'action=copy&path=post/f.md&to=drafts/f.md', body => {} );
    is( where('drafts/f.md'), 'private', 'a copy' ) or diag( explain $r );
    $r = $s->call( 'ann', 'move', %g, query => 'action=move&path=drafts/f.md&to=drafts/f2.md', body => {} );
    is( where('drafts/f2.md'), 'private', 'a rename inside the folder of a copy (which has its own rule)' )
        or diag( explain $r );
    my $B = 'XyZb0undary';
    my $mp = "--$B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"up.md\"\r\n"
        . "Content-Type: text/markdown\r\n\r\n---\ntitle: U\n---\nPOST-TEXT up\n\r\n--$B--\r\n";
    $r = $s->call( 'ann', 'file-upload', %g, query => 'action=file-upload&path=drafts', raw => $mp,
        content_type => "multipart/form-data; boundary=$B" );
    is( where('drafts/up.md'), 'private', 'an upload' ) or diag( explain $r );
};

subtest 'a draft folder with no read list hides a file that has a rule of its own' => sub {
    my $r = $s->call( 'ann', 'move', %g, query => 'action=move&path=post/c.md&to=held/c.md', body => {} );
    is( where('held/c.md'), 'private', 'the move lands privately' ) or diag( explain $r );
    my ( $st, $body ) = anon('/held/c');
    is( $st, 404, 'and the public gets 404, not the page' );
    ok( !$body, 'with none of its text' );
    # The processor half alone: a file already in the store, carrying an owner-only rule.
    make_path("$priv/held");
    spit( "$priv/held/owned.md", "---\ntitle: O\n---\nPOST-TEXT owned\n" );
    acl( 'set', 'held/owned.md', '--actor', 'local', '--owner', 'ann', '--write', 'ann' );
    ( $st, $body ) = anon('/held/owned');
    is( $st, 404, 'its own owner-only rule does not hide the folder\'s draft flag' );
    ok( !$body, 'no text' );
};

subtest 'a file\'s own rule changing inside a held-back folder keeps it there' => sub {
    my ( $rc, $out ) = acl( 'set', 'drafts/ann--a.md', '--actor', 'local', '--write', 'ann,@authors' );
    is( $rc, 0, 'a write-only rule on a file inside the draft folder is set' ) or diag($out);
    is( where('drafts/ann--a.md'), 'private', 'and the file stays in the store' );
    ( $rc, $out ) = acl( 'remove', 'drafts/ann--a.md', '--actor', 'local' );
    is( where('drafts/ann--a.md'), 'private', 'removing the file\'s own rule leaves it in the store' )
        or diag($out);
    is( ( anon('/drafts/ann--a') )[0], 404, 'still 404 to the public' );
};

# --- MCP ----------------------------------------------------------------------
my $stub = "$d/../users-stub.pl";
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
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

subtest 'MCP move_file, copy_file and upload_file land there too' => sub {
    $s->add_user('tester');    # the partner the stub vouches for, so a rule may name it
    acl( 'set', 'post/d.md', '--actor', 'local', '--owner', 'tester', '--write', 'tester' );
    my $r = mcp( 'move_file', { from => '/post/d.md', to => '/held/d.md' } );
    ok( $r->{ok}, 'move_file' ) or diag( explain $r );
    is( where('held/d.md'), 'private', 'a moved file with its own rule lands privately' );
    is( ( anon('/held/d') )[0], 404,   'and is 404 to the public' );
    $r = mcp( 'copy_file', { from => '/post/g.md', to => '/held/g.md' } );
    is( where('held/g.md'), 'private', 'copy_file' ) or diag( explain $r );
    $r = mcp( 'upload_file', { path => '/held/u.md', content_base64 => encode_base64( "---\ntitle: U\n---\nPOST-TEXT u\n", '' ) } );
    is( where('held/u.md'), 'private', 'upload_file' ) or diag( explain $r );
};

# --- WebDAV -------------------------------------------------------------------
sub dav {
    my ( $method, $path, %o ) = @_;
    return TestHelper::run_dav( $d, $method, $path,
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( 'dav:pw123456789-long-enough', '' ), %o );
}

subtest 'WebDAV MOVE, COPY and PUT land there too' => sub {
    acl( 'set', 'post/e.md', '--actor', 'local', '--owner', 'dav', '--write', 'dav' );
    my $r = dav( 'MOVE', '/post/e.md', HTTP_DESTINATION => '/dav/held/e.md' );
    like( $r->{code} // '', qr/\A20[14]\z/, 'MOVE' ) or diag( $r->{raw} . $r->{stderr} );
    is( where('held/e.md'), 'private', 'a moved file with its own rule lands privately' );
    is( ( anon('/held/e') )[0], 404,   'and is 404 to the public' );
    $r = dav( 'COPY', '/post/g.md', HTTP_DESTINATION => '/dav/held/g2.md' );
    is( where('held/g2.md'), 'private', 'COPY' ) or diag( $r->{raw} );
    $r = dav( 'PUT', '/held/put.md', body => "---\ntitle: P\n---\nPOST-TEXT put\n" );
    is( where('held/put.md'), 'private', 'PUT' ) or diag( $r->{raw} );
};

subtest 'a stray public copy of the folder: writes still land privately, and reapply repairs it' => sub {
    # What a front-end upload (or the defect above) leaves: the folder recreated
    # in the docroot, one file the store lacks and one it already holds.
    make_path("$d/drafts");
    spit( "$d/drafts/stray.md", "---\ntitle: Stray\n---\nPOST-TEXT stray\n" );
    spit( "$d/drafts/old.md",   "---\ntitle: Old\n---\nPOST-TEXT the public twin\n" );
    my $r = $s->call( 'ann', 'save', %g, query => 'action=save&path=drafts/after.md',
        body => { content => "---\ntitle: A\n---\nPOST-TEXT after\n" } );
    is( where('drafts/after.md'), 'private', 'a save into the folder still lands privately' ) or diag( explain $r );
    my ( $rc, $out ) = acl( 'reapply', '--actor', 'local', '--apply' );
    is( $rc, 0, 'acl reapply --apply succeeds' ) or diag($out);
    unlike( $out, qr/already holds this path/, 'where it used to refuse' );
    like( $out, qr/drafts\/old\.md.*private store's copy is kept/s, 'saying which copy was kept' );
    is( where('drafts/stray.md'), 'private', 'the file the store lacked moved in' );
    is( slurp("$priv/drafts/old.md"), "---\ntitle: Old\n---\nold\n", 'the store\'s copy of the twin is kept' );
    ok( !-e "$d/drafts", 'nothing of the folder is left in the docroot' );
    my ($kept) = glob("$d/lazysite/displaced/*/drafts/old.md");
    ok( $kept && slurp($kept) =~ /the public twin/, 'the public twin is kept as a recoverable backup' )
        or diag("out: $out");
    like( $out, qr/\Q$kept\E/, 'and the reply names where' ) if $kept;
    is( ( anon('/drafts/stray') )[0], 404, 'the repaired file is 404 to the public' );
};

done_testing();

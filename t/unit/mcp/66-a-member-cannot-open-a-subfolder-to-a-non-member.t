#!/usr/bin/perl
# SM1309 (ruling 46, T-02): A RULE INSIDE ANOTHER MAY NARROW IT; ONLY THE
# OPERATOR OR THE ENCLOSING RULE'S OWNER MAY WIDEN IT.
#
# A mode's list is decided by the longest match, so a subfolder's rule replaces
# its parent's rather than narrowing it, and anyone who may write a path may
# create its first rule. A member's agent opened a subfolder of a protected area
# to a non-member with one set_permissions call, and the non-member then read
# the page. Longest match stays, so an operator's carve-out still works; who may
# write one is what changes, on every surface that writes a rule: MCP
# set_permissions, `lazysite acl set`, and a move that carries a rule inside.
#
# With the fix reverted, the member's subfolder rule, its write-list twin, its
# widening of an existing carve-out, the CLI write as the member and the move are
# all accepted, and the non-member reads the page. The narrowing rule, the
# existing carve-out, the owner's and the operator's writes are the controls.
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
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
sub put {
    my ( $rel, $text ) = @_;
    my ($dir) = "$d/$rel" =~ m{\A(.*)/[^/]+\z};
    make_path($dir);
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub tool {
    my ( $script, @args ) = @_;
    my $r = run_child( [ $^X, "$root/tools/$script", '--docroot', $d, @args ] );
    return ( $r->{out} // '' ) . ( $r->{err} // '' );
}
# `lazysite acl VERB ...`: the verb comes first, as the CLI reads it.
sub acl {
    my ( $verb, @args ) = @_;
    my $r = run_child( [ $^X, "$root/tools/lazysite-acl.pl", $verb, '--docroot', $d, @args ] );
    return $r->{out} // '';
}
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );

# Accounts and the area's group through the users tool, so the stores are the
# ones the engine reads. A group granting `ui` makes this a SECURED site: on an
# unsecured one every account is the operator and nothing here is asked.
tool( 'lazysite-users.pl', 'add', $_, 'pw-long-enough-123' ) for qw(boss memberai outsider outsider2);
tool( 'lazysite-users.pl', 'group-add', 'memberai', 'intranet' );
tool( 'lazysite-users.pl', 'group-add', 'boss',     'staff' );
tool( 'lazysite-users.pl', 'group-set', 'staff', 'ui', 'on' );

put( 'content/intranet/index.md', "---\ntitle: Area\n---\nArea.\n" );
put( 'content/intranet/sub/p.md', "---\ntitle: P\n---\nPAGE-P\n" );
put( 'content/intranet/carve/q.md', "---\ntitle: Q\n---\nPAGE-Q\n" );
put( 'content/loose/x.md',        "---\ntitle: X\n---\nPAGE-X\n" );

# The protected area, and a carve-out inside it that already admits a non-member
# (written before this check, as a site upgrading has them).
sub acls {
    open my $f, '<', "$d/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = <$f>;
    close $f;
    return eval { decode_json($j) } || {};
}
put( 'lazysite/auth/acls.json', encode_json( {
    'content/intranet'       => { owner => 'boss', read => ['@intranet'], write => ['@intranet'] },
    'content/intranet/carve' => { owner => 'memberai', read => [ '@intranet', 'outsider' ] },
} ) );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
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
sub call { sc( mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call', params => { name => $_[0], arguments => $_[1] || {} } }, "Bearer $_[2]:lzs_tok" ) ) }
sub sc   { my $r = shift; $r && $r->{result} ? $r->{result}{structuredContent} : undef }

subtest 'a member\'s agent cannot open a subfolder to a non-member' => sub {
    my $before = acls();
    my $r = call( 'set_permissions', { path => '/content/intranet/sub', read => 'outsider' }, 'memberai' );
    ok( $r && !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind} // '', 'widens-enclosing-rule', 'as a rule widening the one around it' );
    like( $r->{error} // '', qr{the rule on 'content/intranet'}, 'and the refusal names the enclosing rule' );
    is_deeply( acls(), $before, 'nothing was written' );
    my $read = call( 'read_file', { path => '/content/intranet/sub/p.md' }, 'outsider' );
    ok( $read && !$read->{ok}, 'and the non-member still cannot read the page' );

    my $w = call( 'set_permissions', { path => '/content/intranet/sub', write => 'outsider' }, 'memberai' );
    ok( $w && !$w->{ok}, 'a write list admitting the non-member is refused too' );
    is( $w->{field} // '', 'write', '...naming the write list' );
};

subtest 'a narrowing rule is still the writer\'s to make' => sub {
    my $r = call( 'set_permissions', { path => '/content/intranet/sub', read => 'memberai' }, 'memberai' );
    ok( $r && $r->{ok}, 'a member narrows a subfolder to itself' ) or diag explain $r;
    ok( acls()->{'content/intranet/sub'}, 'and the rule is stored' );
    my $rm = call( 'remove_permissions', { path => '/content/intranet/sub' }, 'memberai' );
    ok( $rm && $rm->{ok}, '(and takes it off again)' );
};

subtest 'an existing carve-out keeps working' => sub {
    my $read = call( 'read_file', { path => '/content/intranet/carve/q.md' }, 'outsider' );
    ok( $read && $read->{ok}, 'the non-member it names reads the page' ) or diag explain $read;
    my $again = call( 'set_permissions', { path => '/content/intranet/carve', read => '@intranet,outsider' }, 'memberai' );
    ok( $again && $again->{ok}, 'its owner re-applies it unchanged' ) or diag explain $again;
    my $more = call( 'set_permissions', { path => '/content/intranet/carve', read => '@intranet,outsider,outsider2' }, 'memberai' );
    ok( $more && !$more->{ok}, 'but may not widen it further' );
    is_deeply( acls()->{'content/intranet/carve'}{read}, [ '@intranet', 'outsider' ], 'which left it as it was' );
};

subtest 'the enclosing rule\'s owner and the operator may write a carve-out' => sub {
    my $r = call( 'set_permissions', { path => '/content/intranet/sub', read => 'outsider' }, 'boss' );
    ok( $r && $r->{ok}, 'the owner of the enclosing rule writes one' ) or diag explain $r;
    call( 'remove_permissions', { path => '/content/intranet/sub' }, 'boss' );

    my $op = acl( 'set', '--actor', 'local', '--json', '/content/intranet/sub', '--read', 'outsider' );
    my $j  = eval { decode_json($op) } || {};
    ok( $j->{ok}, 'the operator writes one from the CLI' ) or diag $op;
    is_deeply( acls()->{'content/intranet/sub'}{read}, ['outsider'], 'and it is stored' );
    acl( 'remove', '--actor', 'local', '/content/intranet/sub' );
};

subtest 'the CLI refuses the member as MCP does' => sub {
    my $out = acl( 'set', '--actor', 'memberai', '--json', '/content/intranet/sub', '--read', 'outsider' );
    my $j   = eval { decode_json($out) } || {};
    ok( !$j->{ok}, 'refused' ) or diag $out;
    is( $j->{kind} // '', 'widens-enclosing-rule', 'by the same check' );
    ok( !acls()->{'content/intranet/sub'}, 'and nothing was written' );
};

subtest 'a wide rule cannot be moved inside the area' => sub {
    my $r = call( 'set_permissions', { path => '/content/loose/x.md', read => 'memberai,outsider' }, 'memberai' );
    ok( $r && $r->{ok}, 'a rule where nothing encloses it is written (control)' ) or diag explain $r;
    my $m = call( 'move_file', { from => '/content/loose/x.md', to => '/content/intranet/x.md' }, 'memberai' );
    ok( $m && !$m->{ok}, 'but moving it into the area is refused' ) or diag explain $m;
    is( $m->{kind} // '', 'widens-enclosing-rule', 'as a rule widening the one that would enclose it' );
    ok( acls()->{'content/loose/x.md'}, 'and the rule stays where it was' );
};

done_testing;

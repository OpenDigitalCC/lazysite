#!/usr/bin/perl
# SM278: two silent-success defects on the ACL path, found by the site agent
# re-testing 0.10.6 on edge.
#
#   1. action_acl_set built its record from owner/read/write alone, so `draft`
#      was accepted, reported ok, and dropped. SM181 shipped the ENGINE half of
#      draft (404 to the public, absent from every listing); the writer never
#      carried the field, so the setting could be made and had no effect.
#
#   2. The MCP tool table publishes "additionalProperties": false on all 51
#      tools and never enforced it, so ANY unsupported argument was silently
#      ignored - which is how (1) presented to the agent: ok:1, nothing set.
#
# Both are the same failure shape: the product reporting that it did something
# it did not do.
#
# Negative verification: with lazysite-mcp.pl and Files.pm stashed to their
# pre-fix state, 'draft is PERSISTED' and 'an update that omits draft' both
# fail (the stored ACL has owner/read/write only), and both MCP assertions
# fail (the unknown argument is accepted and returns a normal result).
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use IPC::Open3;
use IPC::Open2  qw(open2);
use Symbol      qw(gensym);
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $secret = 'sekret' x 6;
my $d      = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/upcoming" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nsite_url: http://localhost\nmcp_enabled: true\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sf} "$secret\n";
close $sf;
open my $ix, '>', "$d/upcoming/index.md" or die $!;
print {$ix} "# Upcoming\n";
close $ix;

# --- the manager API path ---------------------------------------------------

sub mapi {
    my (%o) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub aclset {
    my ( $path, $payload ) = @_;
    return mapi(
        REQUEST_METHOD       => 'POST',
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'manager',
        HTTP_X_CSRF_TOKEN =>
            hmac_sha256_hex( "csrf:op:" . int( time() / 3600 ), $secret ),
        QUERY_STRING => "action=acl-set&path=$path",
        body         => encode_json($payload),
    );
}

sub aclget {
    return mapi(
        REQUEST_METHOD       => 'GET',
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'manager',
        QUERY_STRING         => "action=acl-get&path=$_[0]",
    );
}

{
    my $set = aclset( '/upcoming/',
        { read => 'alice', write => 'alice', draft => JSON::PP::true } );
    ok( $set->{ok}, 'acl-set accepts a draft folder prefix' ) or diag encode_json($set);

    my $got = aclget('/upcoming/');
    ok( $got->{ok} && $got->{acl} && $got->{acl}{draft},
        'draft is PERSISTED, not dropped' )
        or diag encode_json($got);

    # Absent means "leave it alone" - an update to the read list must not
    # publish a held-back section by omission. This is the branch that turns a
    # nicety into a disclosure if it is wrong.
    aclset( '/upcoming/', { read => 'alice,bob', write => 'alice' } );
    my $after = aclget('/upcoming/');
    ok( $after->{ok} && $after->{acl}{draft},
        'an update that omits draft leaves the section held back' )
        or diag encode_json($after);

    # Publishing must be a deliberate act, and must actually clear the flag.
    aclset( '/upcoming/',
        { read => 'alice', write => 'alice', draft => JSON::PP::false } );
    my $pub = aclget('/upcoming/');
    ok( $pub->{ok} && !$pub->{acl}{draft}, 'draft:false publishes the section' )
        or diag encode_json($pub);
}

# --- the MCP path: the published schema is enforced -------------------------

my $stub = "$d/users-stub.pl";
open my $st, '>', $stub or die $!;
print $st <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
close $st;
chmod 0755, $stub;

sub call {
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $_[0], arguments => $_[1] } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

{
    my $r = call( 'read_page', { path => 'upcoming/index', typo_argument => 1 } );
    ok( $r && $r->{error}, 'an unsupported argument is REFUSED, not ignored' )
        or diag encode_json($r);
    like( ( $r->{error}{message} // '' ), qr/Unknown argument 'typo_argument'/,
        'the refusal names the offending argument' );
    like( ( $r->{error}{message} // '' ), qr/This tool accepts: /,
        'and lists what the tool does accept' );

    # draft is now a DECLARED property, so it must pass the schema gate rather
    # than be refused as unknown - the fix has to reach both halves. This
    # asserts the gate only: whether THIS agent may write THIS ACL is the
    # ownership question, tested above and in t/unit/manager/15.
    my $ok = call( 'set_permissions',
        { path => 'upcoming/', read => 'alice', draft => JSON::PP::true } );
    ok( $ok && !$ok->{error},
        'draft passes the schema gate over MCP (declared, not unknown)' )
        or diag encode_json($ok);
}

done_testing();

#!/usr/bin/perl
# SM268 01-M3: an ACL key that governs nothing looks exactly like one that
# governs something.
#
# Keys are DOCROOT-relative; a content-rooted domain's URLs are relative to its
# content_root. So on such a domain the intuitive key - the URL segment, which
# is exactly what SM181's example rule uses - is inert. It is syntactically
# valid, it appears in the store, and it protects nothing, and nothing said so
# until somebody tried the URL.
#
# The engine cannot silently reinterpret the key: the manager, MCP and WebDAV
# all write docroot-relative keys and are consistent with each other, and
# guessing would break them. So audit_site reports the symptom - a key matching
# no path - and names the key that WOULD work, because an operator who has just
# been told "this protects nothing" needs to know what to write instead.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_script);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/sites/foo/private", "$d/open" );

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

spit( "$d/lazysite/lazysite.conf", <<'CONF' );
site_name: T
mcp_enabled: true
alias_hosts: alias.example
alias.alias.example.content_root: sites/foo
CONF

spit( "$d/index.md",                    "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/open/free.md",                "---\ntitle: Free\n---\nFree.\n" );
spit( "$d/sites/foo/private/notes.pdf", 'PDFDATA' );
spit( "$d/sites/foo/private/index.md",  "---\ntitle: P\n---\nP.\n" );

# The mistake: the URL segment, as an operator on that domain would write it.
# Plus one key that is correct, so the check cannot pass by flagging everything.
spit( "$d/lazysite/auth/acls.json",
    encode_json( {
            'private'           => { read => ['@editors'] },
            'sites/foo/private' => { read => ['@editors'] },
            'open'              => { read => ['@editors'] },
    } ) );

my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
chmod 0755, $stub;

my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => 'audit_site', arguments => {} } } );
my $out = run_script(
    'lazysite-mcp.pl',
    stdin => $body,
    env   => {
        DOCUMENT_ROOT       => $d,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length($body),
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer partner:lzs_x',
    },
);
my ($jb)  = $out =~ /\r?\n\r?\n(.*)/s;
my $rsp   = eval { decode_json( $jb // '' ) } || {};
my $text  = $rsp->{result}{content}[0]{text} // $jb // '';
my $audit = eval { decode_json($text) } || {};

my %flagged = map { $_->{key} => $_ } @{ $audit->{acl_keys_matching_nothing} || [] };

ok( exists $flagged{'private'},
    'the URL-shaped key is reported - it governs nothing on this site' )
    or diag $text;

like( ( $flagged{'private'}{message} // '' ), qr{sites/foo/private},
    'and the message names the key that WOULD work, because "protects nothing" '
        . 'without a repair is half an answer' );

ok( !exists $flagged{'sites/foo/private'},
    'the correct docroot-relative key is not reported' );
ok( !exists $flagged{'open'},
    'nor a key on the primary site that matches a real folder - a check that '
        . 'flagged every key would pass the first assertion for the wrong reason' );

done_testing();

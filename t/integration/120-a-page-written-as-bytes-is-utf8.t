#!/usr/bin/perl
# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): a .md page arriving as
# raw bytes is written only when the bytes are valid UTF-8 - through every door
# that writes a caller's bytes, for every caller, with a refusal that says so
# and how to fix it.
#
# The finding was tmp/q15g-malformed-hijack-probe.pl: a grant scoped to one
# domain saved a page with one malformed byte in a front-matter key
# ("titre\xFF:"). The write rule, reading the bytes as UTF-8, saw no form; the
# processor, reading them through its lax :utf8 layer, rendered the primary's
# unbound form `orphan` on the page, and the form walker then handed `orphan`
# and its submissions to the grant. The first subtest is that probe, as
# assertions: refused now, nothing written, the form still unreached.
#
# The doors: MCP upload_file (action_save_binary), the multipart upload,
# WebDAV PUT, a site package's content (site-backup-apply, site_apply). Text
# writes (write_file, save) encode their characters, so they cannot carry such
# bytes. A file that is not a page (.txt) is not this rule's.
#
# Callers: op, the cookie operator; cks, a cookie manager scoped to sites/mine;
# mcs, an MCP grant scoped there; dvs, a WebDAV account scoped there.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_dav);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR}           = "$root/lazysite-processor.pl";
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

my @WORK = qw(manage_content manage_forms read_submissions manage_domains);
my @ALL  = ( qw(api ui mcp webdav manage_users manage_config), @WORK );
my %CHAN = ( cks => 'ui', mcs => 'mcp', dvs => 'webdav' );

sub spit { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return scalar <$fh> }

# The probe's bytes: one malformed byte in a key, and the primary's form.
my $BAD  = "---\ntitre\xFF:\nform: orphan\n---\n\n:::form\nemail | Email\n:::\n";
my $GOOD = "---\ntitle: Caf\xC3\xA9\n---\n\nValid UTF-8, with an accent.\n";

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nwebdav_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/lazysite/forms/submissions" );
spit( "$d/sites/mine/index.md", "# mine\n" );
spit( "$d/index.md",            "# primary\n" );
spit( "$d/lazysite/forms/orphan.conf", "targets:\n" ); # registered, bound on no page: the primary's
spit( "$d/lazysite/forms/submissions/orphan.jsonl", encode_json( { email => 'v@example.org' } ) . "\n" );

$s->add_user('op');
$s->grant( 'op', 'g-op', [ qw(ui manage_users manage_config), @WORK ], \@ALL );
for my $u ( sort keys %CHAN ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", [ $CHAN{$u}, @WORK ], \@ALL );
}
sub op { my ( $a, $b ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ) ) }
ok( op( 'domain-add', { host => 'mine.example.org', content_root => 'sites/mine' } )->{ok}, 'set up: mine.example.org' );
ok( op( 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks, g-mcs, g-dvs' } )->{ok},
    'set up: the scoped callers are confined to it' );
my $CONF = slurp("$d/lazysite/lazysite.conf");

sub uapi {
    my ($p) = @_;
    my $pid = open2( my $o, my $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = ( mcs => uapi( { action => 'token', username => 'mcs' } )->{token} // '' );

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $pid = open2( my $out, my $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

# The multipart upload, as the cookie manager (ManagerSession stands in for the
# auth wrapper); the per-file refusal is the answer.
sub upload {
    my ( $who, $dir, $name, $bytes ) = @_;
    my $b = 'XXq15hXX';
    my $raw = "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$name\"\r\n"
        . "Content-Type: application/octet-stream\r\n\r\n$bytes\r\n--$b--\r\n";
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION CONTENT_TYPE)};
    $ENV{HTTP_X_REMOTE_USER}    = $who;
    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
    $ENV{LAZYSITE_USERS_TOOL}   = $s->users;
    $ENV{HTTP_COOKIE}           = $s->cookie_for($who);
    $ENV{HTTP_X_CSRF_TOKEN}     = $s->csrf_for($who);
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{QUERY_STRING}          = "action=file-upload&path=$dir";
    $ENV{REQUEST_METHOD}        = 'POST';
    $ENV{CONTENT_LENGTH}        = length $raw;
    $ENV{CONTENT_TYPE}          = "multipart/form-data; boundary=$b";
    my $e   = gensym;
    my $pid = open3( my $w, my $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} $raw;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $j    = eval { decode_json( $jb // '' ) } // { _raw => $out };
    my $err  = ref $j->{errors} eq 'ARRAY' && @{ $j->{errors} } ? $j->{errors}[0] : undef;
    return $err ? { ok => 0, error => $err->{error}, kind => $err->{kind} } : $j;
}

sub dav {
    my ( $who, $rel, $bytes ) = @_;
    my $r = run_dav( $d, 'PUT', "/$rel",
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( "$who:pw-$who-0123456789", '' ), body => $bytes );
    return { ok => ( ( $r->{code} // '' ) =~ /^20[14]$/ ? 1 : 0 ), code => $r->{code}, error => $r->{body} // '' };
}

# A refusal of this rule: names UTF-8 and the way to fix it, nothing written.
sub refused_as_not_utf8 {
    my ( $what, $r, $file ) = @_;
    ok( !$r->{ok}, "$what: refused" ) or diag explain $r;
    like( $r->{error} // '', qr/is not valid UTF-8/, "$what: the refusal says the page is not UTF-8" );
    like( $r->{error} // '', qr/save the file as UTF-8/, "$what: and how to fix it" );
    ok( !-e "$d/$file", "$what: nothing was written" );
    return;
}

subtest 'the Q15g hijack probe, refused now' => sub {
    my $r = mcp( 'mcs', 'upload_file', { path => 'sites/mine/hook.md', content_base64 => encode_base64( $BAD, '' ) } );
    refused_as_not_utf8( 'mcs upload_file of the bytes', $r, 'sites/mine/hook.md' );
    is( $r->{kind}, 'page-encoding-refused', 'by this rule, with its kind' );
    my $sub = mcp( 'mcs', 'read_form_submissions', { form => 'orphan' } );
    ok( !$sub->{ok}, 'and the grant still does not reach orphan or its submissions' ) or diag explain $sub;
    my $r2 = mcp( 'mcs', 'upload_file', { path => 'sites/mine/good.md', content_base64 => encode_base64( $GOOD, '' ) } );
    ok( $r2->{ok}, 'a page that is valid UTF-8 is written' ) or diag explain $r2;
    is( slurp("$d/sites/mine/good.md"), $GOOD, '...byte for byte' );
};

subtest 'every caller, not only a confined one' => sub {
    local $ENV{LAZYSITE_USERS_TOOL};
    my $r = upload( 'op', '', 'op-bad.md', $BAD );
    refused_as_not_utf8( 'the operator\'s multipart upload', $r, 'op-bad.md' );
};

subtest 'the multipart upload' => sub {
    refused_as_not_utf8( 'cks upload of the bytes', upload( 'cks', 'sites/mine', 'up-bad.md', $BAD ), 'sites/mine/up-bad.md' );
    my $ok = upload( 'cks', 'sites/mine', 'up-good.md', $GOOD );
    ok( $ok->{ok} && -e "$d/sites/mine/up-good.md", 'cks uploads a page that is valid UTF-8' ) or diag explain $ok;
    my $txt = upload( 'cks', 'sites/mine', 'notes.txt', "latin-1 \xE9\n" );
    ok( $txt->{ok} && -e "$d/sites/mine/notes.txt", 'a file that is not a page is not this rule\'s' ) or diag explain $txt;
};

subtest 'WebDAV PUT' => sub {
    my $r = dav( 'dvs', 'sites/mine/dav-bad.md', $BAD );
    refused_as_not_utf8( 'dvs PUT of the bytes', $r, 'sites/mine/dav-bad.md' );
    is( $r->{code}, 415, '...as 415: the request was well formed, its content cannot be served' );
    my $ok = dav( 'dvs', 'sites/mine/dav-good.md', $GOOD );
    ok( $ok->{ok}, 'dvs PUTs a page that is valid UTF-8' ) or diag explain $ok;
    is( slurp("$d/sites/mine/dav-good.md"), $GOOD, '...byte for byte' );
};

subtest 'a site package carrying such a page' => sub {
    spit( "$d/sites/mine/pkg-bad.md", $BAD ); # put there by a door that is not a manager's (git, SSH)
    my $pkg = op( 'site-backup-create', { host => 'mine.example.org' } )->{name} // '';
    like( $pkg, qr/\Alazysite-site-/, 'set up: a package of mine carrying the page' );
    unlink "$d/sites/mine/pkg-bad.md";
    my $r = op( 'site-backup-apply', { name => $pkg, host => 'mine.example.org' } );
    spit( "$d/lazysite/lazysite.conf", $CONF );
    refused_as_not_utf8( 'the operator\'s site-backup-apply', $r, 'sites/mine/pkg-bad.md' );
    my $m = mcp( 'mcs', 'site_apply', { name => $pkg, host => 'mine.example.org' } );
    spit( "$d/lazysite/lazysite.conf", $CONF );
    refused_as_not_utf8( 'mcs site_apply of it', $m, 'sites/mine/pkg-bad.md' );
};

done_testing();

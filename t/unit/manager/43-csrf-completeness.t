#!/usr/bin/perl
# ADVERSARIAL (breadth pass 2026-07): CSRF completeness on the cookie (manager
# UI) channel. The gate is METHOD-KEYED - every POST from a cookie session must
# carry a valid CSRF token (an action-name allowlist could silently omit a new
# write; keying on the method cannot). %MUTATING is the companion guard: it
# forces every state-changing action to be POST, so it can never be reached via a
# CSRF-free GET. This test proves both behaviourally: a POST without a token is
# refused for every write action tried, a valid token clears the gate, and the
# state-changing actions cannot be driven over GET.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# Drive the manager-API. $csrf: 'valid' | 'none'. $method defaults to POST.
sub call {
    my ( $d, $action, %o ) = @_;
    my $csrf   = delete $o{csrf}   // 'valid';
    my $method = delete $o{method} // 'POST';
    my $body   = delete $o{body}   // '{}';
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = $method;
    $ENV{QUERY_STRING}          = "action=$action" . ( $o{qs} ? "&$o{qs}" : '' );
    $ENV{CONTENT_LENGTH}        = length $body;
    $ENV{HTTP_X_REMOTE_USER}    = 'admin';
    $ENV{HTTP_X_REMOTE_GROUPS}  = 'managers';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:admin:" . int( time() / 3600 ), $secret )
        if $csrf eq 'valid';
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w $body;
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\nmanager: enabled\nmanager_groups: managers\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;
uapi( $d, { action => 'add', username => 'admin', password => 'x' } );
grant_caps( $d, 'admin', 'manage_users' );
open my $pg, '>', "$d/page.md" or die $!;
print $pg "x\n";
close $pg;

# A broad, category-spanning set of state-changing actions.
my @writes = qw(
    save delete mkdir move copy config-set domain-add domain-set domain-remove
    theme-activate layout-activate nav-save handler-save backup-create
    rotate-auth-secret plugin-enable session-revoke user-revoke key-revoke
);

# --- 1. a POST WITHOUT a CSRF token is refused for every write ------------------
for my $a (@writes) {
    my $r = call( $d, $a, csrf => 'none' );
    ok( !$r->{ok}, "POST $a without a CSRF token is refused" );
    like( $r->{error} // '', qr/CSRF/i, "  ... with a CSRF error ($a)" );
}

# --- 2. a valid CSRF token CLEARS the gate (no CSRF error) ----------------------
# (The action may still fail for its own reasons - we only assert the CSRF gate
# itself is passed, i.e. the error is never the CSRF refusal.)
for my $a (qw(save domain-add session-revoke)) {
    my $r = call( $d, $a, csrf => 'valid',
        body => encode_json( { content => "x", host => 'x.test', sid => 'nope', username => 'nobody' } ) );
    unlike( $r->{error} // '', qr/Invalid or missing CSRF/i,
        "a valid CSRF token clears the gate for $a" );
}

# --- 3. the pure-write actions cannot be driven over GET (no CSRF-free path) ----
for my $a (qw(session-revoke user-revoke key-revoke config-set domain-add theme-activate)) {
    my $r = call( $d, $a, method => 'GET' );
    ok( !$r->{ok}, "GET $a is refused" );
    like( $r->{error} // '', qr/must be sent as POST|CSRF/i,
        "  ... $a is forced to POST (cannot bypass CSRF via GET)" );
}

# --- 4. the gate is method-keyed in source (not an action allowlist) ------------
my $src = do { open my $fh, '<', $mapi or die $!; local $/; <$fh> };
like( $src, qr/if \(\s*\$method eq 'POST' && !\$token_auth\s*\)/,
    'the CSRF gate keys on the HTTP method, so no write action can be omitted' );
like( $src, qr/verify_csrf_token\(/, 'the gate verifies the CSRF token' );

done_testing();

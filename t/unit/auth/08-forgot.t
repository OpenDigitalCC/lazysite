#!/usr/bin/perl
# SM072 batch 2: forgot-password. Mints a set-password claim and (best-effort)
# emails the link - gated on SMTP configured + the account having an email,
# always a generic response. We assert the claim-mint + generic redirect +
# the gates (the actual SMTP send is exercised only with a real smtp.conf).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utl, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return decode_json($out);
}

sub forgot {
    my (%o) = @_;
    my $body = "identifier=$o{identifier}";
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT       => $o{docroot},
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => 'action=forgot',
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => 'on',
        HTTP_HOST           => 'example.org',
        LAZYSITE_USERS_TOOL => $utl,
    );
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $auth );
    print $w $body; close $w;
    my $out = do { local $/; <$r> }; do { local $/; <$e> };
    waitpid $pid, 0;
    return $out // '';
}

sub pending {
    ( users_api( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} || {} )
        ->{claim_pending} ? 1 : 0;
}

sub build {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth"; mkdir "$d/lazysite/forms";
    open my $cf, '>', "$d/lazysite/lazysite.conf"; print $cf "site_name: T\n"; close $cf;
    open my $sc, '>', "$d/lazysite/forms/smtp.conf";
    print $sc "method: sendmail\nsendmail_path: /nonexistent/sendmail\n"; close $sc;
    users_api( $d, { action => 'add', username => 'human', password => 'pw' } );
    users_api( $d, { action => 'settings-set', username => 'human', key => 'email', value => 'human@example.org' } );
    return $d;
}

# --- known account + email + smtp -> claim minted, generic redirect ----
{
    my $d = build();
    my $out = forgot( docroot => $d, identifier => 'human' );
    like( $out, qr{Location:[^\n]*/login\?reset=1}, 'forgot redirects to the generic reset page' );
    ok( pending( $d, 'human' ), 'a set-password claim was minted' );
}

# --- lookup by email ---------------------------------------------------
{
    my $d = build();
    forgot( docroot => $d, identifier => 'human@example.org' );
    ok( pending( $d, 'human' ), 'lookup by email mints a claim' );
}

# --- unknown identifier: same generic response, nothing minted ---------
{
    my $d = build();
    my $out = forgot( docroot => $d, identifier => 'nobody' );
    like( $out, qr{reset=1}, 'unknown identifier -> same generic redirect' );
    ok( !pending( $d, 'human' ), 'no unrelated claim minted' );
}

# --- gated on SMTP being configured ------------------------------------
{
    my $d = build();
    unlink "$d/lazysite/forms/smtp.conf";
    forgot( docroot => $d, identifier => 'human' );
    ok( !pending( $d, 'human' ), 'no claim when SMTP is not configured' );
}

# --- account without an email gets no claim ----------------------------
{
    my $d = build();
    users_api( $d, { action => 'add', username => 'noemail', password => 'pw' } );
    forgot( docroot => $d, identifier => 'noemail' );
    ok( !pending( $d, 'noemail' ), 'no claim for an account without an email' );
}

done_testing();

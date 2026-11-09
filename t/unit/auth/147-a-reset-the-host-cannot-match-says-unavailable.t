#!/usr/bin/perl
# Ruling 206 (item 19 of the 0.16.9 fault survey): A RESET THE HOST CANNOT MATCH
# SAYS UNAVAILABLE.
#
# lazysite-auth.pl's _resolve_account read an undecodable user-settings.json as
# "no such account", so a reset request for a real account was answered with
# the generic "check your mail" and went nowhere, in silence. Now the request is
# answered ?error=unavailable - a fact about the host, the same for every
# identifier, so it reveals no account - nothing is minted, the log names the
# store and the repair, and the file is left as found. A readable store, and an
# unknown identifier on it, answer as before.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough run_child site_tempdir);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $d, $p ) = @_;
    return decode_json( run_child( [ $^X, $utl, '--api', '--docroot', $d ],
            stdin => encode_json($p), stderr => 'discard' )->{out} );
}

sub forgot {
    my ( $d, $ident ) = @_;
    my $body = "identifier=$ident";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=forgot',
        CONTENT_LENGTH => length($body), CONTENT_TYPE => 'application/x-www-form-urlencoded',
        REMOTE_ADDR => '127.0.0.1', HTTPS => 'on', HTTP_HOST => 'example.org',
        LAZYSITE_USERS_TOOL => $utl,
    );
    my $r = run_child( [ $^X, $auth ], stdin => $body, stderr => 'pipe' );
    return ( $r->{out} // '', $r->{err} // '' );
}

sub slurp { open my $fh, '<:raw', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub build {
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    mkdir "$d/lazysite/forms";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    open my $sc, '>', "$d/lazysite/forms/smtp.conf" or die $!;
    print {$sc} "method: sendmail\nsendmail_path: /nonexistent/sendmail\n";
    close $sc;
    users_api( $d, { action => 'add', username => 'human', password => 'pw-long-enough' } );
    users_api( $d, { action => 'settings-set', username => 'human', key => 'email', value => 'human@example.org' } );
    return $d;
}

subtest 'a readable store: the generic answer, known or not' => sub {
    my $d = build();
    my ($out) = forgot( $d, 'human' );
    like( $out, qr{Location:[^\n]*/login\?reset=1}, 'a real account: reset=1' );
    ($out) = forgot( $d, 'nobody' );
    like( $out, qr{Location:[^\n]*/login\?reset=1}, 'an unknown one: the same' );
};

subtest 'an undecodable user-settings.json: unavailable, nothing minted, left as found' => sub {
    my $d  = build();
    my $us = "$d/lazysite/auth/user-settings.json";
    open my $w, '>', $us or die $!;
    print {$w} '{"human": {"email": "human@example.org"';
    close $w;
    my ( $out, $err ) = forgot( $d, 'human' );
    like( $out, qr{Location:[^\n]*/login\?error=unavailable}, 'the request is answered unavailable' );
    unlike( $out, qr{reset=1}, 'not "check your mail"' );
    my ($o2) = forgot( $d, 'nobody' );
    like( $o2, qr{error=unavailable}, 'the same for an unknown identifier - nothing about the account' );
    like( $err, qr/cannot tell - lazysite\/auth\/user-settings\.json does not decode as a JSON object/,
        'the log names the store' );
    like( $err, qr/lazysite check --docroot <docroot> names it/, 'and the repair' );
    is( slurp($us), '{"human": {"email": "human@example.org"', 'the file is left as found' );
    ok( !( grep { /claim/ } glob("$d/lazysite/auth/*") ), 'no claim file was written' );
};

done_testing();

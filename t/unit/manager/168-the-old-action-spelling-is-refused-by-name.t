#!/usr/bin/perl
# SM1142 (R3, R5): the old spelling of the extension actions is gone, and a
# caller still using it is told the new one by name.
#
# SM817 named these units extensions on the wire and kept the old `p...-*`
# spelling working behind a normaliser; SM831 recorded which spelling each call
# used, so the day it could go would be visible; SM1125 moved every shipped
# caller. SM1142 removes it - "fixup on upgrade, then its done" - so the dispatch
# knows `extension-*` and nothing else. The known outside callers (the sites
# agent's scripts) were told, and an unrecognised-action error would leave the
# next one guessing, so the refusal names the spelling to use: for the action,
# and for the two old parameter names.
#
# Driven over the token channel: the refusal comes before authentication (it
# says only how an action is spelled), so the cookie-only extension actions do
# not need a manager session to show it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use MIME::Base64 qw(encode_base64);
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir run_child);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $out, $err ) = @{ run_child( [ $^X, $mapi ],
        stdin => ( defined $body ? $body : '' ) ) }{qw(out err)};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = site_tempdir();    # lint 118: not a bare tempdir
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\nextensions:\n  - extensions/briefs.pl\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1,"assignable":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;

uapi( $d, { action => 'add', username => 'partner', password => 'x-long-enough' } );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
plan skip_all => 'no partner token' unless $tok;
grant_caps( $d, 'partner', 'api', 'manage_config' );

sub call {
    my ($qs) = @_;
    return mapi( $d, QUERY_STRING => $qs, REQUEST_METHOD => 'POST',
        body => '{}', HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
}

# old-name: begin (SM1142, the test sends the spelling that is refused)
my $old = 'plugin';
for my $verb (qw(list read save action enable disable)) {
    my $r = call("action=$old-$verb");
    ok( !$r->{ok}, "$old-$verb is refused" );
    is( $r->{kind}, 'not-found', 'as an unknown action' );
    like( $r->{error} // '', qr/use 'extension-\Q$verb\E' \(SM1142\)/,
        'naming the spelling to use' )
        or diag 'error was: ' . ( $r->{error} // '(none)' );
}

{
    my $r = call("action=extension-read&$old=stats");
    ok( !$r->{ok}, "the old '$old' parameter is refused" );
    like( $r->{error} // '', qr/unknown parameter '\Q$old\E'.*'extension'/, 'naming the new one' );

    $r = call("action=whoami&${old}s=0");
    ok( !$r->{ok}, "whoami's old '${old}s' switch is refused" );
    like( $r->{error} // '', qr/the switch is 'extensions'/, 'naming the new one' );
}
# old-name: end

{
    my $r = call('action=extension-nosuchthing');
    ok( !$r->{ok}, 'an unknown action in the one spelling is refused' );
    like( $r->{error} // '', qr/Unrecognised action name: 'extension-nosuchthing'/,
        'as the action the caller typed' );

    $r = call('action=whoami&extensions=0');
    ok( $r->{ok}, 'whoami takes its catalogue switch under the new name' )
        or diag explain $r;
}

done_testing();

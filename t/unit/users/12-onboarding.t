#!/usr/bin/perl
# SM071: the `onboarding` action - a fresh pairing key + brief for an
# existing user (the manager Users-page download).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $script = repo_root() . "/tools/lazysite-users.pl";

sub fresh {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://example.test\n";
    close $cf;
    return $d;
}
sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

my $d = fresh();
uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'partner', key => 'webdav', value => 'on' } );
uapi( $d, { action => 'settings-set', username => 'partner', key => 'manage_themes', value => 'on' } );

my $r = uapi( $d, { action => 'onboarding', username => 'partner' } );
ok( $r->{ok}, 'onboarding ok for existing user' );
like( $r->{pairing_key}, qr/^lzp_/, 'onboarding returns a pairing key' );
like( $r->{onboarding}, qr/partner/, 'brief names the user' );
like( $r->{onboarding}, qr{https://example\.test/dav/}, 'brief carries the DAV URL' );
# SM072: the machine-readable block - identity + capabilities parseable.
like( $r->{onboarding}, qr/## Machine-readable/, 'brief has a machine-readable block' );
like( $r->{onboarding}, qr/^partner: partner$/m, 'block carries the partner id' );
like( $r->{onboarding}, qr/- webdav/,   'block lists machine capabilities' );
like( $r->{onboarding}, qr/scheme: basic/,       'block states the basic-auth scheme' );

# The minted pairing key exchanges for a token.
my $ex = uapi( $d, { action => 'token-exchange',
    username => 'partner', pairing_key => $r->{pairing_key} } );
ok( $ex->{ok} && $ex->{token} =~ /^lzs_/, 'onboarding pairing key exchanges for a token' );

# Unknown user is rejected.
my $bad = uapi( $d, { action => 'onboarding', username => 'ghost' } );
ok( !$bad->{ok}, 'onboarding rejects an unknown user' );

# SM076: the web/connector variant mints a token (in the setup, for the
# connector settings) and steps the operator through adding the connector.
my $w = uapi( $d, { action => 'onboarding-web', username => 'partner' } );
ok( $w->{ok}, 'onboarding-web ok' );
like( $w->{token}, qr/^lzs_/, 'onboarding-web mints an lzs_ token' );
like( $w->{connector_setup}, qr{/cgi-bin/lazysite-mcp\.pl}, 'setup names the MCP endpoint' );
like( $w->{connector_setup}, qr/\Q$w->{token}\E/, 'setup carries the token (for the connector field)' );
like( $w->{connector_setup}, qr/whoami/, 'setup includes a whoami confirmation step' );
like( $w->{connector_setup}, qr/not (?:a chat|into a chat)/i, 'setup warns: token in settings, not chat' );
is( $w->{domain}, 'example.test', 'connector name is the site domain (one per site)' );
like( $w->{connector_setup}, qr/Name:\s+example\.test/, 'setup names the connector by domain' );

# The assistant prompt is separate and carries NO secret.
like( $w->{assistant_prompt}, qr/connector tools/i, 'assistant prompt steers to native connector tools' );
unlike( $w->{assistant_prompt}, qr/lzs_|\Q$w->{token}\E/, 'assistant prompt contains no token/secret' );

# Detection: not "used" until a touch-verify (the connector) authenticates.
my $st0 = uapi( $d, { action => 'credential-status', username => 'partner' } );
ok( $st0->{ok} && !$st0->{used}, 'credential-status: not used right after issuance' );
my $vc = uapi( $d, { action => 'verify-credential',
    username => 'partner', secret => $w->{token}, touch => 1 } );
ok( $vc->{ok}, 'the new token verifies' );
my $st1 = uapi( $d, { action => 'credential-status', username => 'partner' } );
ok( $st1->{ok} && $st1->{used}, 'credential-status: used after a connector (touch) verify' );

# A verify WITHOUT touch (e.g. WebDAV) does not flip an already-used flag back,
# and a fresh issuance resets it.
uapi( $d, { action => 'onboarding-web', username => 'partner' } );
ok( !uapi( $d, { action => 'credential-status', username => 'partner' } )->{used},
    'reissuing the credential resets the used flag' );

ok( !uapi( $d, { action => 'onboarding-web', username => 'ghost' } )->{ok},
    'onboarding-web rejects an unknown user' );

done_testing();

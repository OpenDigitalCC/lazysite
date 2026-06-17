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

# The minted pairing key exchanges for a token.
my $ex = uapi( $d, { action => 'token-exchange',
    username => 'partner', pairing_key => $r->{pairing_key} } );
ok( $ex->{ok} && $ex->{token} =~ /^lzs_/, 'onboarding pairing key exchanges for a token' );

# Unknown user is rejected.
my $bad = uapi( $d, { action => 'onboarding', username => 'ghost' } );
ok( !$bad->{ok}, 'onboarding rejects an unknown user' );

done_testing();

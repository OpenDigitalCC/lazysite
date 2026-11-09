#!/usr/bin/perl
# Ruling 206 (item 5 of the 0.16.9 fault survey): ON THE RENDER PATH, A
# groups-settings.json THAT EXISTS AND WILL NOT OPEN OR DECODE REFUSES EVERY
# SIGNED-IN REQUEST (503).
#
# The processor's _group_settings read such a store as {}, so _group_closure lost
# every group's address limit (SM1140) and a member whose group the visitor's
# address is refused for still matched `@group` rules and `auth_groups:`. Now
# _store_fault_gate answers a signed-in request with the cannot-tell 503 before
# anything is judged, and the log names the store and the repair. An anonymous
# request holds no group, so nothing about it is in doubt and it is unaffected.
# An ABSENT store is a site with no groups yet: no fault. `lazysite check` names
# the undecodable file (its existing line, SM1024).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site run_processor repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
setup_auth_site($docroot);
my $GS = "$docroot/lazysite/auth/groups-settings.json";

sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub as_alice {
    my ($uri) = @_;
    return run_processor( $docroot, $uri, HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'members' );
}

subtest 'THE CONTROL: a readable store, the member is served' => sub {
    put( $GS, '{"members":{"ui":0}}' );
    like( as_alice('/protected'), qr/Status: 200/, 'alice reads the members page' );
};

for my $case ( [ 'truncated', '{"members":{"ui":0}' ], [ 'an array', '["members"]' ] ) {
    my ( $what, $bytes ) = @$case;
    subtest "BROKEN groups-settings.json ($what): a signed-in request is refused" => sub {
        put( $GS, $bytes );
        my $out = as_alice('/protected');
        like( $out, qr/Status: 503/, 'alice is refused (503)' );
        like( $out, qr/fault on the host/, 'told the fault is the host\'s' );
        unlike( $out, qr/groups-settings/, 'and not the file name' );
        like( as_alice('/'), qr/Status: 503/, 'a public page too, while signed in' );
        my $anon = run_processor( $docroot, '/protected' );
        like( $anon, qr/Status: 302/, 'an anonymous request is judged as before (to sign-in)' );
        my $check = TestHelper::run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $docroot );
        like( $check, qr/groups-settings\.json does not decode as a JSON object/, 'lazysite check names the file' );
    };
}

subtest 'ABSENT groups-settings.json: no fault' => sub {
    unlink $GS;
    like( as_alice('/protected'), qr/Status: 200/, 'alice reads the members page' );
};

done_testing();

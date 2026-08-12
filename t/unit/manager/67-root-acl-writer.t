#!/usr/bin/perl
# SM287, writer half: the spellings that mean "the whole site", and the ones
# that are refused.
#
# The engine half (t/integration/45) proves a root entry now gates. This proves
# an operator can WRITE one, and - the part that matters - that no spelling is
# quietly accepted and left doing nothing. That was the old behaviour for all
# five: '/', '', '.', '/*' and '*' were each stored happily and gated nothing.
#
# A control that accepts your instruction and ignores it is the failure shape
# this whole programme is about (SM278, SM283, and the probe in SM285 that
# shipped passing by testing zero extensions).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files qw(action_acl_set action_acl_remove);
use Lazysite::Auth::Acl      qw(load_acls);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

sub stored { return load_acls() }

# --- every "whole site" spelling normalises to one key ----------------------
for my $spelling ( '/', '', '.', './' ) {
    my $shown = length $spelling ? "'$spelling'" : '(empty string)';

    # Start clean so each spelling is judged on its own.
    action_acl_remove( '/', 'alice' );

    my $r = action_acl_set( $spelling, 'alice', ['alice'], undef, undef, undef );
    ok( $r->{ok}, "$shown is accepted" ) or diag( $r->{error} // '' );

    my $map = stored();
    ok( exists $map->{'/'},
        "$shown stores under the canonical '/' - one key, however it was typed" )
        or diag( 'keys: ' . join ', ', map { "'$_'" } keys %$map );
    is( scalar keys %$map, 1, "$shown did not also leave a second key behind" );
}

# --- glob spellings are REFUSED, and say what to use instead ----------------
# Refused rather than normalised: the store has no matching language anywhere
# else, so accepting '*' would imply one. Silently storing it is what used to
# happen, and it gated nothing.
action_acl_remove( '/', 'alice' );
for my $glob ( '*', '/*', '**', './*' ) {
    my $r = action_acl_set( $glob, 'alice', ['alice'], undef, undef, undef );
    ok( !$r->{ok}, "'$glob' is refused, not quietly stored" );
    like( $r->{error} // '', qr{"/"},
        "'$glob': the refusal names the spelling that works" );
    like( $r->{error} // '', qr/whole site/i,
        "'$glob': and says what that spelling does" );

    my $map = stored();
    is( scalar keys %$map, 0, "'$glob' left nothing in the store" );
}

# --- the root entry is an ordinary entry in every other respect -------------
subtest 'a root entry reads back, updates and removes like any other' => sub {
    action_acl_set( '/', 'alice', ['alice'], undef, undef, undef );
    my $map = stored();
    is_deeply( $map->{'/'}{read}, ['alice'], 'the read list round-trips' );

    action_acl_set( '/', 'alice', [ 'alice', 'bob' ], undef, undef, undef );
    is_deeply( stored()->{'/'}{read}, [ 'alice', 'bob' ],
        'and updates in place rather than adding a second root key' );

    my $rm = action_acl_remove( '/', 'alice' );
    ok( $rm->{ok},               'removing the root rule succeeds' );
    ok( !exists stored()->{'/'}, 'and the whole site is public again' );
};

done_testing();

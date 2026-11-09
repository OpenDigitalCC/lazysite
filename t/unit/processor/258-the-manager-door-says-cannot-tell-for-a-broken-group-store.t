#!/usr/bin/perl
# Ruling 206 (item 18 of the 0.16.9 fault survey): THE MANAGER DOOR SAYS
# CANNOT-TELL FOR A BROKEN GROUP STORE, NOT "ASK FOR A GRANT".
#
# With lazysite/auth/groups-settings.json undecodable, the processor's
# _groups_grant_cap read it as {} and answered "no `ui`", so a signed-in person
# whose group does hold `ui` got the 403 "Manager access not permitted ... ask a
# sysop to grant your group the ui capability" - a sentence about a rule, for a
# fault in a file, sending them to ask for what they may already hold. Now the
# door answers 503 cannot-tell, and the log names the store and the repair. A
# readable store still opens the manager, and an account it says lacks `ui`
# still gets the 403.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(run_child processor_path site_tempdir);

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub site {
    my ($gs) = @_;
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
    spit( "$d/index.md",               "---\ntitle: Home\n---\nHome.\n" );
    spit( "$d/lazysite/auth/groups",   "editors: rita\nreaders: rob\n" );
    spit( "$d/lazysite/auth/groups-settings.json", $gs );
    return $d;
}

# The wrapper vouches for the cookie user, as the auth CGI does.
sub as_user {
    my ( $d, $user, $groups ) = @_;
    # run_processor discards the child's stderr, which is where the log goes.
    local %ENV = ( %ENV, DOCUMENT_ROOT => $d, REDIRECT_URL => '/manager/', REQUEST_METHOD => 'GET',
        QUERY_STRING => '', LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => $user,
        HTTP_X_REMOTE_GROUPS => $groups );
    my $r = run_child( [ $^X, processor_path() ], stderr => 'pipe' );
    return ( $r->{out}, $r->{err} // '' );
}

sub status { return ( $_[0] =~ /^Status:\s*(\d+)/m )[0] // 200 }

my $good = encode_json( { editors => { label => 'Editors', ui => 1 }, readers => { label => 'Readers' } } );

subtest 'a readable store: the editor is let in, the reader gets the 403' => sub {
    my $d = site($good);
    my ($in) = as_user( $d, 'rita', 'editors' );
    unlike( $in, qr/Manager access not permitted|Cannot tell right now/, 'the editor is let in' );
    my ($out) = as_user( $d, 'rob', 'readers' );
    is( status($out), 403, 'the reader is refused 403' );
    like( $out, qr/Manager access not permitted/, 'as not permitted' );
};

subtest 'an undecodable store: 503 cannot-tell, never "ask for a grant"' => sub {
    my $d = site('{"editors": {"label": "Editors", "ui": 1');
    my ( $out, $err ) = as_user( $d, 'rita', 'editors' );
    is( status($out), 503, '503, not 403' ) or diag( substr $out, 0, 400 );
    like( $out, qr/Cannot tell right now/, 'the cannot-tell page' );
    like( $out, qr/fault on the host, not a\s+decision about this account/, 'saying it is a fault' );
    unlike( $out, qr/Manager access not permitted|grant your group/, 'and not the sentence about a rule' );
    unlike( $out, qr/groups-settings\.json/, 'naming no file to the visitor' );
    like( $err, qr/cannot tell - lazysite\/auth\/groups-settings\.json cannot be read or does not decode/,
        'the log names the store' );
    like( $err, qr/lazysite check --docroot <docroot> names it/, 'and the repair' );
};

done_testing();

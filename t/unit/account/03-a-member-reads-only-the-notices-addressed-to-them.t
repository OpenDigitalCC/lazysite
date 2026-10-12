#!/usr/bin/perl
# SM1034 phase 1b (SM1010 R2): the member's own bell. me-notices answers with the
# notices addressed to the signed-in account - never a broadcast, never another
# account's (not even one whose login contains theirs) - from a window of the
# account's own, so a busy store cannot push them out; me-notices-seen marks or
# dismisses only those. The operators' `notices` door is unchanged: a member
# without `notifications` is still refused it.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1034-1b-secret-' x 3;

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REQUEST_METHOD     => ( $post ? 'POST' : 'GET' ),
        QUERY_STRING       => "action=$action",
        CONTENT_LENGTH     => length($json),
        REMOTE_ADDR        => '192.0.2.20',
        HTTP_X_REMOTE_USER => $who, HTTP_X_REMOTE_GROUPS => '', LAZYSITE_AUTH_TRUSTED => 1,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
    );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w $json;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print $uf "alice:x\nbob:x\nalice2:x\n";
    close $uf;
}

# The store: alice's oldest notice, then 150 for other people, then a broadcast,
# one for bob, one for alice2, and two more for alice.
my $t = time() - 1000;
open my $nf, '>', "$d/lazysite/logs/notices.jsonl" or die $!;
print $nf encode_json( { ts => $t++, type => 'rule', message => 'ALICE-OLDEST', to => 'alice' } ) . "\n";
print $nf encode_json( { ts => $t++, type => 'rule', message => "OTHER-$_", to => "member$_" } ) . "\n" for 1 .. 150;
print $nf encode_json( { ts => $t++, type => 'form', message => 'BROADCAST' } ) . "\n";
print $nf encode_json( { ts => $t++, type => 'rule', message => 'FOR-BOB', to => 'bob' } ) . "\n";
print $nf encode_json( { ts => $t++, type => 'rule', message => 'FOR-ALICE2 alice', to => 'alice2' } ) . "\n";
print $nf encode_json( { ts => $t++, type => 'rule', message => 'ALICE-ONE', to => 'alice', url => '/post/1' } ) . "\n";
print $nf encode_json( { ts => $t++, type => 'rule', message => 'ALICE-TWO', to => 'alice' } ) . "\n";
close $nf;

my $r = api( $d, 'alice', 'me-notices' );
ok( $r->{ok}, 'me-notices: a member with no capability reads their bell' ) or diag explain $r;
my @msg = map { $_->{message} } @{ $r->{notices} || [] };
is_deeply( \@msg, [qw(ALICE-TWO ALICE-ONE ALICE-OLDEST)],
    'exactly the notices addressed to alice, newest first' );
ok( !grep( { /BROADCAST|BOB|ALICE2|OTHER/ } @msg ),
    'no broadcast, nothing for bob, nothing for alice2' );
ok( grep( { $_ eq 'ALICE-OLDEST' } @msg ),
    'her oldest is kept although 150 others came after it - her window is her own' );
is( $r->{unread}, 3, 'all three unread' );

my $bob = api( $d, 'bob', 'me-notices' );
my ($bid) = map { $_->{id} } @{ $bob->{notices} || [] };
is( scalar @{ $bob->{notices} || [] }, 1, 'bob sees his one' );

my $cross = api( $d, 'alice', 'me-notices-seen', { id => $bid } );
ok( !$cross->{ok}, 'alice cannot mark bob\'s notice' );
is( $cross->{kind}, 'not-found', 'it is not found, as an id that does not exist is' );

my ($one) = map { $_->{id} } grep { $_->{message} eq 'ALICE-ONE' } @{ $r->{notices} };
my $m = api( $d, 'alice', 'me-notices-seen', { id => $one } );
ok( $m->{ok}, 'alice marks one of hers read' );
is( $m->{unread}, 2, 'two left unread' );

my $x = api( $d, 'alice', 'me-notices-seen', { id => $one, dismiss => 1 } );
ok( $x->{ok}, 'and dismisses it' );
my $after = api( $d, 'alice', 'me-notices' );
ok( !grep( { $_->{message} eq 'ALICE-ONE' } @{ $after->{notices} } ), 'it leaves her bell' );

my $all = api( $d, 'alice', 'me-notices-seen', {} );
is( $all->{unread},                           0, 'mark all read' );
is( api( $d, 'bob', 'me-notices' )->{unread}, 1, 'and bob\'s are still his to read' );

my $ops = api( $d, 'alice', 'notices' );
ok( !$ops->{ok}, 'the operators\' bell is still closed to a member without notifications' );

done_testing;

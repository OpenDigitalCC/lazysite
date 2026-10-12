#!/usr/bin/perl
# SM957: the Submissions menu entry's unread count is the bell's read state,
# counted for submission notices - asked of the manager API end to end.
#
# The ruling (2026-10-07): "yes unread count". What it may NOT be is a second
# store of what an operator has read: SM938 D3 made reading something said, not
# inferred, per operator, and a menu count kept anywhere else would disagree
# with the bell the first time one of them was marked. So `notices` answers the
# count by type from the same marks, and this drives it through the CGI as three
# accounts: one who has read one of two submission notices, one who has read
# nothing, and one without the notifications grant, who gets no count at all.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir);

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

# A request as a signed-in manager, the way the bell sends it: `notices` is a
# GET; `notices-seen` writes, so it is a POST with the session's CSRF token.
sub as {
    my ( $d, $user, $qs ) = @_;
    my $post = $qs =~ /\Aaction=notices-seen/;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $post ? 'POST' : 'GET';
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:$user:" . int( time() / 3600 ), $secret ) if $post;
    $ENV{CONTENT_LENGTH}        = 0;
    $ENV{QUERY_STRING}          = $qs;
    $ENV{HTTP_X_REMOTE_USER}    = $user;
    $ENV{HTTP_X_REMOTE_GROUPS}  = 'managers';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
make_path("$d/lazysite/logs");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Test Site\nlayout: base\ntheme: live\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sf} $secret;
close $sf;

for my $u (qw(op other alice)) {
    uapi( $d, { action => 'add',       username => $u, password => 'x-long-enough' } );
    uapi( $d, { action => 'group-add', username => $u, group    => 'managers' } );
}
grant_caps( $d, 'op',    'ui', 'notifications', 'read_submissions' );
grant_caps( $d, 'other', 'ui', 'notifications', 'read_submissions' );
grant_caps( $d, 'alice', 'ui', 'read_submissions' );    # no bell, so no count

my $now = time();
open my $nf, '>', "$d/lazysite/logs/notices.jsonl" or die $!;
print {$nf} encode_json($_) . "\n" for (
    { ts => $now - 300, type => 'submission', message => 'New form submission: contact',
        url => '/manager/submission?file=lazysite/forms/submissions/contact.jsonl&id=aaaaaaaaaaaaaaaa' },
    { ts => $now - 200, type => 'submission', message => 'New form submission: contact',
        url => '/manager/submission?file=lazysite/forms/submissions/contact.jsonl&id=bbbbbbbbbbbbbbbb' },
    { ts => $now - 100, type => 'reset-request', message => 'a reset was asked for' },
);
close $nf;

my $start = as( $d, 'op', 'action=notices' );
ok( $start->{ok}, 'the bell answers op' ) or diag explain $start;
is_deeply( $start->{unread_by_type}, { submission => 2, 'reset-request' => 1 },
    'before anything is read: two submission notices unread, counted apart from the rest' );

my ($first) = grep { $_->{message} =~ /contact/ } reverse @{ $start->{notices} };
my $seen = as( $d, 'op', "action=notices-seen&id=$first->{id}" );
ok( $seen->{ok}, 'op follows one submission notice (the bell marks that one read)' ) or diag explain $seen;

my $op = as( $d, 'op', 'action=notices' );
is( $op->{unread_by_type}{submission}, 1, 'op: one submission notice read of two -> the count is 1' );
is( $op->{unread_by_type}{'reset-request'}, 1, 'and the other kind of notice is not touched' );
is( $op->{unread}, 2, 'the bell\'s own total agrees: the count is a part of it, not a second tally' );

my $other = as( $d, 'other', 'action=notices' );
is( $other->{unread_by_type}{submission}, 2, 'another operator: 2 - the read state is per operator' );

my $alice = as( $d, 'alice', 'action=notices' );
ok( !$alice->{ok} && ( $alice->{kind} // '' ) eq 'forbidden',
    'without the notifications grant the bell refuses' );
ok( !exists $alice->{unread_by_type}, 'and there is no count to show' );

as( $d, 'op', 'action=notices-seen' );    # mark all read
is( as( $d, 'op', 'action=notices' )->{unread_by_type}{submission} // 0, 0,
    'mark all read clears the count too - one read state, two places that count it' );

done_testing();

#!/usr/bin/perl
# SM992 (ruled 2026-10-12, Finding 2, "Lock needs write access"): lock,
# renew-lock and unlock - on the manager API, and WebDAV's LOCK and UNLOCK -
# require the caller to be able to write the file under its rule. Everyone else
# is refused; the operator's force-unlock is unchanged.
#
# Reported beside SM979 and left: `lock` asked no file rule, so any manager
# account could lock any file and block its writers until the lock expired,
# and `unlock` released anybody's lock. The manager dispatch called
# acquire_lock, release_lock and renew_lock with no rule at all. WebDAV's LOCK
# was already authorised as a write; UNLOCK was not, so a holder whose write
# was taken away kept releasing.
#
# Every assertion reads the lock store afterwards, not only the reply.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root run_dav);
use ManagerSession qw(new_site);
use MIME::Base64   qw(encode_base64);

my $root = repo_root();
my $s = new_site( root => $root, conf => "control_api_enabled: true\nwebdav_enabled: true\n" );
my $d = $s->docroot;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my @ALL = qw(ui manage_users manage_content manage_config webdav api mcp);
$s->add_user('boss');
$s->grant( 'boss', 'sysops', [qw(ui manage_users manage_content manage_config)], \@ALL );
$s->users( 'group-set', 'sysops', 'manager', 'on' );    # the operator group (SM991)
$s->add_user('GeekRuthie');
$s->grant( 'GeekRuthie', 'authors', [qw(ui manage_content webdav)], \@ALL );
$s->add_user('rs');
$s->grant( 'rs', 'readers', [qw(ui manage_content webdav)], \@ALL );

make_path("$d/post");
spit( "$d/post/a.md", "---\ntitle: A\n---\nthe author's text\n" );
spit( "$d/open.md",   "---\ntitle: O\n---\nno rule governs this\n" );
sub acl {
    my $cmd = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-acl.pl", @_,
        '--docroot', $d, '--actor', 'local';
    qx($cmd 2>&1);
    return $? >> 8;
}
is( acl( 'set', 'post/a.md', '--owner', 'GeekRuthie', '--write', 'GeekRuthie' ), 0, "the post's rule names its author" );

my $LOCKS = "$d/lazysite/manager/locks";
sub lockfile { my ($rel) = @_; ( my $k = $rel ) =~ s{/}{:}g; return "$LOCKS/$k.lock" }
sub holder {
    my ($rel) = @_;
    open my $fh, '<', lockfile($rel) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $rec = eval { JSON::PP::decode_json($raw) } || {};
    return $rec->{user};
}
sub call { my ( $u, $act, $p ) = @_; return $s->call( $u, $act, groups => 1, query => "action=$act&path=$p", body => {} ) }
sub refused {
    my ( $r, $label ) = @_;
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'permission', "$label: refused by the file's rule" )
        or diag( explain $r );
    is( $s->last_status, 403, "$label: answers 403" );
}

subtest 'the manager: a caller the rule does not let write takes no lock' => sub {
    refused( call( 'rs', 'lock', 'post/a.md' ), 'lock' );
    ok( !-e lockfile('post/a.md'), 'and no lock was written' );
    refused( call( 'rs', 'renew-lock', 'post/a.md' ), 'renew-lock' );
    ok( !-e lockfile('post/a.md'), 'nor by renewing' );
};

subtest 'the writer locks, and a non-writer cannot release it' => sub {
    my $r = call( 'GeekRuthie', 'lock', 'post/a.md' );
    ok( $r->{ok}, 'the author locks her post' ) or diag( explain $r );
    is( holder('post/a.md'), 'GeekRuthie', 'the lock is hers' );
    $r = call( 'GeekRuthie', 'renew-lock', 'post/a.md' );
    ok( $r->{ok}, 'and renews it' ) or diag( explain $r );
    refused( call( 'rs', 'unlock', 'post/a.md' ), 'unlock by a non-writer' );
    is( holder('post/a.md'), 'GeekRuthie', 'the lock is still hers' );
};

subtest "the operator's force-unlock is unchanged" => sub {
    my $r = call( 'boss', 'unlock', 'post/a.md' );
    ok( $r->{ok}, "the operator releases the author's lock" ) or diag( explain $r );
    ok( !-e lockfile('post/a.md'), 'and it is gone' );
};

subtest 'a file no rule governs locks as before' => sub {
    my $r = call( 'rs', 'lock', 'open.md' );
    ok( $r->{ok}, 'any manager account locks it' ) or diag( explain $r );
    $r = call( 'rs', 'unlock', 'open.md' );
    ok( $r->{ok} && !-e lockfile('open.md'), 'and releases it' ) or diag( explain $r );
};

my $LOCKBODY = '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">'
    . '<D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>';
# ManagerSession's add_user password (SM1041 lengthened it to the 12-character
# minimum). The old one signs nobody in: every request below was a 401.
sub basic { return 'Basic ' . encode_base64( "$_[0]:pw123456789-long-enough", '' ) }
sub dav { my ( $u, $m, $p, %o ) = @_; return run_dav( $d, $m, "/$p", HTTP_AUTHORIZATION => basic($u), %o ) }

subtest 'WebDAV: LOCK and UNLOCK ask the same rule' => sub {
    my $r = dav( 'rs', 'LOCK', 'post/a.md', body => $LOCKBODY );
    is( $r->{code}, 403, 'LOCK by a non-writer: 403' );
    like( $r->{body} // '', qr/per-file ACL denies you write access/, 'refused by the file\'s rule' );
    ok( !-e lockfile('post/a.md'), 'and no lock' );

    $r = dav( 'GeekRuthie', 'LOCK', 'post/a.md', body => $LOCKBODY );
    is( $r->{code}, 200, 'the author takes a WebDAV lock' ) or diag( explain $r );
    my ($tok) = ( $r->{headers}{'lock-token'} // '' ) =~ /<([^>]+)>/;
    ok( $tok, 'with a token' );

    is( acl( q(remove), q(post/a.md) ), 0, q(her rule is removed) );
    is( acl( q(set), q(post/a.md), q(--owner), q(boss), q(--write), q(boss) ), 0,
        'the rule is changed so it no longer names her' );
    $r = dav( 'GeekRuthie', 'UNLOCK', 'post/a.md', HTTP_LOCK_TOKEN => "<$tok>" );
    is( $r->{code}, 403, 'UNLOCK by a holder who can no longer write: 403' );
    like( $r->{body} // '', qr/per-file ACL denies you write access/, 'refused by the file\'s rule' );
    ok( -e lockfile('post/a.md'), 'and the lock stays' );

    is( acl( q(remove), q(post/a.md) ), 0, q(the operator's rule is removed) );
    is( acl( q(set), q(post/a.md), q(--owner), q(GeekRuthie), q(--write), q(GeekRuthie) ), 0, q(and hers put back) );
    $r = dav( 'GeekRuthie', 'UNLOCK', 'post/a.md', HTTP_LOCK_TOKEN => "<$tok>" );
    is( $r->{code}, 204, 'and she releases her lock' );
    ok( !-e lockfile('post/a.md'), 'which is gone' );
};

done_testing();

#!/usr/bin/perl
# SM173: a sub-user manager (create_sub_users, but NOT the full 'audit' cap) sees
# a SCOPED audit view - their own activity plus that of the accounts beneath them
# in the managed_by/created_by tree - never the whole site. A full 'audit' holder
# still sees everything; a user with neither is denied.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi_s = "$root/lazysite-manager-api.pl";

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

sub get {
    my ( $d, $user, $groups, $qs ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'GET';
    $ENV{CONTENT_LENGTH}      = 0;
    $ENV{QUERY_STRING}        = $qs;
    $ENV{HTTP_X_REMOTE_USER}  = $user;
    $ENV{HTTP_X_REMOTE_GROUPS} = $groups;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi_s );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

uapi( $d, { action => 'add', username => 'op',   password => 'x' } );
uapi( $d, { action => 'add', username => 'boss', password => 'x' } );
grant_caps( $d, 'op',   'audit' );               # full audit
grant_caps( $d, 'boss', 'create_sub_users' );    # a sub-user manager
# boss creates a sub-user; managed_by defaults to created_by (= boss)
uapi( $d, { action => 'account-create', username => 'sub1', password => 'x',
        created_by => 'boss', actor => 'boss' } );
uapi( $d, { action => 'add', username => 'other', password => 'x' } );    # unrelated

# --- audit-scope resolves the manager's subtree -------------------------------
my $sc = uapi( $d, { action => 'audit-scope', username => 'boss' } );
is_deeply( [ sort @{ $sc->{users} } ], [qw(boss sub1)],
    'audit-scope = the manager plus their sub-users (not unrelated accounts)' );

# Seed the audit log with activity by each of the three actors.
open my $al, '>', "$d/lazysite/logs/audit.log" or die $!;
print $al "2026-07-18T10:00:00Z | boss | save | a.md | 1.1.1.1 | ok | ui\n";
print $al "2026-07-18T10:01:00Z | sub1 | save | b.md | 1.1.1.1 | ok | ui\n";
print $al "2026-07-18T10:02:00Z | other | save | c.md | 1.1.1.1 | ok | ui\n";
close $al;

# --- the sub-user manager sees only their team --------------------------------
my $b = get( $d, 'boss', 'role-boss', 'action=audit' );
ok( $b->{ok}, 'a create_sub_users manager may read the (scoped) audit' ) or diag encode_json($b);
ok( $b->{scoped}, 'the response is flagged as scoped' );
my %bu = map { ( $_->{user} // '' ) => 1 } @{ $b->{entries} };
ok( $bu{boss} && $bu{sub1}, 'sees own + sub-user activity' );
ok( !$bu{other}, 'does NOT see an unrelated account (no leak of the whole log)' );
is_deeply( [ sort @{ $b->{users} } ], [qw(boss sub1)],
    'the user filter dropdown lists only the team' );

# --- the full-audit operator sees everything ----------------------------------
my $o = get( $d, 'op', 'role-op', 'action=audit' );
ok( $o->{ok} && !$o->{scoped}, 'a full audit holder is not scoped' );
my %ou = map { ( $_->{user} // '' ) => 1 } @{ $o->{entries} };
ok( $ou{boss} && $ou{sub1} && $ou{other}, 'the full log includes every actor' );

# --- a user with neither capability is denied ---------------------------------
my $n = get( $d, 'other', 'role-other', 'action=audit' );
ok( !$n->{ok} && $n->{kind} eq 'forbidden', 'a user with no audit rights is refused' );

done_testing();

#!/usr/bin/perl
# Coverage: the manager read actions pages / config-read / principals / notices /
# notices-seen had no test references (found via the branch-coverage review).
# These exercise their handlers end to end through the manager API as an operator.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# operator GET/POST as a manager-group member
sub op_get {
    my ( $d, $qs ) = @_;
    return mapi( $d, QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'managers' );
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/logs");
make_path("$d/blog");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "manager_groups: managers\nsite_name: Test Site\nlayout: base\ntheme: live\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf $secret; close $sf;

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_content', 'manage_nav', 'manage_config', 'notifications' );
uapi( $d, { action => 'group-add', username => 'op', group => 'managers' } );   # a stored group with a member
uapi( $d, { action => 'add', username => 'alice', password => 'y' } );

# content for action_pages to discover
open my $p1, '>', "$d/index.md"      or die $!; print $p1 "# Home\n";  close $p1;
open my $p2, '>', "$d/blog/post.md"  or die $!; print $p2 "# Post\n";  close $p2;

# --- action_pages -----------------------------------------------------------
{
    my $r = op_get( $d, 'action=pages' );
    ok( $r->{ok}, 'pages: ok' );
    ok( ( grep { $_ eq '/blog/post' } @{ $r->{urls} } ), 'pages: lists a nested .md page' );
    ok( ( grep { $_ eq '/' } @{ $r->{urls} } ), 'pages: index.md maps to /' );
    ok( !( grep { m{^/lazysite} } @{ $r->{urls} } ), 'pages: excludes the lazysite/ tree' );
}

# --- action_config_read -----------------------------------------------------
{
    my $r = op_get( $d, 'action=config-read' );
    ok( $r->{ok}, 'config-read: ok' );
    is( $r->{config}{site_name}, 'Test Site', 'config-read: returns site_name' );
    is( $r->{config}{layout},    'base',      'config-read: returns layout' );
    ok( exists $r->{config}{webdav_enabled}, 'config-read: includes a defaulted key' );
}

# --- action_principals ------------------------------------------------------
{
    my $r = op_get( $d, 'action=principals' );
    ok( $r->{ok}, 'principals: ok' );
    ok( ( grep { $_ eq 'alice' } @{ $r->{users} } ), 'principals: lists users' );
    ok( ( grep { $_ eq 'managers' } @{ $r->{groups} } ), 'principals: lists groups' );
}

# --- action_notices + notices-seen -----------------------------------------
{
    open my $nf, '>', "$d/lazysite/logs/notices.jsonl" or die $!;
    print $nf encode_json({ ts => 1000, msg => 'old' } ) . "\n";
    print $nf encode_json({ ts => 1_700_000_000, msg => 'new' } ) . "\n";   # past, but > 0
    close $nf;

    my $r = op_get( $d, 'action=notices' );
    ok( $r->{ok}, 'notices: ok' );
    is( scalar @{ $r->{notices} }, 2, 'notices: returns both entries' );
    is( $r->{notices}[0]{msg}, 'new', 'notices: newest first' );
    ok( $r->{unread} >= 1, 'notices: reports unread count' );

    # mark seen (POST needs CSRF)
    my $s = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=notices-seen',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'managers',
        HTTP_X_CSRF_TOKEN => csrf('op') );
    ok( $s->{ok}, 'notices-seen: ok' );
    is( $s->{unread}, 0, 'notices-seen: clears unread' );

    my $r2 = op_get( $d, 'action=notices' );
    is( $r2->{unread}, 0, 'notices: unread is 0 after marking seen' );

    # SM136: the bell requires the notifications capability - a manager without
    # it is refused (the UI then hides the bell).
    my $no = mapi( $d, QUERY_STRING => 'action=notices',
        HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'managers' );
    ok( !$no->{ok} && ( $no->{kind} // '' ) eq 'forbidden',
        'notices: refused without the notifications capability' );
}

# --- action_recent_changes (SM103) ------------------------------------------
{
    make_path("$d/lazysite/cache");
    my $iso = sub { POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time() - $_[0] ) ) };
    open my $al, '>', "$d/lazysite/logs/audit.log" or die $!;
    my $row = sub { join( ' | ', @_ ) . "\n" };
    # /blog/post: two recent edits; op's is later, so op should win per target.
    print $al $row->( $iso->(60), 'alice', 'edit',     '/blog/post', '1.2.3.4', 'ok', 'ui', '' );
    print $al $row->( $iso->(30), 'op',    'edit',     '/blog/post', '1.2.3.4', 'ok', 'ui', '' );
    print $al $row->( $iso->(20), 'op',    'user-add', 'alice',      '1.2.3.4', 'ok', 'ui', '' );
    # excluded cases:
    print $al $row->( '2020-01-01T00:00:00Z', 'op', 'edit',   '/old-page', '1.2.3.4', 'ok',   'ui', '' );
    print $al $row->( $iso->(10),             'op', 'delete', '/failed',   '1.2.3.4', 'fail', 'ui', 'x' );
    print $al $row->( $iso->(5),              'op', 'login',  '',          '1.2.3.4', 'ok',   'ui', '' );
    close $al;

    my $r = op_get( $d, 'action=recent-changes' );
    ok( $r->{ok}, 'recent-changes: ok' );
    my $ch = $r->{changes} || {};
    ok( $ch->{'/blog/post'}, 'recent-changes: a recent page change is present' );
    is( $ch->{'/blog/post'}{user}, 'op', 'recent-changes: the latest writer wins per target' );
    ok( $ch->{'alice'},        'recent-changes: a recent user change is present' );
    ok( !$ch->{'/old-page'},   'recent-changes: an out-of-window change is excluded' );
    ok( !$ch->{'/failed'},     'recent-changes: a failed action is excluded' );
    ok( !exists $ch->{''},     'recent-changes: an empty target is excluded' );

    my $r2 = op_get( $d, 'action=recent-changes&window=1' );
    ok( !$r2->{changes}{'/blog/post'}, 'recent-changes: the window parameter narrows the result' );
}

done_testing();

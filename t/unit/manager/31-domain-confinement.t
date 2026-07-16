#!/usr/bin/perl
# SM154 (P1): a domain-bound cookie user (dav_scope set) is confined to their
# content_root on the INTERACTIVE manager channel too - not just over WebDAV /
# token, which M2 already covers. So a delegated domain editor can work inside
# their domain but cannot read, list or write another domain's content through
# the manager UI. An operator (no dav_scope) is unconfined.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
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
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# GET a read-only action as a cookie user.
sub get {
    my ( $d, $user, $groups, $qs ) = @_;
    return mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups );
}

# POST a state-changing action with a valid CSRF token.
sub post {
    my ( $d, $user, $groups, $qs, $obj ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user,       HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN  => csrf($user), body => encode_json( $obj // {} ) );
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/content/clientA", "$d/content/clientB" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Agency\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;
open my $a, '>', "$d/content/clientA/ok.md"     or die $!; print $a "A\n"; close $a;
open my $b, '>', "$d/content/clientB/secret.md" or die $!; print $b "B\n"; close $b;

# op = operator (manage_users secures the site, so non-operators are gated);
# client = a domain-bound editor confined to content/clientA. SM155: the binding
# is on the GROUP now - grant_caps makes a role-<user> group, so set its
# dav_scope; the member inherits it.
uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users', 'manage_content' );
uapi( $d, { action => 'add', username => 'client', password => 'y' } );
grant_caps( $d, 'client', 'manage_content' );
uapi( $d, { action => 'group-settings-set', group => 'role-client',
        key => 'dav_scope', value => 'content/clientA' } );

# --- the bound client works INSIDE its scope --------------------------------
{
    my $r = get( $d, 'client', 'role-client',
        'action=read&path=/content/clientA/ok.md' );
    ok( $r->{ok}, 'P1: bound client may read inside its domain' )
        or diag encode_json($r);
}

# --- ...but is refused OUTSIDE its scope, on read, list and write ------------
{
    my $r = get( $d, 'client', 'role-client',
        'action=read&path=/content/clientB/secret.md' );
    ok( !$r->{ok}, 'P1: bound client cannot read another domain' );
    is( $r->{kind}, 'forbidden', 'P1: read out-of-scope is forbidden' );

    my $l = get( $d, 'client', 'role-client', 'action=list&path=/content/clientB' );
    ok( !$l->{ok}, 'P1: bound client cannot list another domain' );

    my $w = post( $d, 'client', 'role-client', 'action=save&path=/content/clientB/x.md',
        { content => "no\n", mtime => undef } );
    ok( !$w->{ok},                     'P1: bound client cannot write another domain' );
    ok( !-f "$d/content/clientB/x.md", 'P1: the out-of-scope write did not land' );
}

# --- the operator (no dav_scope) is NOT confined ----------------------------
{
    my $r = get( $d, 'op', 'role-op', 'action=read&path=/content/clientB/secret.md' );
    ok( $r->{ok}, 'operator (unbound) reads any domain' ) or diag encode_json($r);
}

# --- SM155: a member of TWO scoped groups gets the UNION ---------------------
# Add 'client' to a second scoped group (clientB). Now clientA AND clientB are
# reachable, but a third domain is still denied.
{
    uapi( $d, { action => 'group-add', username => 'client', group => 'clientb-team' } );
    uapi( $d, { action => 'group-settings-set', group => 'clientb-team',
            key => 'manage_content', value => 'on' } );
    uapi( $d, { action => 'group-settings-set', group => 'clientb-team',
            key => 'dav_scope', value => 'content/clientB' } );
    mkdir "$d/content/clientC";
    open my $c, '>', "$d/content/clientC/z.md" or die $!; print $c "C\n"; close $c;

    my $ga = 'role-client,clientb-team';   # the client's groups, as the wrapper sets them
    ok( get( $d, 'client', $ga, 'action=read&path=/content/clientA/ok.md' )->{ok},
        'union: still reads clientA (first scoped group)' );
    ok( get( $d, 'client', $ga, 'action=read&path=/content/clientB/secret.md' )->{ok},
        'union: now reads clientB (second scoped group)' );
    my $c3 = get( $d, 'client', $ga, 'action=read&path=/content/clientC/z.md' );
    ok( !$c3->{ok}, 'union: a third domain is still denied' );
    is( $c3->{kind}, 'forbidden', 'union: the third domain read is forbidden' );
}

done_testing();

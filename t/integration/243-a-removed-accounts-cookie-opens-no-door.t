#!/usr/bin/perl
# SM1070 (n562, ruled 2026-10-13 "Probe, then fix"): the cookie of a REMOVED
# account opens no door, and neither does a DISABLED one's; an account whose
# GROUPS were taken away keeps its member's doors and loses its groups' at once.
#
# The probe on main (02c590bd): an account signed in for real, its cookie kept,
# the account removed with the users tool. Through the real doors the cookie
# still read as the removed account - the members-only page (auth: required),
# /account (me), its sessions, the bell (me-notices) and its read state
# (me-notices-seen, audited as the removed name), a CSRF token from the data
# endpoint, and a form post that skipped the rate limit and wrote a PERSONAL row
# owned by the removed name. Its groups had gone with it, so the manager, the
# auth_groups page and the data writes refused it. A disabled account was
# refused on every door already (SM071).
#
# Every request below is the real CGI: the auth wrapper in front of the manager
# API and the processor, as a deployment runs them, and the data endpoint and
# the form handler, which verify the cookie themselves.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper             qw(repo_root env_passthrough site_tempdir run_cmd);
use Lazysite::Data::Tables qw(apply_schema read_rows);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $mapi = "$root/lazysite-manager-api.pl";
my $proc = "$root/lazysite-processor.pl";
my $data = "$root/lazysite-data.pl";
my $form = "$root/plugins/form-handler.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

sub run {
    my ( $argv, $env, $body ) = @_;
    local %ENV = ( env_passthrough(), %$env );
    my ( $w, $r, $e ) = ( undef, undef, gensym );
    my $pid = open3( $w, $r, $e, $^X, @$argv );
    print {$w} ( $body // '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($st) = ( $out // '' ) =~ /^Status:\s*(\d+)/m;
    my ($b)  = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 200, $b // '', $err // '', $out // '' );
}

sub users { return run_cmd( $^X, $utl, '--docroot', @_ ) }

# A secured site: an operator, and `gone`, a member of `editors`, which may
# manage, write content and write data.
sub site {
    my $d = site_tempdir();
    make_path( map { "$d/lazysite/$_" } qw(auth logs forms db/tables) );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\nplugins:\n  - plugins/data.pl\n" );
    spit( "$d/lazysite/forms/.secret", 'b' x 64 );
    spit( "$d/index.md",               "---\ntitle: Home\n---\nHOME\n" );
    spit( "$d/members.md", "---\ntitle: M\nauth: required\n---\nSECRET-MEMBERS\n" );
    spit( "$d/editors.md", "---\ntitle: E\nauth_groups: [editors]\n---\nSECRET-EDITORS\n" );
    spit( "$d/lazysite/db/tables/comments.yaml",
        "title: Comments\ntimestamps: true\nrow_policy: true\n"
            . "fields:\n  post:\n    type: text\n  comment:\n    type: text\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: comments\n    type: table\n    name: Comments\n"
            . "    table: comments\n    fields: post=post,comment=comment\n"
            . "    keep_copy: false\n    row_policy: personal\n" );
    spit( "$d/lazysite/forms/comment.conf", "spam_dwell: off\ntargets:\n  - handler: comments\n" );
    apply_schema( $d, 'comments' );
    users( $d, 'setup-sysop', '--user',  'op', 'op-password-0123456789' );
    users( $d, 'add',         'gone',    'gone-password-0123456789' );
    users( $d, 'group-add',   'gone',    'editors' );
    users( $d, 'group-set',   'editors', $_, 'on' ) for qw(ui manage_content write_data);
    return $d;
}

# A real sign-in through the wrapper; the cookie it sets is the one kept.
sub sign_in {
    my ($d) = @_;
    my $body = 'username=gone&password=gone-password-0123456789&next=/';
    my ( undef, undef, undef, $out ) = run( [$auth],
        { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=login',
            CONTENT_TYPE => 'application/x-www-form-urlencoded', CONTENT_LENGTH => length $body,
            REMOTE_ADDR => '127.0.0.1', LAZYSITE_USERS_TOOL => $utl, HTTPS => '' },
        $body );
    my ($c) = $out =~ /Set-Cookie:\s*lazysite_auth=([^;\s]+)/i;
    return $c // '';
}

sub csrf {
    my ($d) = @_;
    my $s = slurp("$d/lazysite/auth/.secret");
    chomp $s;
    return hmac_sha256_hex( 'csrf:gone:' . int( time() / 3600 ), $s );
}

sub wrapped {
    my ( $d, $c, $target, %o ) = @_;
    my $body = $o{body};
    my %env = ( DOCUMENT_ROOT => $d, REQUEST_METHOD => ( defined $body ? 'POST' : 'GET' ),
        QUERY_STRING   => ( $o{qs} // '' ), REDIRECT_URL => ( $o{uri} // '/' ),
        CONTENT_LENGTH => length( $body // '' ), CONTENT_TYPE => 'application/json',
        REMOTE_ADDR => '127.0.0.1', LAZYSITE_PROCESSOR => $target, LAZYSITE_USERS_TOOL => $utl,
        HTTP_COOKIE => "lazysite_auth=$c" );
    $env{HTTP_X_CSRF_TOKEN} = csrf($d) if defined $body;
    return run( [$auth], \%env, $body );
}

sub manager { my ( $d, $c, $act, %o ) = @_; return wrapped( $d, $c, $mapi, qs => "action=$act", %o ) }
sub page { my ( $d, $c, $uri ) = @_; return wrapped( $d, $c, $proc, uri => $uri ) }

sub data_token {
    my ( $d,  $c ) = @_;
    my ( $st, $b ) = run( [$data], { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
            QUERY_STRING => 'csrf=1', HTTP_COOKIE => "lazysite_auth=$c" } );
    return ( $st, ( eval { decode_json($b) } || {} )->{token} );
}

# ( row owner or undef when no row, rate limit waived? )
sub form_post {
    my ( $d, $c, $comment ) = @_;
    my $ts = time - 10;
    my $b = "_form=comment&post=p1&comment=$comment&_hp=&_ts=$ts&_tk=" . hmac_sha256_hex( $ts, 'b' x 64 );
    my ( undef, undef, $err ) = run( [$form], { DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST',
            CONTENT_TYPE => 'application/x-www-form-urlencoded', CONTENT_LENGTH => length $b,
            REMOTE_ADDR => '203.0.113.9', HTTP_COOKIE => "lazysite_auth=$c" }, $b );
    my ($row) = grep { ( $_->{comment} // '' ) eq $comment }
        @{ read_rows( $d, 'comments', as => 'operator' )->{rows} || [] };
    return ( $row ? ( $row->{created_by} // '' ) : undef, $err =~ /rate limit waived/ ? 1 : 0 );
}

sub audit_names {
    my ( $d, $who ) = @_;
    return scalar grep { ( split /\s*\|\s*/ )[1] eq $who } grep { length } split /\n/, slurp("$d/lazysite/logs/audit.log");
}

# --- the fixture: a live account opens its doors --------------------------------
{
    my $d = site();
    my $c = sign_in($d);
    ok( length $c, 'gone signs in for real' ) or BAIL_OUT('no cookie - nothing below would measure anything');
    my ( $st, $b ) = manager( $d, $c, 'me' );
    is( $st, 200, 'live: /account answers' );
    ( $st, $b ) = page( $d, $c, '/members' );
    like( $b, qr/SECRET-MEMBERS/, 'live: the members page is served' );
    ( $st, $b ) = page( $d, $c, '/editors' );
    like( $b, qr/SECRET-EDITORS/, 'live: the editors page is served' );
    my ( $owner, $waived ) = form_post( $d, $c, 'live' );
    is( $owner, 'gone', 'live: a form post is owned by the member' );
    ok( $waived, 'live: and skips the rate limit' );
}

# --- REMOVED: no door opens -------------------------------------------------------
{
    my $d = site();
    my $c = sign_in($d);
    like( users( $d, 'remove', 'gone' ), qr/removed/, 'removed: the account is removed' );
    my $audit_before = audit_names( $d, 'gone' );
    my $rev_before   = slurp("$d/lazysite/auth/revoked.json");

    for my $act (qw(whoami me me-sessions me-notices)) {
        my ( $st, $b ) = manager( $d, $c, $act );
        is( $st, 400, "removed: manager $act is refused" );
        like( $b, qr/Authentication required/, "removed: $act - as no identity at all" );
    }
    my ( $st, $b ) = page( $d, $c, '/members' );
    is( $st, 302, 'removed: the members page sends the visitor to sign in' );
    unlike( $b, qr/SECRET-MEMBERS/, 'removed: and serves none of it' );
    ( $st, $b ) = page( $d, $c, '/editors' );
    unlike( $b, qr/SECRET-EDITORS/, 'removed: the editors page serves none of it' );

    my ( $tst, $token ) = data_token( $d, $c );
    is( $tst, 403, 'removed: the data endpoint mints no CSRF token' );
    ok( !$token, 'removed: none at all' );

    my ( $owner, $waived ) = form_post( $d, $c, 'after-removal' );
    is( $owner, '', 'removed: a form post is anonymous - no row is owned by the removed name' );
    ok( !$waived, 'removed: and it meets the rate limit like any visitor' );

    # The writes last: on main, me-sign-out-everywhere succeeded, and the
    # revocation it wrote would have refused every request after it.
    ( $st, $b ) = manager( $d, $c, 'save', qs => 'action=save&path=/x.md',
        body => encode_json( { content => "# x\n" } ) );
    is( $st, 400, 'removed: a save is refused' );
    ok( !-e "$d/x.md", 'removed: and nothing is written' );
    for my $act (qw(me-notices-seen me-sign-out-everywhere)) {
        ( $st, $b ) = manager( $d, $c, $act, body => '{}' );
        is( $st, 400, "removed: manager $act (a write) is refused" );
    }

    is( audit_names( $d, 'gone' ), $audit_before, 'removed: the audit trail gains no entry in the removed name' );
    is( slurp("$d/lazysite/auth/revoked.json"), $rev_before, 'removed: the cookie wrote no state' );

    my ( undef, undef, $err ) = page( $d, $c, '/members' );
    like( $err, qr/auth: account does not exist(?=.*user=gone)/, 'removed: the wrapper logs why, naming the account' );
}

# --- DISABLED: no door opens (SM071, held) ----------------------------------------
{
    my $d = site();
    my $c = sign_in($d);
    users( $d, 'account-disable', 'gone' );
    for my $act (qw(whoami me me-notices)) {
        my ($st) = manager( $d, $c, $act );
        is( $st, 400, "disabled: manager $act is refused" );
    }
    my ( $st, $b ) = page( $d, $c, '/members' );
    is( $st, 302, 'disabled: the members page sends the visitor to sign in' );
    my ($tst) = data_token( $d, $c );
    is( $tst, 403, 'disabled: no CSRF token' );
    my ($owner) = form_post( $d, $c, 'disabled' );
    is( $owner, '', 'disabled: a form post is anonymous' );
}

# --- GROUPS REMOVED: a member still, and the groups go at once --------------------
{
    my $d = site();
    my $c = sign_in($d);
    users( $d, 'group-remove', 'gone', 'editors' );
    my ( $st, $b ) = page( $d, $c, '/editors' );
    is( $st, 403, 'ungrouped: the editors page is refused at once - groups are read fresh' );
    ( $st, $b ) = manager( $d, $c, 'whoami' );
    is( $st, 403, 'ungrouped: the manager refuses it (no ui)' );
    ( $st, $b ) = page( $d, $c, '/members' );
    like( $b, qr/SECRET-MEMBERS/, 'ungrouped: an account that still exists keeps its members page' );
    ( $st, $b ) = manager( $d, $c, 'me' );
    is( $st, 200, 'ungrouped: and its /account' );
}

# --- the passwordless flag rides on the same read ----------------------------------
# The wrapper flagged a passwordless account by reading the account store a second
# time; it now takes the flag from the verifier's read. A stub processor reports
# what the wrapper handed it.
{
    my $d = site();
    users( $d, 'add', 'tok', '' );
    my $stub = "$d/../stub.pl";
    spit( $stub, 'print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";'
            . 'print "USER=", ( $ENV{HTTP_X_REMOTE_USER} // "" ), " NOPW=", ( $ENV{LAZYSITE_AUTH_NO_PASSWORD} // "" ), "\n";' );
    my $gone = sign_in($d);    # first: the first sign-in mints the site secret
    my $s    = slurp("$d/lazysite/auth/.secret");
    chomp $s;
    my $mint = sub { my $p = "$_[0]:" . time() . ':'; return "$p:" . hmac_sha256_hex( $p, $s ) };
    my ( undef, $b ) = wrapped( $d, $mint->('tok'), $stub );
    like( $b, qr/USER=tok NOPW=1/, 'a passwordless account is flagged' );
    ( undef, $b ) = wrapped( $d, $gone, $stub );
    like( $b, qr/USER=gone NOPW=$/m, 'an account with a password is not' );
}

done_testing();

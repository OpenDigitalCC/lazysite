#!/usr/bin/perl
# SM183: the control-API surface behind the manager UI's site-package panel -
# site-backup-inspect (read the manifest without applying) and site-backup-delete
# (remove a package), plus the human round-trip create -> inspect -> apply ->
# delete. The package file is surface-agnostic (the same artefact the MCP
# site_backup/site_apply tools produce and consume - see t/unit/mcp/04), so a
# package created here can be applied by an agent and vice versa. Also pins the
# NAME CONFINEMENT: neither action can reach a full/content backup or an
# arbitrary file - only the lazysite-site- namespace.
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
use TestHelper   qw(repo_root grant_caps);
use MIME::Base64 qw(encode_base64);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi_s = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }

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
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi_s );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub post {
    my ( $d, $user, $groups, $qs, $obj ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user,       HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN  => csrf($user), body => encode_json( $obj // {} ) );
}
sub get {
    my ( $d, $user, $groups, $qs ) = @_;
    return mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups );
}

# --- fixture: an instance with a client sub-domain that has its own content ---
my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/backups",
    "$d/lazysite/layouts/base/themes/blue", "$d/sites/clienta" );
spit( "$d/lazysite/lazysite.conf",
    "site_name: Agency\ncontrol_api_enabled: true\n" );
spit( "$d/lazysite/auth/.secret",                        $secret );
spit( "$d/lazysite/layouts/base/layout.tt",              '[% content %]' );
spit( "$d/lazysite/layouts/base/themes/blue/theme.json", '{"name":"blue"}' );
spit( "$d/sites/clienta/index.md",                       "# Client A\n" );

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_domains' );

# Register the source domain (its own content root) and set its presentation.
ok( post( $d, 'op', 'role-op', 'action=domain-add',
        { host => 'shop.clienta.com', content_root => 'sites/clienta' } )->{ok},
    'source domain configured' );
post( $d, 'op', 'role-op', 'action=domain-set',
    { host => 'shop.clienta.com', key => 'theme', value => 'blue' } );
post( $d, 'op', 'role-op', 'action=domain-set',
    { host => 'shop.clienta.com', key => 'layout', value => 'base' } );

# --- export (create) --------------------------------------------------------
my $created = post( $d, 'op', 'role-op', 'action=site-backup-create',
    { host => 'shop.clienta.com' } );
ok( $created->{ok}, 'site-backup-create packages the domain' ) or diag encode_json($created);
my $pkg = $created->{name};
like( $pkg, qr/^lazysite-site-shop\.clienta\.com-\d{8}T\d{6}Z\.tar\.gz$/, 'package name is namespaced' );

# --- inspect (read the manifest, no apply) ----------------------------------
{
    my $r = get( $d, 'op', 'role-op', "action=site-backup-inspect&name=$pkg" );
    ok( $r->{ok}, 'site-backup-inspect reads the package' ) or diag encode_json($r);
    is( $r->{manifest}{source_host}, 'shop.clienta.com', 'inspect reports the source host' );
    ok( $r->{content_files} >= 1, 'inspect counts content files' );
    is( $r->{has_layout}, 1, 'inspect reports the bundled layout' );
}

# --- SM193 gap 1: download streams the package (manage_domains, token-accessible) -
{
    my $r   = get( $d, 'op', 'role-op', "action=site-backup-download&name=$pkg" );
    my $raw = $r->{_raw} // '';
    like( $raw, qr/Content-Disposition:\s*attachment; filename="\Q$pkg\E"/,
        'site-backup-download streams the package as an attachment' );
    like( $raw, qr{Content-Type:\s*application/gzip}, 'served as gzip' );
    my ($bodyb) = $raw =~ /\r?\n\r?\n(.*)/s;
    is( substr( $bodyb // '', 0, 2 ), "\x1f\x8b", 'the body is a real gzip stream (magic bytes)' );

    my $missing = get( $d, 'op', 'role-op',
        'action=site-backup-download&name=lazysite-site-nope-20260101T000000Z.tar.gz' );
    is( $missing->{kind}, 'not-found', 'download of an unknown site package is a clean not-found' );
}

# --- NAME CONFINEMENT: neither action escapes the lazysite-site- namespace ---
{
    # A full backup must be unreachable by inspect or delete.
    spit( "$d/lazysite/backups/lazysite-full-20260101T000000Z.tar.gz", "SECRET FULL BACKUP\n" );
    my $i = get( $d, 'op', 'role-op',
        'action=site-backup-inspect&name=lazysite-full-20260101T000000Z.tar.gz' );
    ok( !$i->{ok}, 'inspect refuses a non-site (full) backup name' );

    my $del = post( $d, 'op', 'role-op', 'action=site-backup-delete',
        { name => 'lazysite-full-20260101T000000Z.tar.gz' } );
    ok( !$del->{ok}, 'delete refuses a non-site (full) backup name' );
    ok( -f "$d/lazysite/backups/lazysite-full-20260101T000000Z.tar.gz",
        'the full backup is untouched' );

    # SM193: download must not reach a full-system backup either.
    my $dl = get( $d, 'op', 'role-op',
        'action=site-backup-download&name=lazysite-full-20260101T000000Z.tar.gz' );
    ok( !$dl->{ok}, 'download refuses a non-site (full) backup name' );
    is( $dl->{kind}, 'invalid', 'the refusal is an invalid-name error, nothing streamed' );

    # Traversal is refused too.
    my $trav = post( $d, 'op', 'role-op', 'action=site-backup-delete',
        { name => 'lazysite-site-../../auth/.secret' } );
    ok( !$trav->{ok},                  'delete refuses a traversal name' );
    ok( -f "$d/lazysite/auth/.secret", 'the auth secret is untouched' );
}

# --- apply to a fresh target domain (the human round-trip) -------------------
{
    make_path("$d/sites/dest");
    ok( post( $d, 'op', 'role-op', 'action=domain-add',
            { host => 'client.example', content_root => 'sites/dest' } )->{ok},
        'target domain configured' );

    my $ap = post( $d, 'op', 'role-op', 'action=site-backup-apply',
        { name => $pkg, host => 'client.example', clean => 1 } );
    ok( $ap->{ok}, 'site-backup-apply applies the package to the target' ) or diag encode_json($ap);
    ok( -f "$d/sites/dest/index.md", 'content landed in the target content root' );
}

# --- SM578/SM577: confinement is a property of the ACTION ------------------
# The scope check used to be skipped entirely when the caller had no
# dav_scopes, on the reading that no scope means unconfined. That is true of a
# COOKIE session - the operator, above - and false of a TOKEN grant, where it
# means nobody set one. A partner holding manage_domains and no scope therefore
# reached every domain's package on the instance, and a package is a whole
# site.
#
# THE WEAKER GRANT IS THE EVIDENCE. Everything above this point authenticates
# with the trusted header, which is the exempt path, so it could not have shown
# the gap either way.
{
    uapi( $d, { action => 'add', username => 'partner', password => 'partner-pw-0123456789' } );
    grant_caps( $d, 'partner', 'manage_domains', 'api' );
    my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
    ok( length( $tok // '' ), 'a manage_domains token partner exists, with no dav_scope' );

    my $auth = 'Basic ' . encode_base64( "partner:$tok", '' );

    my $dl = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => "action=site-backup-download&name=$pkg",
        HTTP_AUTHORIZATION => $auth );
    ok( !$dl->{ok}, 'a scopeless token partner cannot DOWNLOAD another domain\'s package' );
    is( $dl->{kind}, 'forbidden', 'and is told it is forbidden, not that it is missing' );

    my $del = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=site-backup-delete',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( { name => $pkg } ) );
    ok( !$del->{ok},                   'nor DELETE it - SM577, the irreversible half' );
    ok( -f "$d/lazysite/backups/$pkg", 'and the package is still there' );

    # SM578's second half: the listing carried no filter at all, so a name and
    # size were readable by a caller who could not open the file.
    my $ls = mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=backup-list',
        HTTP_AUTHORIZATION => $auth );
    my @names = map { $_->{name} // '' } @{ $ls->{backups} || [] };
    ok( !( grep { $_ eq $pkg } @names ),
        'and the package is not named in the listing either' );

    # ALL FOUR VERBS, not the two that happened to share a helper. The first
    # cut confined download and delete and left create and inspect carrying
    # their own inline copy of the old test - measured in the field as a
    # scopeless grant building a package for an unrelated domain and reading
    # any manifest in full.
    my $ins = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => "action=site-backup-inspect&name=$pkg",
        HTTP_AUTHORIZATION => $auth );
    ok( !$ins->{ok},       'nor INSPECT it - the manifest is the disclosure' );
    ok( !$ins->{manifest}, 'and no manifest came back' );

    my $cre = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=site-backup-create',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( { host => 'shop.clienta.com' } ) );
    ok( !$cre->{ok},
        'nor BUILD one for a host it has no relationship with' );

    # THE OPERATOR IS UNAFFECTED - the exemption is the channel, and this is
    # what says the fix did not simply break the feature for everyone.
    my $op = get( $d, 'op', 'role-op', "action=site-backup-inspect&name=$pkg" );
    ok( $op->{ok}, 'the operator, on a cookie session, still reaches the package' );
}

# --- delete (housekeeping) --------------------------------------------------
{
    my $del = post( $d, 'op', 'role-op', 'action=site-backup-delete', { name => $pkg } );
    ok( $del->{ok}, 'site-backup-delete removes the package' ) or diag encode_json($del);
    ok( !-f "$d/lazysite/backups/$pkg", 'the package file is gone' );

    my $gone = get( $d, 'op', 'role-op', "action=site-backup-inspect&name=$pkg" );
    ok( !$gone->{ok}, 'inspecting a deleted package is not-found' );
    is( $gone->{kind}, 'not-found', 'refusal is not-found' );
}

done_testing();

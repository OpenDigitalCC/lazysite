#!/usr/bin/perl
# SM085 phase 1: the content-history manager actions (git-init / git-status /
# git-history / git-show / git-restore) end to end through the manager API.
# What matters: init enables the feature and reports the adoption commit;
# reads have stable shapes, respect the deny lists and are not audited; and
# restore goes THROUGH the normal save path - the cache sibling and host
# copies are cleared, the action is audited, and the restore itself appears
# as the newest history entry.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root grant_caps);
use Lazysite::Git ();

plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

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
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf  { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }
sub op_get {
    my ( $d, $qs ) = @_;
    return mapi( $d, QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => 'admin', HTTP_X_REMOTE_GROUPS => 'managers' );
}
sub op_post {
    my ( $d, $qs, $body ) = @_;
    return mapi( $d,
        REQUEST_METHOD       => 'POST',
        HTTP_X_REMOTE_USER   => 'admin',
        HTTP_X_REMOTE_GROUPS => 'managers',
        HTTP_X_CSRF_TOKEN    => csrf('admin'),
        QUERY_STRING         => $qs,
        body                 => ( $body // '{}' ),
    );
}
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { open my $fh, '>', $_[0] or die $!; print $fh $_[1]; close $fh }

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/cache/hosts/alias.example" );
spit( "$d/lazysite/lazysite.conf", "manager: enabled\nsite_name: T\ncontrol_api_enabled: true\n" );
spit( "$d/lazysite/auth/.secret",  $secret );
spit( "$d/lazysite/auth/users",    "admin:hash\n" );
spit( "$d/page.md",                "---\ntitle: P\n---\n\nversion ONE\n" );

# --- git-init: sets the conf key, adopts the site, reports the commit --------
{
    my $r = op_post( $d, 'action=git-init' );
    ok( $r->{ok}, 'git-init ok' ) or diag explain $r;
    like( $r->{commit}, qr/\A[0-9a-f]{40}\z/, 'the adoption commit is reported' );
    ok( $r->{commits} >= 1, 'commit count reported' );
    like( slurp("$d/lazysite/lazysite.conf"), qr/^git_history: enabled$/m,
        'conf key written' );
    ok( -f "$d/lazysite/git/HEAD", 'repo initialised at lazysite/git' );

    my $again = op_post( $d, 'action=git-init' );
    ok( $again->{ok} && $again->{already}, 'a second git-init is an idempotent no-op' );
}

# --- git-status ---------------------------------------------------------------
{
    my $s = op_get( $d, 'action=git-status' );
    ok( $s->{ok} && $s->{enabled}, 'git-status: enabled after init' );
    ok( $s->{git_available},       'git-status: reports the git binary' );
    ok( $s->{commits} >= 1,        'git-status: commit count' );
    # the action now reports a real health verdict, not just the conf flag
    is( $s->{verdict}, 'ok',  'git-status: verdict ok on a healthy repo' );
    ok( $s->{healthy},        'git-status: healthy flag set on a good repo' );
}

# --- a manager save auto-commits; git-history lists the timeline ---------------
my ( $sha_adopt, $sha_edit );
{
    my $sv = op_post( $d, 'action=save&path=page.md',
        encode_json( { content => "---\ntitle: P\n---\n\nversion TWO\n" } ) );
    ok( $sv->{ok}, 'save ok' ) or diag explain $sv;

    my $h = op_get( $d, 'action=git-history&path=page.md' );
    ok( $h->{ok} && $h->{enabled}, 'git-history ok + enabled flag' );
    is( scalar @{ $h->{entries} }, 2, 'two versions of the page' );
    is( $h->{entries}[0]{subject}, 'edit page.md',        'newest: the edit, terse message' );
    is( $h->{entries}[0]{author},  'admin',               'newest: the acting user' );
    is( $h->{entries}[1]{subject}, 'adopt existing site', 'oldest: the adoption commit' );
    ok( $h->{entries}[0]{epoch} > 0, 'entries carry an epoch' );
    ( $sha_edit, $sha_adopt ) = map { $_->{sha} } @{ $h->{entries} };
}

# --- git-show: historic content + diff vs the worktree -------------------------
{
    my $s = op_get( $d, "action=git-show&path=page.md&sha=$sha_adopt" );
    ok( $s->{ok}, 'git-show ok' ) or diag explain $s;
    like( $s->{content}, qr/version ONE/, 'content of the old version' );
    like( $s->{diff},    qr/^-.*version ONE/m, 'diff: old line removed' );
    like( $s->{diff},    qr/^\+.*version TWO/m, 'diff: current worktree line added' );

    ok( !op_get( $d, 'action=git-show&path=page.md&sha=HEAD' )->{ok},
        'symbolic rev refused (sha validation)' );
    ok( !op_get( $d, "action=git-show&path=lazysite/auth/users&sha=$sha_adopt" )->{ok},
        'blocked path refused' );
    ok( !op_get( $d, "action=git-history&path=lazysite/auth/users" )->{ok},
        'git-history refuses a blocked path' );
    my $miss = op_get( $d, "action=git-show&path=page.md&sha=" . ( 'f' x 40 ) );
    ok( !$miss->{ok}, 'an unknown sha is a clean error' );
}

# --- git-restore: THROUGH the save path ----------------------------------------
{
    # a rendered sibling + a host-keyed alias copy that the save path must clear
    spit( "$d/page.html",                                   '<html>stale</html>' );
    spit( "$d/lazysite/cache/hosts/alias.example/page.html", '<html>stale host</html>' );

    my $r = op_post( $d, "action=git-restore&path=page.md&sha=$sha_adopt" );
    ok( $r->{ok}, 'git-restore ok' ) or diag explain $r;
    is( $r->{restored_from}, $sha_adopt, 'reports the restored version' );
    like( slurp("$d/page.md"), qr/version ONE/, 'the historic content is back' );
    ok( !-e "$d/page.html", 'cache sibling cleared (normal save semantics)' );
    ok( !-e "$d/lazysite/cache/hosts/alias.example/page.html",
        'host-keyed alias copy cleared too' );

    my $sha7 = substr $sha_adopt, 0, 7;
    my $h = op_get( $d, 'action=git-history&path=page.md' );
    is( $h->{entries}[0]{subject}, "restore page.md to $sha7",
        'the restore is itself the newest history entry' );
    is( $h->{entries}[0]{author}, 'admin', 'restore attributed to the acting user' );

    ok( !op_post( $d, 'action=git-restore&path=page.md&sha=nope' )->{ok},
        'restore refuses a malformed sha' );
}

# --- audit: restore recorded, reads skipped ------------------------------------
{
    # exercise a POSTed read too - the skip list must cover it
    op_post( $d, 'action=git-history&path=page.md' );
    op_post( $d, 'action=git-status' );
    my $audit = slurp("$d/lazysite/logs/audit.log") // '';
    like( $audit, qr/\| git-restore \| page\.md \|/, 'git-restore audited with its target' );
    like( $audit, qr/\| git-init \|/,                'git-init audited' );
    unlike( $audit, qr/git-history|git-show|git-status/, 'reads are not audited' );
}

# --- token-channel gating --------------------------------------------------------
{
    uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
    grant_caps( $d, 'partner', 'api', 'manage_content' );
    my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
    ok( $tok && $tok =~ /^lzs_/, 'minted partner token' );
    uapi( $d, { action => 'add', username => 'nocap', password => 'x' } );
    grant_caps( $d, 'nocap', 'api' );
    my $tok2 = uapi( $d, { action => 'token', username => 'nocap' } )->{token};

    my $h = mapi( $d, QUERY_STRING => 'action=git-history&path=page.md',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    ok( $h->{ok}, 'git-history available to a token with manage_content' );

    my $no = mapi( $d, QUERY_STRING => 'action=git-history&path=page.md',
        HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
    ok( !$no->{ok} && $no->{error} =~ /capability/i,
        'git-history denied to a token without manage_content' );

    my $ni = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=git-init',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ), body => '{}' );
    ok( !$ni->{ok} && $ni->{error} =~ /capability/i,
        'git-init needs manage_config, not just manage_content' );

    grant_caps( $d, 'partner', 'manage_config' );
    my $ni2 = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=git-init',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ), body => '{}' );
    ok( $ni2->{ok} && $ni2->{already}, 'git-init allowed with manage_config (idempotent)' );
}

# --- SM175: a move carries the page's history; a recreate at the old path does
#     not inherit it (end to end through action=move + git-history) ------------
{
    my $mv = op_post( $d, 'action=move&path=page.md&to=sub/moved.md', '{}' );
    ok( $mv->{ok}, 'move page.md -> sub/moved.md' ) or diag explain $mv;

    my $h = op_get( $d, 'action=git-history&path=sub/moved.md' );
    ok( $h->{ok} && $h->{enabled}, 'git-history on the moved path' );
    my @subj = map { $_->{subject} } @{ $h->{entries} };
    ok( ( grep { m{^move page\.md -> sub/moved\.md} } @subj ), 'shows the move commit' );
    ok( ( grep { /^edit page\.md/ } @subj ),      'history followed the rename: the pre-move edit is present' );
    ok( ( grep { /adopt existing site/ } @subj ), 'history followed back to the adoption commit' );

    # View a PRE-MOVE version through the new path: git-show resolves the historic
    # path (page.md) from the lineage and returns that version's content + a diff.
    my ($pre) = grep { $_->{subject} =~ /^edit page\.md/ } @{ $h->{entries} };
    my $sv = op_get( $d, "action=git-show&path=sub/moved.md&sha=$pre->{sha}" );
    ok( $sv->{ok}, 'git-show opens a pre-move version through the new path' ) or diag explain $sv;
    is( $sv->{from_path}, 'page.md', 'git-show reports the historic (pre-rename) path' );
    like( $sv->{content}, qr/version TWO/, 'the pre-move content is returned' );

    # Restore a pre-move version: its content lands at the CURRENT path.
    my $rs = op_post( $d, "action=git-restore&path=sub/moved.md&sha=$pre->{sha}", '{}' );
    ok( $rs->{ok}, 'git-restore of a pre-move version into the current path' ) or diag explain $rs;
    like( op_get( $d, 'action=read&path=sub/moved.md' )->{content}, qr/version TWO/,
        'the current file now holds the restored pre-move content' );

    # A fresh, unrelated page created at the OLD path starts a clean thread.
    my $nw = op_post( $d, 'action=save&path=page.md',
        encode_json( { content => "---\ntitle: New\n---\n\nunrelated\n" } ) );
    ok( $nw->{ok}, 'a new page created at the old path' );
    my @s2 = map { $_->{subject} } @{ op_get( $d, 'action=git-history&path=page.md' )->{entries} };
    ok( ( !grep { /^edit page\.md/ } @s2 ),
        'the recreated old path does NOT inherit the moved file history (no leak)' );
}

# --- SM199: git-history-summary (site-level file list + revision statistics) --
{
    my $s = op_get( $d, 'action=git-history-summary' );
    ok( $s->{ok} && $s->{enabled}, 'git-history-summary ok + enabled' ) or diag explain $s;
    ok( ref $s->{files} eq 'ARRAY' && @{ $s->{files} }, 'a non-empty file list' );
    ok( ref $s->{summary} eq 'HASH', 'a site-level summary hash' );

    my %by = map { $_->{path} => $_ } @{ $s->{files} };
    # sub/moved.md carries its lineage (adopt + edit + restore + move + restore...)
    ok( $by{'sub/moved.md'}, 'the moved page appears in the file list' );
    ok( $by{'sub/moved.md'}{revisions} >= 2,
        'the moved page counts its lineage revisions (rename followed)' );
    ok( defined $by{'sub/moved.md'}{first} && $by{'sub/moved.md'}{first} > 0,
        'a first-revision date is reported' );
    ok( defined $by{'sub/moved.md'}{latest}
            && $by{'sub/moved.md'}{latest} >= $by{'sub/moved.md'}{first},
        'latest date is at or after first' );
    like( $by{'sub/moved.md'}{last_author}, qr/\S/, 'a last author is reported' );

    # site totals are internally consistent with the rows
    is( $s->{summary}{files}, scalar @{ $s->{files} },
        'summary file count equals the number of rows' );
    my $rev = 0;
    $rev += $_->{revisions} for @{ $s->{files} };
    is( $s->{summary}{revisions}, $rev,
        'summary revision total equals the sum of per-file counts' );

    # token gating: exactly like git-history (manage_content), refused without it
    my $ok = mapi( $d, QUERY_STRING => 'action=git-history-summary',
        HTTP_AUTHORIZATION => basic( 'partner', uapi( $d, { action => 'token', username => 'partner' } )->{token} ) );
    ok( $ok->{ok}, 'git-history-summary available to a token with manage_content' );

    my $no = mapi( $d, QUERY_STRING => 'action=git-history-summary',
        HTTP_AUTHORIZATION => basic( 'nocap', uapi( $d, { action => 'token', username => 'nocap' } )->{token} ) );
    ok( !$no->{ok} && $no->{error} =~ /capability/i,
        'git-history-summary denied to a token without manage_content' );
}

done_testing();

#!/usr/bin/perl
# SM641: a failed login wrote the caller's chosen username into the audit
# trail's actor column.
#
# The column after the timestamp answers WHO. A login attempt is unauthenticated
# by definition, so the name it carries is a claim - and this file audited that
# claim as an identity, including on the branch that runs precisely BECAUSE the
# account does not exist. Anyone who could reach the login form could put a
# string of their choosing in the operator's trail, have it listed as a distinct
# actor in the Audit page's filter, have it rendered as a live link to a user
# page for an account that never existed, and have it forwarded to syslog.
#
# WHAT IS ASSERTED
#   a login for a name that is not an account is recorded against 'system'
#   the attempted name survives, in the field that reports a claim
#   it is bounded and reduced to characters an account name can hold
#   a REAL account's failed login still names that account - the fix must not
#     blind the trail to the attempts that matter most
#   'system' itself is not rewritten into a note about itself
#   the claim never reaches the actor column by any of the unverified doors
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol      qw(gensym);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";
plan skip_all => "no $auth" unless -f $auth && -f $utl;

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print {$cin} encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

sub run_auth {
    my ( $env, $body ) = @_;
    $body //= '';
    local %ENV = ( env_passthrough(), %$env, CONTENT_LENGTH => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        LAZYSITE_USERS_TOOL => $utl );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print {$wtr} $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $pid, 0;
    return $out // '';
}

sub audit_lines {
    my ($d) = @_;
    my $f = "$d/lazysite/logs/audit.log";
    return () unless -f $f;
    open my $fh, '<', $f or return ();
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

# The actor is the field after the timestamp. Parsed rather than regex-matched
# across the whole line, so an attempted name appearing in the DETAIL can never
# be mistaken for the same name appearing in the ACTOR - which is the entire
# distinction under test.
sub actors {
    my (@lines) = @_;
    return map { my @f = split /\s*\|\s*/, $_; $f[1] // '' } @lines;
}

my $src_auth = do { open my $fh, '<', $auth or die $!; local $/; <$fh> };

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
users_api( $d, { action => 'add', username => 'human', password => 'pw' } );

my %base = ( DOCUMENT_ROOT => $d, REMOTE_ADDR => '10.0.0.9', HTTPS => '' );
sub login {
    my ( $u, $p ) = @_;
    return run_auth(
        { %base, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=login' },
        "username=$u&password=" . ( $p // 'x' ) . "&next=/" );
}

# ---------------------------------------------------------------------
# 1. A name nobody ever had
# ---------------------------------------------------------------------
login( 'invented-person', 'anything' );
my @l = audit_lines($d);
cmp_ok( scalar @l, '>', 0, 'the attempt was audited at all (not vacuous)' );

my @a = actors(@l);
ok( !( grep { $_ eq 'invented-person' } @a ),
    'the invented name is NOT an actor' )
    or diag( "actors seen: " . join( ', ', @a ) );
is( $a[-1], 'system', "the actor is 'system' - nobody authenticated" );
like( $l[-1], qr/attempted username: invented-person/,
    'and the name it claimed is kept, in the field that reports a claim' );
like( $l[-1], qr/invalid-credentials/,
    'the original reason is not lost to make room for it' );

# ---------------------------------------------------------------------
# 2. A real account still names itself
# ---------------------------------------------------------------------
# The failure this guards: a fix that sent EVERY failed login to 'system' would
# hide the attempts an operator most needs - somebody working on a real account.
login( 'human', 'WRONG' );
@l = audit_lines($d);
@a = actors(@l);
is( $a[-1], 'human',
    "a real account's failed login is still recorded against that account" );
unlike( $l[-1], qr/attempted username/,
    'and it gains no note about a claim, because there was none' );

# A successful login is unaffected.
login( 'human', 'pw' );
@l = audit_lines($d);
@a = actors(@l);
is( $a[-1], 'human', 'a successful login is unchanged' );

# ---------------------------------------------------------------------
# 3. Sanitised means bounded
# ---------------------------------------------------------------------
# A pipe would split the record's own fields; a newline would forge a whole
# entry. audit_log already strips those, so what is added here is the reduction
# to characters an account name can hold, and a cap.
my $nasty = 'ev il<script>' . ( 'A' x 200 );
login( $nasty, 'x' );
@l = audit_lines($d);
@a = actors(@l);
is( $a[-1], 'system', 'a hostile name is still recorded against system' );
my ($claim) = $l[-1] =~ /attempted username: (.*)$/;
ok( defined $claim, 'the claim was recorded' );
unlike( $claim, qr/[<>]/, 'markup characters do not survive' );
like( $claim, qr/^[A-Za-z0-9._-]+$/,
    'what is written is account-name characters and nothing else' );
cmp_ok( length($claim), '<=', 64,
    'a long probe cannot flood the line it is written on' );

# WHERE THAT BOUND ACTUALLY COMES FROM, said plainly because the assertions
# above cannot tell the two apart: the login door ALREADY strips to
# [a-zA-Z0-9_.-] and caps at 64 before the writer sees anything, so through
# this door the writer's own reduction has nothing left to do. It is kept
# because the writer must not depend on every caller having done it first -
# that dependency is exactly what put an unverified name in the actor column
# in the first place. Asserted at the source, as an independent guarantee
# rather than as a claim about this path.
like( $src_auth, qr/sub _safe_attempt/,
    'the writer bounds the claim itself rather than trusting its callers' );
like( $src_auth, qr/\$n =~ s\/\[\^A-Za-z0-9\._\\\@-\]\/\?\/g;/,
    'it replaces one for one, so the shape of a hostile name survives' );
like( $src_auth, qr/substr\( \$n, 0, 64 \)/, 'and it caps the length' );

# ---------------------------------------------------------------------
# 4. Every unverified door, not just the one
# ---------------------------------------------------------------------
# Rate-limiting audits before the account is looked up; claim redemption takes
# a username straight from a public form. Both are unverified, and the check
# lives in the shared writer so neither needs to remember.
my $before = scalar audit_lines($d);
run_auth( { %base, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=claim-redeem' },
    'username=also-invented&claim=nope&password=zzz' );
@l = audit_lines($d);
SKIP: {
    skip 'claim redemption wrote no audit entry here', 2
        unless scalar @l > $before;
    @a = actors(@l);
    ok( !( grep { $_ eq 'also-invented' } @a ),
        'a claim redemption for an unknown name does not invent an actor' );
    is( $a[-1], 'system', 'it is system too' );
}

# ---------------------------------------------------------------------
# 5. The pseudo-actor is left alone
# ---------------------------------------------------------------------
# 'system' is not an account, so a rule that checked only "is this an account"
# would rewrite this file's OWN actor and append a note about itself to every
# ip-auto-blocked entry it writes.
like( $src_auth, qr/return \( \$name, \$detail \) if \$name eq 'system';/,
    "'system' passes through the check untouched" );

# ---------------------------------------------------------------------
# 6. One answer to "is this an account"
# ---------------------------------------------------------------------
# The writer and the Audit page's reader must not disagree: a second parser
# could link a name the writer refused, or refuse one the writer allowed - and
# the second makes a real account look invented.
like( $src_auth, qr/Lazysite::Auth::Settings::account_names/,
    'the writer asks the shared reader' );
my $api = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};
like( $api, qr/Lazysite::Auth::Settings::account_names/,
    'and so does the manager API' );

# ---------------------------------------------------------------------
# 7. THE ENTRIES ALREADY ON DISK
# ---------------------------------------------------------------------
# No writer-side change reaches a line that is already written, and every
# affected site has some. The manager API tells the page which of the actors in
# its answer are real accounts, so a name that was injected before the fix
# stops being offered as a link to a user page that does not exist.
SKIP: {
    my $mapi = "$root/lazysite-manager-api.pl";
    skip 'no manager api', 5 unless -f $mapi;

    # The token door is off by default (SM633's manage_services switch), and
    # this section reads through it.
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "control_api_enabled: true\n";
    close $cf;

    # A line of the shape the old writer produced, appended by hand because the
    # fixed writer can no longer create one.
    open my $fh, '>>', "$d/lazysite/logs/audit.log" or die $!;
    print {$fh} "2026-08-01T00:00:00Z | ghost-account | login | h | 1.2.3.4 | fail | ui\n";
    close $fh;

    users_api( $d, { action => 'add', username => 'reader', password => 'pw' } );
    users_api( $d, { action => 'group-settings-set', group => 'auditors',
            key => $_, value => 'on' } ) for qw(audit api);
    users_api( $d, { action => 'group-add', username => 'reader', group => 'auditors' } );
    my $tok = users_api( $d, { action => 'token', username => 'reader' } )->{token};
    skip 'could not mint an audit token', 5 unless $tok;

    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REQUEST_METHOD     => 'GET',
        CONTENT_LENGTH     => 0,
        QUERY_STRING       => 'action=audit',
        REMOTE_ADDR        => '127.0.0.1',
        HTTP_AUTHORIZATION => 'Basic '
            . MIME::Base64::encode_base64( "reader:$tok", '' ) );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) } // {};

    ok( $res->{ok}, 'the audit read answered' )
        or diag( 'payload: ' . ( $jb // $out // 'none' ) );
    skip 'no audit payload', 4 unless $res->{ok};
    ok( ref $res->{accounts} eq 'ARRAY', 'it says which actors are accounts' );
    my %acct = map { $_ => 1 } @{ $res->{accounts} || [] };
    my %seen = map { $_ => 1 } @{ $res->{users}    || [] };

    ok( $seen{'ghost-account'},
        'the injected actor is still in the trail - nothing is rewritten' );
    ok( !$acct{'ghost-account'},
        'but it is not offered as an account, so the page will not link it' );
    ok( $acct{'human'},
        'a real account IS offered - the list is not simply empty' );
}

# ---------------------------------------------------------------------
# 8. And the page honours it
# ---------------------------------------------------------------------
my $pagef = "$root/starter/manager/audit.md";
SKIP: {
    skip 'no audit page', 3 unless -f $pagef;
    my $page = do { open my $fh, '<', $pagef or die $!; local $/; <$fh> };
    like( $page, qr/if \(auditAccounts && !auditAccounts\[u\]\)/,
        'a non-account actor is not rendered as a link' );
    like( $page, qr/auditAccounts = null;/,
        'and an engine that does not send the list falls back to linking, so a '
            . 'newer page against an older engine does not stop linking real '
            . 'accounts' );
    my ($fill) = $page =~ /(function populateAuditFilters.*?\n\})/s;
    like( $fill // '', qr/auditAccounts/,
        'the list is taken before any row is rendered' );
}

done_testing();

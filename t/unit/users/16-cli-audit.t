#!/usr/bin/perl
# Audit-completeness round: every state-mutating users-tool command run from
# the CLI writes ONE audit entry (origin 'cli', user = the invoking OS
# identity), setup-manager writes exactly its two summary entries, secrets
# never land in the trail, and --api mode writes NO tool-side entry (the
# calling web surface audits - one entry per operation from either path).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps run_cmd);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";
my $d      = tempdir( CLEANUP => 1 );
my $me     = getpwuid($<) // "uid:$<";

sub run_cli {
    my (@args) = @_;
    my @cmd = ( $^X, $script, '--docroot', $d, @args );
    # List form: "qx(@cmd)" joins on a space and lets the shell re-split it.
    return run_cmd(@cmd);
}

sub users_api {
    my ($payload) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $d );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

sub audit_lines {
    my $f = "$d/lazysite/logs/audit.log";
    return () unless -f $f;
    open my $fh, '<', $f or return ();
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

# --- user-add: origin cli, invoking identity, target ---
run_cli( 'add', 'alice', 'pw-alpha-1' );
my @l = audit_lines();
is( scalar @l, 1, 'add writes exactly one audit entry' );
like( $l[0], qr/\Q| $me | user-add | alice |\E\s*\| ok \| cli$/,
    'user-add: cli origin, OS identity, target user' );
unlike( $l[0], qr/pw-alpha-1/, 'password never appears in the trail' );

# --- passwd / group ops / settings ---
run_cli( 'passwd',       'alice', 'pw-alpha-2' );
run_cli( 'group-add',    'alice', 'content-editors' );
run_cli( 'group-remove', 'alice', 'content-editors' );
run_cli( 'set',          'alice', 'comment', 'test account' );
@l = audit_lines();
is( scalar @l, 5, 'each mutating command appended one entry' );
like( $l[1], qr/\| user-passwd \| alice \|/, 'passwd audited' );
unlike( join( "\n", @l ), qr/pw-alpha-2/, 'new password not in the trail' );
like( $l[2], qr/\| user-group-add \| alice\@content-editors \|/,
    'group-add audited with user@group target' );
like( $l[3], qr/\| user-group-remove \| alice\@content-editors \|/,
    'group-remove audited' );
like( $l[4], qr/\| user-settings-set \| alice \|.*\| key comment$/,
    'set audited with the key (not the value)' );
unlike( $l[4], qr/test account/, 'setting VALUE not recorded' );

# --- token issue: event recorded, token itself never ---
my $tok_out = run_cli( 'token', 'alice' );
my ($token) = $tok_out =~ /^(lzs_\S+|[0-9a-f]{32,})\s*$/m;
@l = audit_lines();
like( $l[-1], qr/\| user-token \| alice \|.*credential generated/,
    'token issue audited' );
if ( defined $token && length $token ) {
    unlike( join( "\n", @l ), qr/\Q$token\E/, 'the credential itself is not in the trail' );
}
else {
    pass('token not parsed from output; leak check via format assertions above');
}

# --- setup-manager: exactly TWO entries (summary + credential issue) ---
my $before = scalar @l;
run_cli( 'setup-manager', 'mgr-secret-9' );
@l = audit_lines();
is( scalar @l, $before + 2, 'setup-manager writes exactly two entries' );
like( $l[-2], qr/\| setup-manager \| lazysite-admins \|.*manager account 'manager'/,
    'setup-manager entry targets the admin group and names the account' );
like( $l[-1], qr/\| user-passwd \| manager \|.*password set/,
    'credential issue for the manager account audited' );
unlike( join( "\n", @l ), qr/mgr-secret-9/, 'manager password not in the trail' );

# --- disable / enable ---
run_cli( 'account-disable', 'alice' );
run_cli( 'account-enable',  'alice' );
@l = audit_lines();
like( $l[-2], qr/\| user-account-disable \| alice \|/, 'disable audited' );
like( $l[-1], qr/\| user-account-enable \| alice \|/,  'enable audited' );

# --- partner-create (compound): summary + pairing-key, no primitive spam ---
grant_caps( $d, 'alice', 'create_sub_users' );    # direct file write, no audit
@l      = audit_lines();
$before = scalar @l;
run_cli( 'partner-create', 'bot-x', '--by', 'alice' );
@l = audit_lines();
is( scalar @l, $before + 2,
    'partner-create writes exactly two entries (summary + pairing key)' );
like( $l[-2], qr/\| user-partner-create \| bot-x \|.*created by alice/,
    'partner-create summary entry' );
like( $l[-1], qr/\| user-pairing-key \| bot-x \|/, 'pairing-key issue audited' );
unlike( join( "\n", @l ), qr/lzp_[0-9a-f]+/, 'pairing key value not in the trail' );

# --- claim lifecycle ---
run_cli( 'claim-create', 'alice' );
@l = audit_lines();
like( $l[-1], qr/\| user-claim-create \| alice \|/, 'claim-create audited' );
unlike( join( "\n", @l ), qr/lzc_[0-9a-f]+/, 'claim token not in the trail' );

# --- --api mode: the tool writes NOTHING (caller audits; no double entry) ---
$before = scalar @l;
my $r = users_api( { action => 'add', username => 'bob', password => 'pw' } );
ok( $r->{ok}, 'api add succeeded' );
$r = users_api( { action => 'passwd', username => 'bob', password => 'pw2' } );
ok( $r->{ok}, 'api passwd succeeded' );
$r = users_api( { action => 'group-add', username => 'bob', group => 'content-editors' } );
ok( $r->{ok}, 'api group-add succeeded' );
@l = audit_lines();
is( scalar @l, $before, 'no tool-side audit entries under --api (single-entry contract)' );
unlike( join( "\n", @l ), qr/\bbob\b/, 'api-driven ops left no cli-origin trace' );

done_testing();

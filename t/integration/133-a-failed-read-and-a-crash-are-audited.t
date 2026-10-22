#!/usr/bin/perl
# P24 (WORK-PLAN-0154, under SM943's rule: refusals and errors are audited).
#
# (1) The control API's `users` read sub-actions - users-detail,
#     verify-credential and the rest skipped as reads - wrote no audit row when
#     they failed. A failure is now recorded, as `user-<sub>`, by its class and
#     never its text: a read's error can echo what it was given.
# (2) A handler that crashes wrote no row on any surface: the control API's
#     process left before its audit block, and MCP answered "Tool error" and
#     recorded nothing. Each now writes one failure row naming the action, and
#     not the error's content.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui mcp manage_content manage_nav manage_users);
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
$s->add_user('op');
$s->add_user('member');
$s->grant( 'op', 'g-op', \@ALL, \@ALL );
# SM1057: the manager's door needs `ui`, which op's api/mcp group may not
# also grant (SM127) - so the cookie calls below are a manager-UI account's.
$s->add_user('mgr');
$s->grant( 'mgr', 'g-mgr', [qw(ui manage_content manage_nav manage_users)],
    [qw(ui manage_content manage_nav manage_users)] );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $tok = uapi( { action => 'token', username => 'op' } )->{token} // '';
ok( length $tok, 'the MCP caller has a token' );

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer op:$tok";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // {};
}

sub audit_lines {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}
sub new_lines { my ($before) = @_; my @l = audit_lines(); return @l[ $before .. $#l ] }

my $SECRET = 'P24-SECRET-do-not-record';

subtest 'a users read that succeeds writes no row (unchanged)' => sub {
    my $n = () = audit_lines();
    my $r = $s->call( 'mgr', 'users', body => { action => 'users-detail' } );
    ok( $r->{ok}, 'users-detail answers' ) or diag explain $r;
    is( scalar( () = new_lines($n) ), 0, 'and nothing is recorded' );
};

subtest 'a users read that fails writes one row, without its text' => sub {
    my $n = () = audit_lines();
    my $r = $s->call( 'mgr', 'users', body => { action => 'verify-credential', username => 'member',
            secret => $SECRET } );
    ok( !$r->{ok}, 'a wrong secret is not verified' );
    my @l = new_lines($n);
    is( scalar @l, 1, 'one row' ) or diag @l;
    like( $l[0] // '', qr/\|\s*mgr\s*\|\s*user-verify-credential\s*\|\s*member\s*\|.*\|\s*fail\s*\|/,
        'naming the caller, the sub-action, the account and the failure' );
    unlike( join( '', audit_lines() ), qr/\Q$SECRET\E/, 'and never the secret' );
};

subtest 'a users read whose error carries its input records the failure, not the text' => sub {
    # The users tool turns a die inside a read into { ok: 0, error: <the die> };
    # this makes verify-credential die holding the secret it was given.
    local $ENV{PERL5LIB} = join ':', "$root/t/lib", "$root/lib", ( $ENV{PERL5LIB} // () );
    local $ENV{PERL5OPT}       = '-MCrashHook';
    local $ENV{CRASH_HOOK_SUB} = 'Lazysite::Auth::Verify::verify_credential';
    local $ENV{CRASH_HOOK_MSG} = "died holding $SECRET";
    my $n = () = audit_lines();
    my $r = $s->call( 'mgr', 'users', body => { action => 'verify-credential', username => 'member',
            secret => $SECRET } );
    ok( !$r->{ok}, 'the read fails' ) or diag explain $r;
    my @l = new_lines($n);
    is( scalar @l, 1, 'one row' ) or diag @l;
    like( $l[0] // '', qr/\|\s*user-verify-credential\s*\|\s*member\s*\|.*\|\s*fail\s*\|\s*ui\s*\|\s*failed\s*$/,
        'recording that it failed' );
    unlike( join( '', audit_lines() ), qr/\Q$SECRET\E/, 'and never what the error carried' );
};

subtest 'a crashing control API handler writes one failure row' => sub {
    local $ENV{PERL5LIB} = join ':', "$root/t/lib", "$root/lib", ( $ENV{PERL5LIB} // () );
    local $ENV{PERL5OPT}       = '-MCrashHook';
    local $ENV{CRASH_HOOK_SUB} = 'Lazysite::Manager::Nav::action_nav_read';
    local $ENV{CRASH_HOOK_MSG} = "died holding $SECRET";
    my $n = () = audit_lines();
    my $r = $s->call( 'mgr', 'nav-read' );
    ok( !$r->{ok}, 'the call fails' );
    my @l = new_lines($n);
    is( scalar @l, 1, 'one row' ) or diag @l;
    like( $l[0] // '', qr/\|\s*mgr\s*\|\s*nav-read\s*\|.*\|\s*fail\s*\|.*crashed: the handler failed/,
        'naming the action and that it crashed' );
    unlike( join( '', audit_lines() ), qr/\Q$SECRET\E/, 'and never the error' );
};

subtest 'a crashing MCP tool writes one failure row' => sub {
    local $ENV{PERL5LIB} = join ':', "$root/t/lib", "$root/lib", ( $ENV{PERL5LIB} // () );
    local $ENV{PERL5OPT}       = '-MCrashHook';
    local $ENV{CRASH_HOOK_SUB} = 'Lazysite::Manager::Nav::action_nav_read';
    local $ENV{CRASH_HOOK_MSG} = "died holding $SECRET";
    my $n = () = audit_lines();
    my $r = mcp( read_nav => {} );
    like( $r->{error}{message} // '', qr/Tool error: read_nav/, 'the call answers a tool error' );
    # The token's first use writes its own `connect` row; this asks about the tool's.
    my @l = grep { !/\|\s*connect\s*\|/ } new_lines($n);
    is( scalar @l, 1, 'one row' ) or diag @l;
    like( $l[0] // '', qr/\|\s*op\s*\|\s*read_nav\s*\|.*\|\s*fail\s*\|\s*mcp\s*\|.*crashed: the handler failed/,
        'naming the tool and that it crashed' );
    unlike( join( '', audit_lines() ), qr/\Q$SECRET\E/, 'and never the error' );
};

done_testing();

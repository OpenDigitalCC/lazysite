#!/usr/bin/perl
# Q16, ruled 2026-10-12 ("Close Q16 + MCP attribution"): an MCP domain write
# names the account that made it.
#
# Manager::Domains keeps its own copy of the acting user for log attribution
# (SM154), and bridges it into Manager::Common's account for the one conf write,
# which names the content-history commit's author. The manager API and the
# domains CLI set that copy; MCP's setup_context did not, so an MCP domain_set
# logged `[domain-set] domain key set ... user=` and was committed as `unknown`
# (tmp/sm944-q16-a-probe.out). setup_context now sets Domains' copy to the
# token's account.
#
# It must not set Common's $auth_user. That is the fail-closed request context
# every S2x/S3x handler refuses on when it is empty, and MCP sets no manager
# request: setting it would open those handlers in the MCP process. So the MCP
# script runs here under a wrapper whose END block - after the tool call has
# answered, in the same process - reads both accounts and calls a fail-closed
# handler, action_domain_check, with its outbound probe a stand-in that counts
# its calls. It must refuse and probe nothing.
#
# No network: the probe is a stand-in, the install's public addresses are none.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use lib repo_root() . '/lib';
use Lazysite::Git ();

my $root = repo_root();
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';  # this process; the MCP run sets INFO
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
plan skip_all => 'mcp script missing' unless -f "$root/lazysite-mcp.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; return scalar <$fh> }

# new_site's docroot is site_tempdir()'s. The grant's group names the domain in
# its allowed_groups, so the domain rule lets the grant reach it.
my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\ngit_history: enabled\n"
        . "alias_hosts: q.example.org\nalias.q.example.org.content_root: sites/q\n"
        . "alias.q.example.org.allowed_groups: g-mcu\n" );
my $d = $s->docroot;
make_path("$d/sites/q");
spit( "$d/sites/q/index.md", "# q\n" );
my @ALL = qw(api ui mcp manage_domains manage_users manage_config manage_content manage_themes manage_layouts);
$s->add_user( 'mcu', 'pw-mcu-0123456789' );
$s->grant( 'mcu', 'g-mcu', [qw(mcp manage_domains manage_content manage_themes manage_layouts)], \@ALL );

my $init = Lazysite::Git::init( $d, 'operator' );
plan skip_all => 'content history could not initialise (no git?)'
    unless ref $init eq 'HASH' && $init->{ok};

my $token = do {
    my $e = gensym;
    my $pid = open3( my $w, my $r, $e, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$w} encode_json( { action => 'token', username => 'mcu' } );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    ( eval { decode_json($out) } || {} )->{token} // '';
};
ok( length $token, 'the grant has a token' ) or BAIL_OUT('no token');

# The wrapper: the END block runs after MCP has answered and exited, in its
# process, and records what that process holds.
my $result  = "$d/../q16-after.json";
my $wrapper = "$d/../q16-mcp-wrapper.pl";
spit( $wrapper, <<"PERL" );
use strict;
use warnings;
END {
    no warnings qw(once redefine);
    my \%r = ( ran => 1 );
    \$r{common}  = \$Lazysite::Manager::Common::auth_user;
    \$r{domains} = \$Lazysite::Manager::Domains::auth_user;
    my \$probed = 0;
    *Lazysite::Manager::Domains::domain_check        = sub { \$probed++; return { ok => 1, host => \$_[0] } };
    *Lazysite::Manager::Domains::instance_public_ips = sub { return () };
    my \$c = Lazysite::Manager::Domains::action_domain_check('q.example.org');
    \$r{check_ok}   = \$c->{ok} ? 1 : 0;
    \$r{check_kind} = \$c->{kind} // '';
    \$r{probed}     = \$probed;
    open my \$fh, '>', '$result' or die \$!;
    print {\$fh} JSON::PP::encode_json(\\\%r);
    close \$fh;
}
\@ARGV = ();
do '$root/lazysite-mcp.pl';
die \$\@ if \$\@;
PERL

sub mcp_domain_set {
    my ($value) = @_;
    unlink $result;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'domain_set',
                arguments => { host => 'q.example.org', key => 'site_name', value => $value } } } );
    local %ENV = %ENV;
    delete @ENV{ qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE
            HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL LAZYSITE_ACTING_USER) };
    $ENV{DOCUMENT_ROOT}                = $d;
    $ENV{REQUEST_METHOD}               = 'POST';
    $ENV{CONTENT_LENGTH}               = length $body;
    $ENV{HTTP_AUTHORIZATION}           = "Bearer mcu:$token";
    $ENV{LAZYSITE_LOG_LEVEL}           = 'INFO';
    $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
    my $e   = gensym;
    my $pid = open3( my $w, my $r, $e, $^X, $wrapper );
    print {$w} $body;
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb)  = $out =~ /\r?\n\r?\n(.*)/s;
    my $j     = eval { decode_json( $jb // '' ) }      || {};
    my $after = eval { decode_json( slurp($result) ) } || {};
    return ( ( $j->{result}{structuredContent} || $j->{error} || { _raw => $out } ), $err, $after );
}

sub last_commit {
    my $e = gensym;
    my $pid = open3( my $w, my $r, $e, 'git', "--git-dir=" . Lazysite::Git::git_dir($d), 'log', '-1',
        '--format=%an|%s' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    chomp $out;
    return split /\|/, $out, 2;
}

my ( $r, $err, $after ) = mcp_domain_set('MCP');

subtest 'an MCP domain_set names its account' => sub {
    ok( $r->{ok}, 'domain_set by the grant succeeds' ) or diag explain $r;
    like( slurp("$d/lazysite/lazysite.conf"), qr/^alias\.q\.example\.org\.site_name: MCP$/m, '...and is written' );
    my @lines = grep { /\[domain-set\] domain key set/ } split /\n/, $err;
    is( scalar @lines, 1, 'one domain-set log line' ) or diag $err;
    like( $lines[0]   // '', qr/\buser=mcu\b/, '...naming the token\'s account' );
    unlike( $lines[0] // '', qr/\buser=(?:\s|$)/, '...not an empty user' );
    my ( $author, $subject ) = last_commit();
    is( $subject, 'set domain key q.example.org', 'the conf write is in content history' );
    is( $author,  'mcu', '...committed with the account as its author, not unknown' );
};

subtest 'after it, Common\'s account is still nobody and a fail-closed handler refuses' => sub {
    ok( $after->{ran}, 'the wrapper ran in the MCP process after the call' ) or diag $err;
    is( $after->{domains}, 'mcu', 'Domains\' log copy names the account' );
    is( $after->{common},  '',    'Manager::Common\'s $auth_user was never set' );
    ok( !$after->{check_ok}, 'domain-check, outside a request, is refused' );
    is( $after->{check_kind}, 'forbidden', '...as forbidden' );
    is( $after->{probed},     0,           '...and its outbound probe did not run' );
};

done_testing();

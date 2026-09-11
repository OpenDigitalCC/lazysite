#!/usr/bin/perl
# SM821: whoami says what an account MAY DO and what the account IS, apart, and
# the two surfaces say it the same way.
#
# MCP's whoami handed back the whole resolved settings map under `capabilities`
# - 49 keys, 22 of them account-record fields (email, created_at, groups,
# mfa_enrolled, token_expires_at, disabled...) sitting among the capability flags
# - while the control API's held 27. And the one map carried `ui` beside
# `manager_ui`: `ui` meaning "interactive login is allowed", `manager_ui` meaning
# "holds the ui capability", with opposite values on an ordinary account.
#
# Now, on both surfaces: `capabilities` holds exactly the capability keys, as
# booleans, `ui` among them meaning the capability; `account` holds the rest,
# the login setting as `interactive_login`; the identity is `user`. One builder
# (Lazysite::Capabilities::whoami_grant) makes both blocks for both surfaces.
#
# Reproduced before the change: every assertion about shape failed on MCP, and
# the API's `ui` reported the login setting.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper               qw(repo_root env_passthrough site_tempdir);
use Lazysite::Auth::Settings qw(@CAP_KEYS);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\ncontrol_api_enabled: true\n";
close $cf;

# The resolved settings of an ordinary partner account: may sign in
# interactively, holds no manager access - the pair that read as a contradiction.
my %settings = (
    analytics => 1,                   manage_content => 1, api => 1, mcp => 1,
    ui        => JSON::PP::true,      manager_ui     => JSON::PP::false,
    email     => 'tess@example.test', display_name => 'Tess', created_at => 1_789_000_000,
    groups => ['editors'], mfa_enrolled => JSON::PP::false, token_expires_at => 1_800_000_000,
    disabled => JSON::PP::false,
);
my $stub = "$docroot/../users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json decode_json);\n"
    . 'my $s = decode_json(q{' . encode_json( \%settings ) . "});\n"
    . "print encode_json({ ok => 1, settings => \$s, groups => { editors => ['tester'] } });\n";
close $sf;
chmod 0755, $stub;

sub api_whoami {
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'tester',
        LAZYSITE_AUTH_TRUSTED => 1,
        LAZYSITE_USERS_TOOL   => $stub,
        REQUEST_METHOD        => 'GET',
        QUERY_STRING          => 'action=whoami&plugins=0',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}

sub mcp_whoami {
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'whoami', arguments => {} } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
    );
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $d    = eval { decode_json($jb) } || {};
    return eval { decode_json( $d->{result}{content}[0]{text} // '' ) } || {};
}

my %surface = ( 'control API' => api_whoami(), MCP => mcp_whoami() );
my @ACCOUNT = qw(email display_name created_at groups mfa_enrolled token_expires_at disabled);

for my $name ( sort keys %surface ) {
    my $w = $surface{$name};
    subtest $name => sub {
        ok( $w->{ok}, 'whoami answers' ) or return diag explain $w;
        is( $w->{user}, 'tester', 'the identity is `user`' );
        is_deeply( [ sort keys %{ $w->{capabilities} || {} } ], [ sort @CAP_KEYS ],
            '`capabilities` holds exactly the capability keys' );
        ok( !( grep { exists $w->{capabilities}{$_} } @ACCOUNT, 'manager_ui' ),
            'and no account field, and no second name for ui' );
        ok( !$w->{capabilities}{ui}, '`ui` is the manager capability, which this account does not hold' );
        ok( ( ref $w->{account} eq 'HASH' ), 'an `account` block' ) or return;
        is( $w->{account}{email}, 'tess@example.test', 'carrying the account record' );
        is_deeply( $w->{account}{groups}, ['editors'], 'and its groups' );
        ok( $w->{account}{interactive_login}, 'the login setting is `interactive_login`, and says yes' );
    };
}

is_deeply( $surface{MCP}{capabilities}, $surface{'control API'}{capabilities},
    'the two surfaces report the same capabilities' );
is_deeply( $surface{MCP}{account}, $surface{'control API'}{account},
    'and the same account' );

done_testing();

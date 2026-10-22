#!/usr/bin/perl
# SM1219 (#339, ruled 2026-10-20): THE VISITS PER SIGNED-IN ACCOUNT, and who may
# read them. Read by anyone with the analytics capability; a caller confined to
# some domains sees only the accounts that visited its own domains (the SM1001
# rule, as analyse_visitors already reads the traffic); a caller without
# analytics is refused. It is asked for (`by_account`), and the default reply
# carries no account name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(ui api mcp analytics);
my $s   = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nsite_url: https://main.test\n"
        . "alias_hosts: mine.test, other.test\n"
        . "alias.mine.test.content_root: sites/mine\nalias.mine.test.site_url: https://mine.test\n"
        . "alias.mine.test.allowed_groups: g-mcs\n"
        . "alias.other.test.content_root: sites/other\nalias.other.test.site_url: https://other.test\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/logs" );
for my $u (qw(op mcs mcu na)) {
    $s->add_user($u);
    $s->grant( $u, "g-$u", ( $u eq 'op' ? [qw(ui analytics)] : $u eq 'na' ? [qw(ui)] : [qw(mcp analytics)] ), \@ALL );
}

# One day of traffic: each domain has its own signed-in accounts.
my @g = gmtime;
my $log = sprintf "$d/lazysite/logs/access-%04d%02d%02d.jsonl", $g[5] + 1900, $g[4] + 1, $g[3];
my $UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
my $now = time() - 60;
{
    open my $fh, '>', $log or die $!;
    my $n = 0;
    for my $ev ( [ 'main.test', 'primary-user', 2 ], [ 'mine.test', 'mine-user', 3 ],
        [ 'other.test', 'other-user', 1 ], [ '', 'nohost-user', 1 ] )
    {
        my ( $h, $u, $times ) = @$ev;
        for my $i ( 1 .. $times ) {
            print {$fh} encode_json( { t => $now + $n++, p => "/pg", s => 200, ch => 'page', v => "vis" . length($u) . $n, ua => $UA, u => $u,
                    ( length $h ? ( h => $h ) : () ) } ) . "\n";
        }
        print {$fh} encode_json( { t => $now + $n++, p => '/anon', s => 200, ch => 'page', v => "an" . $n, ua => $UA,
                ( length $h ? ( h => $h ) : () ) } ) . "\n";
    }
    close $fh;
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(mcs mcu);

sub mcp {
    my ( $who, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'analyse_visitors', arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}
sub api { my ($q) = @_; return $s->call( 'op', 'analyse_visitors', query => "action=analyse_visitors&$q" ) }

sub accounts_of {
    my ($r) = @_;
    return { map { ( $_->{account} => $_->{visits} ) } @{ ( $r->{by_account} || {} )->{accounts} || [] } };
}

subtest 'the operator with analytics reads every domain\'s accounts' => sub {
    my $r = api('window=7&by_account=1');
    ok( $r->{ok}, 'it answers' ) or diag explain $r;
    is_deeply( accounts_of($r),
        { 'primary-user' => 2, 'mine-user' => 3, 'other-user' => 1, 'nohost-user' => 1 },
        'each account with its page requests; the anonymous visits are no row' );
    ok( !exists api('window=7')->{by_account}, 'and the default reply carries no accounts' );
    unlike( encode_json( api('window=7') ), qr/mine-user|primary-user/, '...nor an account name' );
    is_deeply( accounts_of( api('window=7&by_account=1&host=mine.test') ), { 'mine-user' => 3 }, 'one domain on request' );
};

subtest 'a grant confined to one domain reads only that domain\'s accounts' => sub {
    my $r = mcp( mcs => { window => 7, by_account => JSON::PP::true } );
    ok( $r->{ok}, 'it answers' ) or diag explain $r;
    is_deeply( accounts_of($r), { 'mine-user' => 3 }, 'its own domain\'s only' );
    unlike( encode_json($r), qr/other-user|primary-user|nohost-user/, 'and no other domain\'s account anywhere in the reply' );
};

subtest 'an unscoped grant reads the primary\'s accounts only' => sub {
    my $r = mcp( mcu => { window => 7, by_account => JSON::PP::true } );
    ok( $r->{ok}, 'it answers' ) or diag explain $r;
    is_deeply( accounts_of($r), { 'primary-user' => 2, 'nohost-user' => 1 }, 'the primary\'s traffic' );
};

subtest 'the analytics capability is needed' => sub {
    my $r = $s->call( 'na', 'analyse_visitors', query => 'action=analyse_visitors&window=7&by_account=1' );
    ok( !$r->{ok}, 'a manager account without analytics is refused' ) or diag explain $r;
    unlike( encode_json($r), qr/mine-user|primary-user/, '...and told no account' );
};

done_testing();

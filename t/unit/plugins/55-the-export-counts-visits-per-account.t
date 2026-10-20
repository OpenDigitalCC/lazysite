#!/usr/bin/perl
# SM1219 (#339): the visits per signed-in account, from the visitor log.
#
# The processor records the verified account as `u` on a visit made while signed
# in. The export carries it only when asked (`--by-account`): the default view is
# unchanged, because an account name is personal data and the capability that
# reads it is the one that may.
#
#   a row per account, most visits first: visits, agent_visits, days, last
#   an anonymous visit (no `u`) is no row, and a non-page request is not a visit
#   a declared agent's own account is counted, with its visits marked
#   the default export has no by_account
#   --host narrows it to the domains named: another domain's accounts are absent
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
plan skip_all => "no $plugin" unless -f $plugin;

my $d = site_tempdir();
make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://main.test\nalias_hosts: mine.test\n";
close $cf;

my $now = time() - 120;
my @gm  = gmtime($now);
my $ymd = sprintf '%04d%02d%02d',   $gm[5] + 1900, $gm[4] + 1, $gm[3];
my $day = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];

my $BR = 'Mozilla/5.0 (X11; Linux x86_64) Chrome/126.0 Safari/537.36';
my $i  = 0;
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
sub ev {
    my (%e) = @_;
    my %r = ( t => $now - 60 + $i++, p => '/x', s => 200, ch => 'page', v => 'v0', ua => $BR, %e );
    delete $r{$_} for grep { !defined $r{$_} } keys %r;
    print {$lf} encode_json( \%r ) . "\n";
}
ev( u => 'alice', h => 'main.test' ) for 1 .. 3;
ev( u => 'alice', h => 'mine.test' );
ev( u => 'bob',   h => 'mine.test' ) for 1 .. 2;
ev( u => 'agent1', ua => 'lazysite-agent/partner-x', h => 'main.test' ) for 1 .. 2;
ev( u => 'carol', ch => 'registry', h => 'main.test' );    # not a page request
ev( h => 'main.test' ) for 1 .. 4;                          # anonymous
close $lf;

sub run_export {
    my (@args) = @_;
    # Argument list, never a shell string (t/lint/40); stdout only, as it is JSON.
    local $ENV{DOCUMENT_ROOT} = $d;
    open my $ph, '-|', $^X, $plugin, '--export', '--docroot', $d, '--window', 7, @args
        or die "cannot run $plugin: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    return eval { decode_json($out) } || {};
}

my $r = run_export('--by-account');
ok( $r->{ok}, 'the export answers' ) or diag explain $r;
my $rows = ( $r->{by_account} || {} )->{accounts} || [];
is_deeply( [ map { $_->{account} } @$rows ], [qw(alice agent1 bob)],
    'one row per account, most visits first, ties by name; anonymous, and a non-page request, make none' );
my %by = map { ( $_->{account} => $_ ) } @$rows;
is( $by{alice}{visits}, 4, 'alice: every page request she made' );
is( $by{bob}{visits},   2, 'bob' );
is( $by{agent1}{visits},       2, 'an agent\'s token account is recorded too' );
is( $by{agent1}{agent_visits}, 2, '...and its declared-agent visits are said' );
is( $by{alice}{agent_visits},  0, 'a person\'s are not' );
is( $by{alice}{days}, 1, 'the distinct days' );
is( $by{alice}{last}, $day, 'and the latest' );
ok( length( $r->{by_account}{basis} // '' ), 'it says what it counted' );

ok( !exists run_export()->{by_account}, 'the default view carries no accounts' );
unlike( encode_json( run_export() ), qr/alice|bob|agent1/, '...and no account name anywhere in it' );

my $m = run_export( '--host', 'mine.test', '--by-account' );
ok( $m->{ok}, 'a view for one domain answers' ) or diag explain $m;
is_deeply( [ map { "$_->{account}:$_->{visits}" } @{ ( $m->{by_account} || {} )->{accounts} || [] } ],
    [ 'bob:2', 'alice:1' ], 'for mine.test only its own domain\'s visits, and only its visitors' );
unlike( encode_json($m), qr/agent1/, 'another domain\'s account is absent' );

done_testing();

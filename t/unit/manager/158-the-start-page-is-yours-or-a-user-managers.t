#!/usr/bin/perl
# SM724 through the manager API: start-page (read: current, landing, choices)
# and start-page-set. Your own account needs nothing beyond being signed in;
# another account's needs manage_users. The choices are the TARGET's. A set is
# audited against the account it changed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . q{/lazysite-manager-api.pl};

my @ALL = qw(ui manage_users manage_content manage_domains audit);
my $s   = new_site( root => repo_root() );
$s->add_user('boss');
$s->add_user('ed');
$s->grant( 'boss', 'bosses', [ 'ui', 'manage_users', 'manage_domains', 'audit' ], \@ALL );
$s->grant( 'ed', 'editors', [ 'ui', 'manage_content' ], \@ALL );
my $d = $s->docroot;

subtest 'read: your own, with your choices' => sub {
    my $r = $s->call( 'ed', 'start-page' );
    ok( $r->{ok}, 'a plain manager user reads their own' ) or diag explain $r;
    is( $r->{username}, 'ed',                  'about themselves' );
    is( $r->{current},  '',                    'nothing set yet' );
    is( $r->{landing},  '/manager/?account=1', 'so the landing is the fallback' );
    my %p = map { $_->{value} => 1 } @{ $r->{choices}{pages} };
    ok( $p{'manager:files'},    'files is offered - they hold manage_content' );
    ok( !$p{'manager:domains'}, 'domains is not - the list is THEIR reach' );
};

subtest 'read: another account needs manage_users' => sub {
    my $r = $s->call( 'ed', 'start-page', query => 'action=start-page&username=boss' );
    ok( !$r->{ok}, 'ed may not read boss\'s' );
    is( $r->{kind}, 'forbidden', 'refused as a capability matter' );
    like( $r->{error}, qr/Users & groups/, 'naming the permission' );
    $r = $s->call( 'boss', 'start-page', query => 'action=start-page&username=ed' );
    ok( $r->{ok}, 'boss (manage_users) may' ) or diag explain $r;
    my %p = map { $_->{value} => 1 } @{ $r->{choices}{pages} };
    ok( !$p{'manager:domains'}, 'and sees ED\'s choices, not their own - no domains for ed' );
};

subtest 'set: your own' => sub {
    my $r = $s->call( 'ed', 'start-page-set', body => { value => 'manager:files' } );
    ok( $r->{ok}, 'ed sets their own' ) or diag explain $r;
    $r = $s->call( 'ed', 'start-page' );
    is( $r->{current}, 'manager:files',  'and reads it back' );
    is( $r->{landing}, '/manager/files', 'as the landing' );

    $r = $s->call( 'ed', 'start-page-set', body => { value => 'manager:domains' } );
    ok( !$r->{ok}, 'a page they cannot reach is refused' );
    like( $r->{error}, qr/cannot reach the manager page 'domains'/, 'with the reason' );

    # SM781: the value under another key is not a clear. The field sent
    # {start_page: ...}, got ok:1, and found the setting silently cleared.
    $r = $s->call( 'ed', 'start-page-set', body => { start_page => 'manager:files' } );
    ok( !$r->{ok}, 'a body without `value` is refused' );
    like( $r->{error}, qr/value is required .*an empty string clears/, 'naming the key and how to clear' );
    is( $s->call( 'ed', 'start-page' )->{current}, 'manager:files', 'and the setting is untouched' );

    open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!;
    my @rows = grep { /start-page-set/ } <$fh>;
    close $fh;
    ok( @rows >= 2, 'both attempts are in the trail' );
    like( $rows[0], qr/\| ed \| start-page-set \| ed \|/, 'the target is the account, not a path' );
};

subtest 'set: another account' => sub {
    my $r = $s->call( 'ed', 'start-page-set', body => { username => 'boss', value => 'manager:files' } );
    ok( !$r->{ok} && $r->{kind} eq 'forbidden', 'ed may not set boss\'s' );
    $r = $s->call( 'boss', 'start-page-set', body => { username => 'ed', value => 'manager:index' } );
    ok( $r->{ok}, 'boss sets ed\'s' ) or diag explain $r;
    is( $s->call( 'boss', 'start-page', query => 'action=start-page&username=ed' )->{landing}, '/manager/', 'and it took' );
    $r = $s->call( 'boss', 'start-page-set', body => { username => 'ed', value => '' } );
    ok( $r->{ok}, 'and clears it' );
    is( $s->call( 'ed', 'start-page' )->{current}, '', 'cleared' );
};

done_testing();

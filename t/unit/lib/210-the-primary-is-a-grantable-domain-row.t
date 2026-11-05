#!/usr/bin/perl
# SM1332 (ruling 78): THE PRIMARY IS A GRANTABLE DOMAIN ROW, AND GRANTS ADD.
#
# Before, the primary was reached only by having no scope at all: naming an
# account's group on a secondary domain gave it a scope, and with it the primary
# went - and there was no primary row to grant it back on (the 2026-11-05 filing,
# an agent account that lost the primary when its group was added to one other
# domain). Now the primary's row carries allowed_groups like any secondary (the
# bare `allowed_groups:` line), a grant there adds the primary's scope (the
# docroot, PRIMARY_SCOPE), an account granted nothing keeps the primary as it
# always did, and only a lock (locked_users, the account's pin) takes the others
# away.
#
# Nothing changes at upgrade: the first block is today's data, and its answers
# are the ones the resolver gave before this change, written out.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::DomainAccess qw(read_domains effective_scopes effective_home_domain
    intersect_scopes DENY_ALL_SCOPE PRIMARY_SCOPE is_primary_scope);

my $DIR = tempdir( CLEANUP => 1 );

# Today's data, the filing's shape: a secondary domain naming the agents' group,
# a second one naming the editors', a lock on one account, and NO access line on
# the primary.
my $TODAY = <<'CONF';
site_name: Primary
alias_hosts: harmony.test, www.harmony.test, other.test
alias.harmony.test.content_root: sites/harmony
alias.harmony.test.allowed_groups: agent-ai
alias.www.harmony.test.content_root: sites/harmony
alias.www.harmony.test.allowed_groups: agent-ai
alias.other.test.content_root: sites/other
alias.other.test.allowed_groups: editors
alias.other.test.locked_users: pinned
CONF

sub conf {
    my ($extra) = @_;
    my $f = "$DIR/lazysite.conf";
    open my $fh, '>', $f or die "conf: $!";
    print {$fh} $TODAY, ( $extra // '' );
    close $fh;
    return read_domains($f);
}
sub scopes { my $d = shift; return [ sort( effective_scopes( $d, @_ ) ) ] }

subtest 'at upgrade, every account keeps exactly its reach' => sub {
    my $d = conf();
    is_deeply( $d->{''}{allowed_groups}, [], 'the primary row names nobody' );
    is_deeply( scopes( $d, 'free', ['nobody-group'] ), [], 'an account granted nothing: unbound, the primary' );
    is_deeply( scopes( $d, 'agent', ['agent-ai'] ), ['sites/harmony'],
        'an account scoped to a secondary keeps that scope and does NOT gain the primary' );
    is( effective_home_domain( $d, 'agent', ['agent-ai'] ), '', '...and, two hosts serving it, no single home, as before' );
    is_deeply( scopes( $d, 'both', [ 'agent-ai', 'editors' ] ), [ 'sites/harmony', 'sites/other' ],
        'two grants: both, as before' );
    is_deeply( scopes( $d, 'pinned', [ 'agent-ai', 'editors' ] ), ['sites/other'], 'a lock narrows, as before' );
    is_deeply( scopes( $d, 'pinned', ['agent-ai'] ), [DENY_ALL_SCOPE], 'a lock on an ungranted domain: nothing' );
};

subtest 'the primary row is read like any other' => sub {
    my $d = conf("allowed_groups: agent-ai, ops\nlocked_users: primary-only\n");
    is_deeply( $d->{''}{allowed_groups}, [ 'agent-ai', 'ops' ], 'allowed_groups: on the bare line' );
    is_deeply( $d->{''}{locked_users}, ['primary-only'], 'locked_users: likewise' );
    is( $d->{''}{content_root}, '', 'the primary keeps no content root of its own' );
};

subtest 'granting the primary row ADDS the primary' => sub {
    my $d = conf("allowed_groups: agent-ai\n");
    is_deeply( scopes( $d, 'agent', ['agent-ai'] ), [ PRIMARY_SCOPE, 'sites/harmony' ],
        'the agent group now reaches the primary and keeps its domain' );
    is( effective_home_domain( $d, 'agent', ['agent-ai'] ), '', 'two domains: no single home' );
    is_deeply( scopes( $d, 'ed', ['editors'] ), ['sites/other'],
        'a group the primary row does not name is unchanged' );
    is_deeply( scopes( $d, 'free', ['nobody-group'] ), [],
        'an account granted nothing anywhere still keeps the primary' );
};

subtest 'the primary granted alone' => sub {
    my $d = conf("allowed_groups: staff\n");
    is_deeply( scopes( $d, 'st', ['staff'] ), [PRIMARY_SCOPE], 'a grant naming the primary only' );
    is( effective_home_domain( $d, 'st', ['staff'] ), '', 'no secondary home' );
};

subtest 'only a pin removes the others' => sub {
    my $d = conf("allowed_groups: agent-ai, editors\n");
    is_deeply( scopes( $d, 'pinned', [ 'agent-ai', 'editors' ] ), ['sites/other'],
        'locked to other.test: the primary and harmony go, though both are granted' );
    $d = conf("allowed_groups: agent-ai\nlocked_users: agent\n");
    is_deeply( scopes( $d, 'agent', ['agent-ai'] ), [PRIMARY_SCOPE], 'pinned to the primary: the primary only' );
    $d = conf("locked_users: agent\n");
    is_deeply( scopes( $d, 'agent', ['agent-ai'] ), [],
        'pinned to a primary that names nobody: the primary, unbound, as before' );
};

subtest 'the primary scope in the sub-user ceiling meets only itself' => sub {
    my $P = PRIMARY_SCOPE;
    is_deeply( [ intersect_scopes( [$P], ['sites/a'] ) ], [DENY_ALL_SCOPE],
        'a sub-user granted the primary under a creator who lacks it: nothing' );
    is_deeply( [ sort( intersect_scopes( [ $P, 'sites/a' ], ['sites/a'] ) ) ], ['sites/a'],
        'the creator\'s one domain is what is left' );
    is_deeply( [ intersect_scopes( ['sites/a'], [$P] ) ], [DENY_ALL_SCOPE],
        'a creator granted only the primary does not lend another domain' );
    is_deeply( [ sort( intersect_scopes( [ $P, 'sites/a' ], [ $P, 'sites/b' ] ) ) ], [$P],
        'both hold the primary: the primary' );
    is_deeply( [ intersect_scopes( [], [$P] ) ], [$P], 'an unbound sub-user is held to its creator' );
};

subtest 'is_primary_scope' => sub {
    ok( is_primary_scope('/'),  '/' );
    ok( is_primary_scope('//'), '//' );
    ok( !is_primary_scope(''), 'the empty string is no scope, not the primary' );
    ok( !is_primary_scope(undef), 'undef' );
    ok( !is_primary_scope('sites/a'), 'a folder' );
    ok( !is_primary_scope(DENY_ALL_SCOPE), 'deny-all' );
};

done_testing();

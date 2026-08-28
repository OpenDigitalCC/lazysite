#!/usr/bin/perl
# SM673 follow-up: "which group does an approved stranger land in" is a flag on
# the group, not a name in a config file.
#
# The release manager's framing: 'that would be a group flag "Add anonymous user
# registrations to this group"'. It belongs there because it is a fact ABOUT a
# group, because the operator setting it can see the capability grid immediately
# below it, and because a config key is a thing somebody has to be told about.
#
# SETTING IT IS THE STRONGEST CONFERRAL THIS SYSTEM HAS: it decides what a
# person nobody has met holds on the day they are approved. So it passes the
# SAME ceiling as granting that group's capabilities one at a time - SM647 and
# SM682 answered the identical question for a domain's allowed_groups and a
# table's writable_by, and this is the third instance.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP;

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";
plan skip_all => 'users tool missing' unless -f $users;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;

sub run {
    my (@a) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $users, '--docroot', $d, @a );
    return qx($cmd 2>&1);
}
sub api {
    my ($req) = @_;
    my $json = encode_json($req);
    my $out  = qx(printf '%s' \Q$json\E | $^X \Q$users\E --api --docroot \Q$d\E 2>/dev/null);
    my $r    = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}
sub groups_of {
    my ($u) = @_;
    my $g = run('groups');
    return join ',', sort map { /^(\S+):.*\b\Q$u\E\b/ ? $1 : () } split /\n/, $g;
}

run( 'group-set', 'learners', 'ui', 'on' );
run( 'group-set', 'staff',    'ui', 'on' );

subtest 'with nothing flagged, an approved account joins nothing' => sub {
    my $r = api( { action => 'account-approve', username => 'nobody1' } );
    ok( $r->{ok}, 'approved' ) or diag( $r->{error} // '' );
    is_deeply( $r->{group}, [], 'and joins no group' )
        or diag( 'No shipped group grants only a login, so the safe default is '
            . 'to place them in nothing.' );
};

subtest 'a flagged group takes them' => sub {
    my $s = api( { action => 'group-settings-set', group => 'learners',
            key => 'registration', value => 'on' } );
    ok( $s->{ok}, 'the flag is settable' ) or diag( $s->{error} // '' );

    my $r = api( { action => 'account-approve', username => 'learner9' } );
    ok( $r->{ok}, 'approved' ) or diag( $r->{error} // '' );
    is_deeply( $r->{group}, ['learners'], 'placed in the flagged group' );
    like( groups_of('learner9'), qr/learners/, 'and the store agrees' );
};

subtest 'more than one flagged group means all of them' => sub {
    api( { action => 'group-settings-set', group => 'staff',
            key => 'registration', value => 'on' } );
    my $r = api( { action => 'account-approve', username => 'learner10' } );
    is_deeply( $r->{group}, [ 'learners', 'staff' ],
        'an approved account joins every flagged group' )
        or diag( 'An operator composing a role out of two groups expects both; '
            . 'silently picking one would be a rule nobody could discover.' );
};

subtest 'the flag is reported so the page can offer it' => sub {
    my $v = api( { action => 'group-settings-get' } );
    ok( $v->{ok}, 'the view loads' );
    ok( $v->{groups}{learners}{registration}, 'a flagged group says so' );
    ok( !$v->{groups}{staff}{registration} == !1, 'and the flag is per group' );
};

subtest 'turning it off stops them landing there' => sub {
    api( { action => 'group-settings-set', group => 'staff',
            key => 'registration', value => 'off' } );
    my $r = api( { action => 'account-approve', username => 'learner11' } );
    is_deeply( $r->{group}, ['learners'], 'only the still-flagged group' );
};

subtest 'THE CEILING: it cannot confer what the actor may not' => sub {
    # A delegate with manage_users but not manage_content. Flagging a group that
    # grants manage_content would hand it to every future registrant - which is
    # exactly the escalation SM195 exists to stop, wearing a different hat.
    run( 'group-set', 'writers', 'manage_content', 'on' );
    run( 'add', 'delegate', 'pw123456789' );
    run( 'group-set', 'delegates', 'ui', 'on' );
    run( 'group-set', 'delegates', 'manage_users', 'on' );
    run( 'group-add', 'delegate', 'delegates' );

    my $r = api( { action => 'group-settings-set', group => 'writers',
            key => 'registration', value => 'on', actor => 'delegate' } );
    ok( !$r->{ok}, 'refused for the delegate' )
        or diag( 'Ticking a box must not be a way around the ceiling that '
            . 'granting the same capability one at a time obeys.' );
    is( $r->{kind}, 'forbidden', 'as a capability matter' );
    like( $r->{error} // '', qr/manage_content/, 'naming the capability' );

    my $v = api( { action => 'group-settings-get' } );
    ok( !$v->{groups}{writers}{registration},
        'and the flag was NOT set' );
};

done_testing();

#!/usr/bin/perl
# SM669: the first test to drive a cookie-side capability gate by BEHAVIOUR.
#
# Until now %COOKIE_CAP was asserted only as source text, because nothing could
# reach it. SM660 shipped that way - its integration test was written, passed,
# and was deleted when sabotage showed the fixture never reached the gate.
#
# What made it unreachable: the manager API does not read a session cookie.
# lazysite-auth.pl verifies the cookie and vouches for the user with
# X-Remote-User plus LAZYSITE_AUTH_TRUSTED=1; the CGI reads that. A correctly
# signed cookie - one that verifies against the module in isolation - is not an
# input this program has. ManagerSession stands in for the wrapper.
#
# So this file proves the two things SM660 and SM664 asserted as declarations:
# `a+b` means BOTH and `a|b` means EITHER, on the live evaluator, and the
# refusal names the capabilities the caller is missing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_forms read_submissions manage_content manage_config);
my $s   = new_site( root => repo_root() );
$s->add_user('clerk');

sub hold { $s->grant( 'clerk', 'formfolk', [ 'ui', @_ ], \@ALL ) }

subtest 'SM660: both capabilities, and the refusal says so' => sub {
    hold('manage_forms');
    for my $act (
        qw(form-submission-delete form-submission-confirm form-submissions-delete-bulk) )
    {
        my $r = $s->call( 'clerk', $act, body => { file => 'x', id => '1', ids => ['1'] } );
        ok( ManagerSession->refused_for_capability($r), "$act is refused" )
            or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
        like( $r->{error} // '', qr/manage_forms and read_submissions/,
            "$act names BOTH capabilities" )
            or diag( 'An "or" here would mean either suffices, which is the '
                . 'defect SM660 fixed rather than the fix.' );
    }
};

subtest 'SM660: adding read_submissions is what changes the answer' => sub {
    # THE ONLY CHANGE between this and the subtest above is one capability. A
    # grant holding both from the start would prove nothing about which one
    # opened the door.
    hold( 'manage_forms', 'read_submissions' );
    for my $act (qw(form-submission-delete form-submission-confirm)) {
        my $r = $s->call( 'clerk', $act, body => { file => 'x', id => '1' } );
        ok( !ManagerSession->refused_for_capability($r),
            "$act is past the capability gate" )
            or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
    }
};

subtest 'SM664: the either-spelling still means either' => sub {
    # git-history-summary is manage_content|manage_config. If the `+` branch had
    # swallowed the `|` case this would refuse - the regression a table-reading
    # test cannot see.
    hold('manage_config');
    ok( !ManagerSession->refused_for_capability( $s->call( 'clerk', 'git-history-summary' ) ),
        'manage_config alone reaches it' );

    hold('manage_content');
    ok( !ManagerSession->refused_for_capability( $s->call( 'clerk', 'git-history-summary' ) ),
        'and so does manage_content alone' );

    hold('manage_forms');
    my $r = $s->call( 'clerk', 'git-history-summary' );
    ok( ManagerSession->refused_for_capability($r), 'and neither refuses' );
    like( $r->{error} // '', qr/manage_content or manage_config/,
        'naming both, joined by "or"' );
};

# --- SM958: a token-gated action is gated on this channel too ---------------
#
# An action with no %COOKIE_CAP line had NO capability check for a manager
# account. form-uploads-save and form-notify-save shipped that way: a manager
# without manage_forms could turn uploads on for a public form.

subtest 'SM958: the form writers need manage_forms here too' => sub {
    hold('manage_content');
    for my $act (qw(form-uploads-save form-notify-save)) {
        my $r = $s->call( 'clerk', $act, body => { form => 'contact', uploads => 'on', notify => 'off' } );
        ok( ManagerSession->refused_for_capability($r), "$act is refused without manage_forms" )
            or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
        like( $r->{error} // '', qr/manage_forms/, 'naming it' );
    }
    hold('manage_forms');
    for my $act (qw(form-uploads-save form-notify-save)) {
        my $r = $s->call( 'clerk', $act, body => { form => 'contact', uploads => 'on', notify => 'off' } );
        ok( !ManagerSession->refused_for_capability($r), "$act is past the gate with it" )
            or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
    }
};

subtest 'SM958: any token-gated action - regenerate-registries needs manage_content' => sub {
    hold('manage_forms');
    my $r = $s->call( 'clerk', 'regenerate-registries', body => { go => 1 } );
    ok( ManagerSession->refused_for_capability($r), 'refused without manage_content' )
        or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
    hold('manage_content');
    ok( !ManagerSession->refused_for_capability( $s->call( 'clerk', 'regenerate-registries', body => { go => 1 } ) ),
        'and reached with it' );
};

subtest 'SM958: the actions that decide for themselves are not capability-refused' => sub {
    # acl-set is owner-checked inside; a manager without manage_content who owns a
    # file may still set its rule. The answer may be a refusal - but not THIS one.
    hold('manage_forms');
    my $r = $s->call( 'clerk', 'acl-set', body => { path => 'x.md', read => [] } );
    ok( !ManagerSession->refused_for_capability($r), 'acl-set reaches its own ownership check' )
        or diag( 'got: ' . ( $r->{error} // '(no error)' ) );
};

done_testing();

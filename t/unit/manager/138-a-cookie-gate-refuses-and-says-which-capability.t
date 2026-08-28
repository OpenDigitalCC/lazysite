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

done_testing();

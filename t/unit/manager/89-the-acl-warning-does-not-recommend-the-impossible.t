#!/usr/bin/perl
# SM243/SM224 corrected: the acl-set warning must not advise a remedy that
# cannot work.
#
# It ended "Name those accounts individually if they need access." Measured in
# the field on 0.10.19 and then confirmed in the source: that does nothing.
#
# A rendered page takes its identity from $ENV{HTTP_X_REMOTE_USER}, which the
# auth wrapper sets after verifying an lzs_session cookie. A partner presenting
# Basic with an lzs_ token is not a signed-in user on that path at all - $user
# is EMPTY - so NO read-list entry matches it: not a @group, not the account's
# own name, not even being the rule's owner.
#
# So the advice looked like a fix, produced no error, and left the page still
# redirecting to /login. That is worse than saying nothing: it costs a round of
# work and ends with the agent doubting its own reading rather than the advice.
#
# THE NUANCE THAT KEEPS THE FIX SMALL, and which the warning must carry: the
# partner is NOT locked out of the content. It reads the same files over WebDAV
# and the control API throughout. Only the rendered, session-authenticated view
# is closed to it, which may well be correct - so the warning states a fact
# instead of proposing a feature.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/intranet" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Manager::Files::auth_user = 'owner';
    # The ACL store lives under lazysite/, and Acl.pm needs its own context or
    # it concatenates undef into the store path and the subtest dies before
    # asserting anything.
    $Lazysite::Auth::Acl::DOCROOT      = $d;
    $Lazysite::Auth::Acl::LAZYSITE_DIR = "$d/lazysite";
    return $d;
}

sub warn_text {
    my (%acl) = @_;
    fixture();
    # ( path, user, read, write, owner, draft ) - positional.
    my $r = Lazysite::Manager::Files::action_acl_set( 'intranet', 'owner',
        $acl{read} || [], $acl{write} || [], 'owner', 0 );
    return join ' ', @{ $r->{warnings} || [] };
}

subtest 'the impossible remedy is gone' => sub {
    my $w = warn_text( read => ['@team'] );
    unlike( $w, qr/Name those accounts individually/i,
        'it no longer tells you to do the thing that does not work' )
        or diag( 'Following it costs a round of work, produces no error, and '
            . 'leaves the page redirecting to /login.' );
};

subtest 'and the reason is stated, for a group entry' => sub {
    my $w = warn_text( read => [ '@team', '@ai-team' ] );
    like( $w, qr/\@team/, 'the groups are named' );
    like( $w, qr/carry no groups/, 'a @group cannot match a partner' );
    like( $w, qr/DOES NOT HELP ON THE RENDERED PAGE/i,
        'and naming an account is called out as no help either' )
        or diag( 'That is the correction: both halves fail, for the same '
            . 'reason - there is no signed-in user on that path.' );
};

subtest 'an ordinary account-only ACL does NOT warn' => sub {
    # A first attempt at this correction ALSO fired whenever an account was
    # named, reasoning that an agent who had followed the old advice deserved
    # to be told it had not worked. t/unit/manager/73 caught that: a rule like
    # read: [alice], where alice is a signed-in manager, is an ordinary and
    # entirely working ACL. Warning about it is noise on the common case, and
    # noise is how a warning that matters gets skipped.
    #
    # The concern dissolves anyway: the advice is gone, so there is nothing to
    # report back on.
    my $w = warn_text( read => ['alice'] );
    unlike( $w, qr/RENDERED PAGE/i,
        'a plain account ACL is left alone' )
        or diag( 'Alice is a signed-in manager and the rule works for her. '
            . 'A warning here would fire on most ACLs on most sites.' );
};

subtest 'it says what still WORKS, not only what does not' => sub {
    my $w = warn_text( read => ['@team'] );
    like( $w, qr/WebDAV and the control API/,
        'the partner still reads the content over its own channels' )
        or diag( 'Without this the warning reads as "your partner is locked '
            . 'out", which is false and would send someone unpicking a rule '
            . 'that is working.' );
    like( $w, qr/it is working/,
        'and that the rule does its job against public visitors' );
};

subtest 'no ACL entries, no warning' => sub {
    my $w = warn_text( read => [] );
    unlike( $w, qr/RENDERED PAGE/i, 'a rule naming nobody warns about nobody' );
};

done_testing();

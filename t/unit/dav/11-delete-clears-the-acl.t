#!/usr/bin/perl
# SM212 (site-agent 0.10.7 report): a WebDAV DELETE left the path's ACL entry
# behind, and the entry outlives the content.
#
# Why that matters is not tidiness. Create a file at the same path later - by any
# surface - and it is born governed by a rule nobody set, owned by whoever owned
# the file that used to be there. The manager's delete has always cleared the
# entry; WebDAV never did, so the two surfaces disagreed about what deleting
# means, and the disagreement is only visible later.
#
# The path is checked through the REAL DAV surface rather than by calling
# do_delete, because the defect was in what the handler did after a successful
# unlink - a unit call on the pieces would have agreed with itself.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper          qw(setup_dav_site run_dav);
use Lazysite::Auth::Acl ();

sub acls_for {
    my ($doc) = @_;
    local $Lazysite::Auth::Acl::DOCROOT = $doc;
    return Lazysite::Auth::Acl::load_acls();
}

sub set_acl {
    my ( $doc, $key, $rec ) = @_;
    local $Lazysite::Auth::Acl::DOCROOT = $doc;
    my $a = Lazysite::Auth::Acl::load_acls();
    $a->{$key} = $rec;
    Lazysite::Auth::Acl::save_acls($a) or die "cannot write acls";
    return;
}

subtest 'deleting a file takes its ACL entry with it' => sub {
    my $s   = setup_dav_site();
    my $doc = $s->{docroot};
    my $a   = $s->{auth};

    my $put = run_dav( $doc, 'PUT', '/content/gone.md',
        body => "x", HTTP_AUTHORIZATION => $a );
    ok( $put->{code} == 201, 'the file is created' );

    # A neighbour that must survive, so "the store was cleared" cannot pass by
    # emptying it.
    run_dav( $doc, 'PUT', '/content/stays.md', body => "y",
        HTTP_AUTHORIZATION => $a );

    set_acl( $doc, 'content/gone.md',  { owner => 'alice', read => ['alice'] } );
    set_acl( $doc, 'content/stays.md', { owner => 'alice', read => ['alice'] } );

    my $del = run_dav( $doc, 'DELETE', '/content/gone.md',
        HTTP_AUTHORIZATION => $a );
    is( $del->{code}, 204, 'DELETE succeeds' );

    my $after = acls_for($doc);
    ok( !exists $after->{'content/gone.md'},
        'the ACL entry is gone - otherwise a file later created at this path '
            . 'is born governed by a rule nobody set' );
    ok( exists $after->{'content/stays.md'},
        'the control: the neighbour keeps its entry' );
};

subtest 'deleting a collection takes its descendants with it' => sub {
    my $s   = setup_dav_site();
    my $doc = $s->{docroot};
    my $a   = $s->{auth};

    run_dav( $doc, 'MKCOL', '/content/team', HTTP_AUTHORIZATION => $a );
    run_dav( $doc, 'PUT', '/content/team/plan.md', body => "p",
        HTTP_AUTHORIZATION => $a );
    run_dav( $doc, 'PUT', '/content/keep.md', body => "k",
        HTTP_AUTHORIZATION => $a );

    set_acl( $doc, 'content/team',         { owner => 'alice', read => ['alice'] } );
    set_acl( $doc, 'content/team/plan.md', { owner => 'alice', read => ['bob'] } );
    set_acl( $doc, 'content/keep.md',      { owner => 'alice', read => ['alice'] } );

    my $del = run_dav( $doc, 'DELETE', '/content/team',
        HTTP_AUTHORIZATION => $a );
    is( $del->{code}, 204, 'DELETE of a collection succeeds' );

    my $after = acls_for($doc);
    ok( !exists $after->{'content/team'}, "the folder's own entry is gone" );
    ok( !exists $after->{'content/team/plan.md'},
        'and its descendants - the paths they name no longer exist' );
    ok( exists $after->{'content/keep.md'},
        'the control: a sibling outside the deleted folder is untouched' );
};

subtest 'a prefix that merely SHARES a name is not swept' => sub {
    # `content/team` must not take `content/teamwork.md` with it. The match is on
    # path segments, not on string prefix - the same distinction as SEC-2026-07
    # H3, where a bare prefix test let public_html.bak pass as public_html.
    my $s   = setup_dav_site();
    my $doc = $s->{docroot};
    my $a   = $s->{auth};

    run_dav( $doc, 'MKCOL', '/content/team', HTTP_AUTHORIZATION => $a );
    run_dav( $doc, 'PUT', '/content/teamwork.md', body => "t",
        HTTP_AUTHORIZATION => $a );

    set_acl( $doc, 'content/team',        { owner => 'alice', read => ['alice'] } );
    set_acl( $doc, 'content/teamwork.md', { owner => 'alice', read => ['alice'] } );

    run_dav( $doc, 'DELETE', '/content/team', HTTP_AUTHORIZATION => $a );

    my $after = acls_for($doc);
    ok( !exists $after->{'content/team'}, 'the folder entry went' );
    ok( exists $after->{'content/teamwork.md'},
        'and the file whose name merely starts the same way did NOT' );
};

done_testing();

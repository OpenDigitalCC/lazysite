#!/usr/bin/perl
# CF-2 (SM430): deleting content must drop its rules; moving content must
# carry them. Both were true on ONE surface each, in opposite directions.
#
#   DAV DELETE dropped ACL entries (SM212) - the manager's delete did not.
#   The manager's move re-keyed and re-synced the store - DAV's move had no
#   ACL code at all.
#
# The comment at lazysite-dav.pl claiming "the manager's delete has always
# done this" was simply false, so SM212's fix reached one surface out of four.
#
# THE MOVE HALF IS THE ONE THAT MATTERS. WebDAV resolves a gated path into the
# PRIVATE store, so a MOVE to an ungated destination physically relocated the
# bytes into the public docroot - and with no re-key, no rule followed them.
# Protected content became public through an ordinary operation, silently.
# That is the exact inverse of SM286: protecting content moves it, so moving
# content has to carry its protection.
#
# Asserted against the ACL STORE FILE, never against an action's own report -
# a handler that says it cleaned up is exactly what was believed for four
# surfaces and four releases.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/docs" );
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Auth::Acl::DOCROOT       = $d;
    $Lazysite::Auth::Acl::LAZYSITE_DIR  = "$d/lazysite";
    return $d;
}

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

sub store {
    my ($d) = @_;
    my $p = "$d/lazysite/auth/acls.json";
    return {} unless -f $p;
    open my $fh, '<', $p or return {};
    local $/;
    return decode_json(<$fh>) // {};
}

subtest 'the shared helpers do what their names say' => sub {
    my $d = fixture();
    Lazysite::Auth::Acl::save_acls( {
            'docs'           => { owner => 'op' },
            'docs/a.md'      => { owner => 'op', read => ['members'] },
            'docs/sub/b.md'  => { owner => 'op' },
            'elsewhere/c.md' => { owner => 'op' },

            # THE DISCRIMINATING KEY. 'docs-archive' starts with 'docs' as a
            # STRING but is not under it as a PATH - the same trap validate_path
            # documents for public_html vs public_html.bak. A bare
            # index($k,$key)==0 eats it, and no other key here would notice:
            # the sabotage making exactly that mistake passed until this
            # existed.
            'docs-archive/d.md' => { owner => 'op' },
    } );

    is( Lazysite::Auth::Acl::forget_path('docs'), 3,
        'forget_path takes the key and its descendants' );
    my $left = store($d);
    ok( !exists $left->{'docs/a.md'},     'descendant gone' );
    ok( exists $left->{'elsewhere/c.md'}, 'an unrelated key is untouched' );
    ok( exists $left->{'docs-archive/d.md'},
        'and a SIBLING whose name merely starts with the key survives - a '
            . 'prefix is not a substring' );

    Lazysite::Auth::Acl::save_acls(
        { 'old/x.md' => { owner => 'op', read => ['members'] } } );
    is( Lazysite::Auth::Acl::rekey_path( 'old/x.md', 'new/x.md' ), 1,
        'rekey_path moves the entry' );
    my $after = store($d);
    ok( !exists $after->{'old/x.md'}, 'the old key is gone' );
    is_deeply( $after->{'new/x.md'}{read}, ['members'],
        'and the rule arrived intact at the new key' );
};

subtest 'THE MANAGER DELETE now drops the rule (it never did)' => sub {
    my $d = fixture();
    spit( "$d/docs/gone.md", "x\n" );
    Lazysite::Auth::Acl::save_acls(
        { 'docs/gone.md' => { owner => 'op', read => ['members'] } } );

    my $r = Lazysite::Manager::Files::action_delete( 'docs/gone.md', 'op' );
    ok( $r->{ok}, 'deleted' ) or diag explain $r;

    ok( !exists store($d)->{'docs/gone.md'},
        'the entry went with the file' )
        or diag( 'An entry outlives the file it governs: a file created later '
            . 'at the same path is born governed by a rule nobody set, owned '
            . 'by whoever owned the file that used to be there.' );
};

subtest 'a deleted DIRECTORY takes its descendants with it' => sub {
    my $d = fixture();
    make_path("$d/docs/section");
    Lazysite::Auth::Acl::save_acls( {
            'docs/section'      => { owner => 'op', draft => 1 },
            'docs/section/p.md' => { owner => 'op' },
            'docs/keep.md'      => { owner => 'op' },
    } );
    my $r = Lazysite::Manager::Files::action_delete( 'docs/section', 'op' );
    ok( $r->{ok}, 'directory deleted' ) or diag explain $r;
    my $left = store($d);
    ok( !exists $left->{'docs/section'},      'the section rule is gone' );
    ok( !exists $left->{'docs/section/p.md'}, 'and its descendant' );
    ok( exists $left->{'docs/keep.md'},       'a sibling survives' );
};

subtest 'CONTROL: an ordinary delete with no rule still works' => sub {
    # A cleanup that only fires when there IS a rule must not break the case
    # where there is not - and every assertion above would pass regardless.
    my $d = fixture();
    spit( "$d/docs/plain.md", "x\n" );
    my $r = Lazysite::Manager::Files::action_delete( 'docs/plain.md', 'op' );
    ok( $r->{ok},               'deleted' ) or diag explain $r;
    ok( !-f "$d/docs/plain.md", 'and the file really went' );
};

done_testing();

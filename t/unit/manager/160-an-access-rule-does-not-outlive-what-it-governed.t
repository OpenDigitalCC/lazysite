#!/usr/bin/perl
# SM936 AO1-AO4: an access rule is a statement about a thing, and it does not
# outlive the thing.
#
# The filing was measured on a live site at 0.14.4: draft a page, delete it,
# write a DIFFERENT page at the same path, and the new page is born governed by
# a rule nobody set. It failed safe there - `draft` withholds - and the argument
# for building it is that THE DIRECTION OF THE ACCIDENT IS NOT A PROPERTY OF THE
# MECHANISM.
#
# WHAT THIS FILE PINS, AND WHY IT IS SHAPED AS FOUR QUESTIONS. Measuring the
# four steps against THIS tree gave three different answers, so a single
# "SM936 is fixed" assertion would have been wrong in three ways:
#
#   pages (AO1)  - already fixed, by CF-2 in action_delete. Does NOT reproduce.
#                  Pinned anyway: it is the case the filing is named for, and
#                  nothing else asserts it from the delete side.
#   move  (AO4)  - already correct: the rule re-keys with the content.
#   tables (AO3) - REPRODUCED. Table rules live in the same store, keyed
#                  `lazysite/db/tables/<name>`, and drop_table never touched it.
#                  This is the GRANT direction: a table recreated under the same
#                  name answered `read: [@volunteers]` to a group nobody granted,
#                  with an owner who had not made it.
#   create (AO2) - the remaining silence, and it is by DESIGN rather than a leak:
#                  a rule on an ANCESTOR governs a page created under it, which
#                  is correct, and the create said nothing at all.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Auth::Acl        ();
use Lazysite::Manager::Files   ();
use Lazysite::Manager::Common  ();
use Lazysite::Data::Access     ();
use Lazysite::Data::Tables     ();

my $doc = site_tempdir();
make_path("$doc/lazysite/auth");
make_path("$doc/lazysite/db/tables");
make_path("$doc/videos");
make_path("$doc/lazysite/manager/locks");
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# Manager::Files takes validate_path from Manager::Common, which keeps its OWN
# $DOCROOT. Setting only the first two leaves validate_path resolving against
# undef and every write refusing a path it never looked at - which, while
# measuring this filing, produced a confident "the defect reproduces" that was
# the rig and not the engine.
$Lazysite::Auth::Acl::DOCROOT       = $doc;
$Lazysite::Manager::Files::DOCROOT  = $doc;
$Lazysite::Manager::Common::DOCROOT = $doc;
$Lazysite::Manager::Common::auth_user = 'owner';
$Lazysite::Manager::Files::LOCK_DIR   = "$doc/lazysite/manager/locks";

sub set_rule {
    my ( $key, %rule ) = @_;
    my $a = Lazysite::Auth::Acl::load_acls();
    $a->{$key} = { owner => 'owner', %rule };
    Lazysite::Auth::Acl::save_acls($a) or die 'save_acls';
}
sub rule_at {
    my ($key) = @_;
    return Lazysite::Auth::Acl::load_acls()->{$key};
}
sub write_page {
    my ( $rel, $body ) = @_;
    open my $fh, '>', "$doc/$rel" or die "$rel: $!";
    print {$fh} $body;
    close $fh;
}

my $PAGE = 'videos/marcello-leucci.md';

subtest 'AO1: a deleted page takes its rule with it' => sub {
    write_page( $PAGE, "---\ntitle: First\n---\nThe first page.\n" );
    set_rule( $PAGE, draft => 1 );
    ok( rule_at($PAGE), 'the rule is set' );

    my $r = Lazysite::Manager::Files::action_delete( "/$PAGE", 'owner' );
    ok( $r->{ok}, 'the page was deleted' ) or diag explain $r;
    ok( !-f "$doc/$PAGE", 'and is gone from disk' );

    ok( !rule_at($PAGE), 'THE RULE IS GONE TOO' )
        or diag( 'A rule on a content path is a statement about that content. '
            . 'When the content goes the statement has no subject, and it '
            . 'waits in the store to be inherited by whatever arrives next at '
            . 'the same spelling.' );

    # The step that made the filing: a DIFFERENT page at the same path.
    write_page( $PAGE, "---\ntitle: Second\n---\nDeliberately public.\n" );
    is( Lazysite::Auth::Acl::gating_for( $doc, $PAGE ), 'open',
        'a new page at that path is NOT born gated' )
        or diag( 'This is the reported case: 201 Created, then 404 to the '
            . 'public, and nothing on any surface saying why.' );
};

subtest 'AO4: a move takes the rule WITH the content, not off it' => sub {
    set_rule( $PAGE, read => ['@volunteers'] );
    my $mv = Lazysite::Manager::Files::action_move(
        "/$PAGE", '/videos/renamed.md', 'owner' );
    ok( $mv->{ok}, 'the page moved' ) or diag explain $mv;

    ok( !rule_at($PAGE), 'the old key carries no rule' );
    my $moved = rule_at('videos/renamed.md');
    ok( $moved, 'and the NEW key does' )
        or diag( 'The opposite failure to AO1 and just as bad: a move that '
            . 'dropped the rule would make a gated page public by relocating '
            . 'it, which is a one-step way to publish something private.' );
    is_deeply( $moved->{read}, ['@volunteers'], 'with the same read list' );

    my $a = Lazysite::Auth::Acl::load_acls();
    delete $a->{$_} for keys %$a;
    Lazysite::Auth::Acl::save_acls($a);
    unlink "$doc/videos/renamed.md";
};

subtest 'AO3: a dropped table takes its rule with it' => sub {
    my $TABLE = 'enquiries';
    my $KEY   = Lazysite::Data::Access::acl_key($TABLE);

    my $desc = sub {
        open my $df, '>', "$doc/lazysite/db/tables/$TABLE.yaml" or die $!;
        print {$df} "key: code\nfields:\n  code:\n    type: text\n"
            . "    required: true\n  $_[0]:\n    type: text\n";
        close $df;
    };
    $desc->('who');
    my $mk = Lazysite::Data::Tables::apply_schema( $doc, $TABLE );
    ok( $mk->{ok}, 'the table was created' ) or diag explain $mk;

    # A GROUP read, because that is the direction that matters: the filing's
    # own point is that the same mechanism grants as quietly as it withholds.
    set_rule( $KEY, read => ['@volunteers'] );
    ok( rule_at($KEY), 'the table carries a read rule' );

    my $dr = Lazysite::Data::Tables::drop_table(
        $doc, $TABLE, actor => 'owner', confirm => $TABLE );
    ok( $dr->{ok}, 'the table was dropped' ) or diag explain $dr;

    ok( !rule_at($KEY), 'THE TABLE RULE IS GONE TOO' )
        or diag( 'Measured before this was built: it survived, and a table '
            . 'recreated under the same name answered read=@volunteers with '
            . 'an owner who had not made it - a read granted to a group '
            . 'nobody granted it to.' );
    is( $dr->{acl_forgotten}, 1, 'and the drop SAYS it removed one' )
        or diag( 'Silently doing the right thing leaves an operator unable to '
            . 'tell this version from the one that did not.' );

    # The recreate, to prove the grant is really gone rather than merely absent
    # from the store for some other reason.
    $desc->('different');
    my $mk2 = Lazysite::Data::Tables::apply_schema( $doc, $TABLE );
    ok( $mk2->{ok}, 'the table was recreated' );
    ok( !rule_at($KEY), 'and the new table is governed by nothing' );
};

subtest 'AO2: a page born gated under an ancestor rule says so' => sub {
    my $a = Lazysite::Auth::Acl::load_acls();
    delete $a->{$_} for keys %$a;
    Lazysite::Auth::Acl::save_acls($a);

    # A rule on the FOLDER. This is correct behaviour - an ancestor governs
    # what is under it - and the point is that the create was silent about it.
    set_rule( 'videos', read => ['@volunteers'] );

    my $sr = Lazysite::Manager::Files::action_save( '/videos/new-one.md',
        'someone-else', "---\ntitle: New\n---\nMeant to be public.\n", undef );
    ok( $sr->{ok}, 'the page saved' ) or diag explain $sr;
    is( $sr->{created}, 1, 'as a create' );

    ok( $sr->{acl_in_force}, 'the reply NAMES the rule in force' )
        or diag( 'Without it: an author publishes a page meant to be public, '
            . 'it 404s to the world, and the create that caused it reported '
            . 'four fields none of which was the reason.' );
    like( $sr->{acl_in_force}, qr/videos/,
        'and says WHERE the rule sits' )
        or diag( 'The page has no rule of its own, so "there is a rule" is '
            . 'the unhelpful half - which folder is the answer.' );
    like( $sr->{acl_in_force}, qr/ancestor/,
        'marking it as inherited rather than its own' );

    # NOT ON EVERY WRITE. A save over an existing page is not the moment of
    # surprise, and a field on every write is one an agent learns to skip.
    my $sr2 = Lazysite::Manager::Files::action_save( '/videos/new-one.md',
        'someone-else', "---\ntitle: New\n---\nEdited.\n", undef );
    ok( $sr2->{ok}, 'a second save works' );
    is( $sr2->{created}, 0, 'and is not a create' );
    ok( !exists $sr2->{acl_in_force},
        'so it does NOT repeat the notice' );

    # AND NOT WHEN NOTHING GATES THE PATH - the discriminating half, without
    # which the assertion above would pass on a field set unconditionally.
    my $a2 = Lazysite::Auth::Acl::load_acls();
    delete $a2->{$_} for keys %$a2;
    Lazysite::Auth::Acl::save_acls($a2);
    my $sr3 = Lazysite::Manager::Files::action_save( '/videos/ungated.md',
        'someone-else', "---\ntitle: Open\n---\nPublic.\n", undef );
    ok( $sr3->{ok}, 'an ungated create works' );
    is( $sr3->{created}, 1, 'as a create' );
    ok( !exists $sr3->{acl_in_force},
        'and carries no notice, because nothing gates it' );
};

subtest 'SM1242: a page rule keyed by its STEM goes with the page' => sub {
    # #372b, from the xisl.com site agent: delete_page removed the page and its
    # draft rule stayed. CF-2 drops the page's own key (AO1 above); a rule set on
    # "/about" is stored as `about`, governs about.md, and was left behind.
    my $a = Lazysite::Auth::Acl::load_acls();
    delete $a->{$_} for keys %$a;
    Lazysite::Auth::Acl::save_acls($a);

    write_page( 'videos/stem.md', "---\ntitle: S\n---\nS.\n" );
    set_rule( 'videos/stem', draft => 1 );
    my $r = Lazysite::Manager::Files::action_delete( '/videos/stem.md', 'owner' );
    ok( $r->{ok}, 'the page was deleted' ) or diag explain $r;
    ok( !rule_at('videos/stem'), 'THE STEM RULE IS GONE TOO' );
    write_page( 'videos/stem.md', "---\ntitle: New\n---\nNew.\n" );
    is( Lazysite::Manager::Files::_acl_gates_public( Lazysite::Auth::Acl::load_acls()->{'videos/stem'} ), 0,
        'and a new page there is not born a draft' );
    unlink "$doc/videos/stem.md";

    # The discriminating half: where a FOLDER of that name exists, the stem key
    # is the folder's rule, and deleting the landing page must not remove it.
    make_path("$doc/videos/section");
    write_page( 'videos/section.md', "---\ntitle: L\n---\nL.\n" );
    set_rule( 'videos/section', draft => 1 );
    set_rule( 'videos/section/inner.md', read => ['@volunteers'] );
    $r = Lazysite::Manager::Files::action_delete( '/videos/section.md', 'owner' );
    ok( $r->{ok}, 'the landing page of a folder was deleted' ) or diag explain $r;
    ok( rule_at('videos/section'), 'and the folder\'s rule stays' );
    ok( rule_at('videos/section/inner.md'), 'and so does a rule beneath it' );
};

done_testing();

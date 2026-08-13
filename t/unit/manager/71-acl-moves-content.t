#!/usr/bin/perl
# SM286, the flip: protecting content MOVES it out of the document root, and
# un-protecting it moves it back.
#
# This is the point of the work item. Until now a gate was a rule the engine
# honoured and every front end had to be told about separately - and three
# releases running a front end was not told, or was told and answered first
# (SM248, SM268 H17, SM283). SM283 ran live across a fleet for weeks: a
# protected section gated its pages and served its images and PDFs to anyone who
# knew the path, because Hestia's nginx answered by file extension before Apache
# ever saw the request.
#
# Moving the bytes makes the rule structural rather than advisory. There is
# nothing left in the served tree for a front end to get wrong.
#
# The invariant that matters most here is EXACTLY ONE TREE. A copy left behind in
# the docroot is the precise exposure this removes, so the assertions below check
# both sides of every move, never just the destination.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  qw(action_acl_set action_acl_remove);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       qw(load_acls);
use Lazysite::Private         qw(private_path stray_public);
use JSON::PP                  ();

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path("$d/lazysite/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

subtest 'gating a folder moves it out of the document root' => sub {
    spit( "$d/members/brief.md",      "SECRET\n" );
    spit( "$d/members/plan.pdf",      "PDFBYTES\n" );
    spit( "$d/members/deep/notes.md", "DEEP\n" );

    my $r = action_acl_set( 'members/', 'alice', ['alice'], undef, undef, undef );
    ok( $r->{ok}, 'the permission is accepted' ) or diag( $r->{error} // '' );

    ok( !-e "$d/members",
        'and the folder is GONE from the document root - which is what makes '
            . 'the rule structural instead of advisory' );
    is( slurp( private_path( $d, 'members/brief.md' ) ), "SECRET\n",
        'the page is in the private store' );
    is( slurp( private_path( $d, 'members/plan.pdf' ) ), "PDFBYTES\n",
        'and so is the PDF - the SM283 case exactly, where the page was gated '
            . 'and the asset beside it was served to anyone' );
    is( slurp( private_path( $d, 'members/deep/notes.md' ) ), "DEEP\n",
        'nested content moves with it' );

    ok( !stray_public( $d, 'members/brief.md' ),
        'and nothing is left in BOTH trees - a stray public copy is the very '
            . 'exposure this removes' );

    # The stored KEY has no trailing slash: validate_path derives `rel` from
    # realpath. Worth pinning, because a reader that assumes the slash skips
    # every rule the writer produces - which is exactly what the "held back"
    # panel did (SM292, covered in t/unit/manager/72).
    ok( exists load_acls()->{'members'},
        'the rule is stored, under the key the writer really produces' )
        or diag( 'keys: ' . join ', ', map { "'$_'" } keys %{ load_acls() } );
};

subtest 'removing the rule brings it back' => sub {
    my $r = action_acl_remove( 'members/', 'alice' );
    ok( $r->{ok},      'the removal is accepted' ) or diag( $r->{error} // '' );
    ok( $r->{removed}, 'and reports that it removed something' );

    is( slurp("$d/members/brief.md"),      "SECRET\n", 'the page is public again' );
    is( slurp("$d/members/deep/notes.md"), "DEEP\n",   'nested content too' );
    ok( !-e private_path( $d, 'members/brief.md' ),
        'and it is no longer in the store - one tree, never two' );
};

subtest 'a write-only rule publishes exactly as before' => sub {
    # The semantics come from Acl::_acl_allows: an absent or empty read list
    # allows EVERYONE. So a rule naming only a write list restricts editing and
    # says nothing about who may read.
    #
    # Moving that content would take a public page offline to express a rule
    # about who may edit it - a permission change that silently unpublishes is
    # the worst kind, because the operator's screen shows what they asked for.
    spit( "$d/news/post.md", "PUBLIC\n" );

    my $r = action_acl_set( 'news/', 'alice', undef, ['alice'], undef, undef );
    ok( $r->{ok}, 'the write rule is accepted' ) or diag( $r->{error} // '' );

    is( slurp("$d/news/post.md"), "PUBLIC\n",
        'and the content stays in the document root, still served' );
    ok( !-e private_path( $d, 'news/post.md' ), 'nothing went into the store' );
};

subtest 'a draft section moves too' => sub {
    # Draft 404s to the public, which is a stronger statement than gating rather
    # than a weaker one - so it must move as well.
    spit( "$d/unreleased/teaser.md", "SOON\n" );

    my $r = action_acl_set( 'unreleased/', 'alice', undef, undef, undef, 'true' );
    ok( $r->{ok}, 'the draft rule is accepted' ) or diag( $r->{error} // '' );
    ok( !-e "$d/unreleased",
        'and a draft section leaves the document root, despite naming no reader'
    );
    is( slurp( private_path( $d, 'unreleased/teaser.md' ) ), "SOON\n",
        'its content is in the store' );
};

subtest 'relaxing a rule to public moves content back' => sub {
    # Not a removal - the entry stays, its read list is cleared. The content has
    # to follow the RULE, not the presence of a record.
    my $r = action_acl_set( 'unreleased/', 'alice', undef, undef, undef, 'false' );
    ok( $r->{ok}, 'clearing draft is accepted' ) or diag( $r->{error} // '' );
    is( slurp("$d/unreleased/teaser.md"), "SOON\n",
        'and the content comes back into the document root, because the rule '
            . 'that kept it out is gone even though the entry is not' );
};

subtest 'a single file, not only a folder' => sub {
    spit( "$d/docs/private.md", "ONEFILE\n" );
    spit( "$d/docs/open.md",    "OPEN\n" );

    my $r = action_acl_set( 'docs/private.md', 'alice', ['alice'], undef, undef, undef );
    ok( $r->{ok}, 'a per-file rule is accepted' ) or diag( $r->{error} // '' );

    ok( !-e "$d/docs/private.md", 'that file leaves the document root' );
    is( slurp( private_path( $d, 'docs/private.md' ) ), "ONEFILE\n",
        'and lands in the store' );
    is( slurp("$d/docs/open.md"), "OPEN\n",
        'the control: its neighbour is untouched, so the move is the path it '
            . 'was given and not the folder around it' );
};

subtest 'protecting one file does not privatise the folder around it' => sub {
    # resolve_for_write decides where a NEW path is written by walking to its
    # nearest existing ancestor. Moving a single FILE into the store creates its
    # parent directories there too, and treating that bare container as evidence
    # of a gate made every file later created in a PUBLIC folder private -
    # unpublishing new content through an operation nobody thinks of as a
    # permission change, which is the exact failure resolve_for_write exists to
    # prevent, pointed the other way.
    #
    # The distinction is structural: a genuinely gated folder was MOVED, so it
    # is not in the docroot at all. A folder in both trees is a public folder
    # that happens to hold some private files.
    spit( "$d/journal/one.md", "ONE\n" );
    spit( "$d/journal/two.md", "TWO\n" );

    ok( action_acl_set( 'journal/one.md', 'alice', ['alice'], undef, undef, undef )
            ->{ok},
        'one file in the folder is protected' );
    ok( !-e "$d/journal/one.md", 'that file left the docroot' );
    ok( -d "$d/journal",         'but the folder itself is still public' );

    my $v = Lazysite::Manager::Common::validate_path('journal/three.md');
    is( $v->{store}, 'public',
        'so a NEW file in that folder is written publicly - the private '
            . 'PARENT DIRECTORY created by the move is a container, not a gate' );
    is( $v->{full}, "$d/journal/three.md", 'at the docroot path' );

    is( ( Lazysite::Manager::Common::validate_path('journal/one.md') )->{store},
        'private', 'the control: the protected file itself still resolves private' );
};

subtest 'the notes and the stale render follow the page' => sub {
    # A move that takes the .md and leaves these behind protects the page and
    # publishes its substance. The .html especially: it is a complete public
    # copy of the page sitting in the docroot, which is what SM283 WAS.
    spit( "$d/briefed/page.md",       "BODY\n" );
    spit( "$d/briefed/page.md.brief", "WHY\n" );
    spit( "$d/briefed/page.html",     "<p>BODY</p>\n" );

    ok( action_acl_set( 'briefed/page.md', 'alice', ['alice'], undef, undef, undef )
            ->{ok},
        'the page is protected' );

    is( slurp( private_path( $d, 'briefed/page.md.brief' ) ), "WHY\n",
        'the notes moved with it' );
    ok( !-e "$d/briefed/page.md.brief", 'and are not left public' );
    ok( !-e "$d/briefed/page.html",
        'and the render cache from before the gate is gone from the docroot - '
            . 'it was a full public copy of the page now protected' );
};

subtest 'moving a protected page keeps it protected' => sub {
    # action_move re-keys the ACL to the destination. The rename puts the bytes
    # wherever the destination resolved - the docroot, for a new path under a
    # public folder - so without re-syncing, a move carries the rule to the new
    # key and leaves the content public: the engine gates it, a front end serves
    # it. SM283, reintroduced by a rename.
    spit( "$d/vault/secret.md", "VAULT\n" );
    ok( action_acl_set( 'vault/secret.md', 'alice', ['alice'], undef, undef, undef )
            ->{ok},
        'the page is protected' );

    my $mv = Lazysite::Manager::Files::action_move(
        'vault/secret.md', 'vault/renamed.md', 'alice' );
    ok( $mv->{ok}, 'the move succeeds' ) or diag( $mv->{error} // '' );

    ok( exists load_acls()->{'vault/renamed.md'}, 'the rule followed the path' );
    is( slurp( private_path( $d, 'vault/renamed.md' ) ), "VAULT\n",
        'and so did the content - still out of the document root' );
    ok( !-e "$d/vault/renamed.md",
        'the renamed page was NOT published by the rename' );
};

subtest 'the site-wide rule says it moves nothing' => sub {
    # '/' cannot be expressed as a move: the docroot would have to become its own
    # sibling store. It stays enforced by the engine alone (SM287).
    #
    # The requirement here is that it SAYS SO. This is the one scope where the
    # SM283 class of exposure is still reachable through a front end that serves
    # files without asking the engine, and an operator making a whole site
    # private is entitled to know that rather than infer it.
    my $r = action_acl_set( '/', 'alice', ['alice'], undef, undef, undef );
    ok( $r->{ok}, 'a site-wide rule is accepted' ) or diag( $r->{error} // '' );
    is( $r->{path}, '/',
        'and reports the path it set - this returned undef for the root, the '
            . 'one rule covering everything' );

    my ($said) = grep { /site-wide/i } @{ $r->{warnings} || [] };
    ok( $said, 'and warns that no files moved' )
        or diag( 'warnings: ' . join ' | ', @{ $r->{warnings} || [] } );
    like( $said // '', qr/front end/i,
        'naming the residual risk, not just the mechanism' );

    # The docroot is still intact - the rule must not have tried.
    ok( -d "$d/lazysite", 'and the document root is untouched' );

    action_acl_remove( '/', 'alice' );
};


subtest 'the listing says which tree an entry is in' => sub {
    # Protected content is no longer in the document root, and a listing row
    # looks identical either way. Without this, "is this page actually
    # protected?" can only be answered by reading the ACL and trusting the move
    # happened - which is the assumption underneath every defect in this
    # programme.
    spit( "$d/mixed/open.md",   "O\n" );
    spit( "$d/mixed/closed.md", "C\n" );
    ok( action_acl_set( 'mixed/closed.md', 'alice', ['alice'], undef, undef, undef )
            ->{ok},
        'one of the two is protected' );

    my $l = Lazysite::Manager::Files::action_list( '/mixed', 'alice' );
    ok( $l->{ok}, 'the folder lists' ) or diag( $l->{error} // '' );
    my %by = map { $_->{name} => $_ } @{ $l->{entries} || [] };

    is( ( $by{'open.md'}   || {} )->{store}, 'public',  'the public one says public' );
    is( ( $by{'closed.md'} || {} )->{store}, 'private', 'the protected one says private' );

    # The standing rule: filesystem paths are never exposed through any surface.
    # The store's location is a filesystem fact, so the label must not leak it.
    my $json = JSON::PP->new->canonical->encode($l);
    unlike( $json, qr/\Q$base\E/,
        'and no absolute filesystem path appears in the response' );
    unlike( $json, qr/lazysite-private/,
        'not even the store directory name - the label is enough to act on' );
};

done_testing();

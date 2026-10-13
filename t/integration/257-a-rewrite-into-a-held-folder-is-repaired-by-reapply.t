#!/usr/bin/perl
# P11 (WORK-PLAN-0154), reported 2026-10-11 from a 1,745-post local site:
# "`acl set --draft` over a folder worked, with one trap: rewriting files into a
# folder that is already held leaves the private store's copy in place, and
# `acl reapply` then refuses to move the new files in ('the private store
# already holds this path'), correctly, and leaves them public in the meantime.
# ... A rewrite that names which of the two stores wins would help."
#
# Reproduced here in the report's shape - a draft-only folder, every file
# rewritten into the docroot by a tool that is not the engine, and one new file
# - against main after SM981 (a6106bec, "Land where save would"), which made the
# repair merge: the private store's copy of a file both trees hold wins, the
# public one goes to lazysite/displaced/ and is named, and what the store lacks
# moves in. This holds that the trap is gone, by both repairs the report could
# reach for (`acl reapply --apply`, and re-issuing `acl set --draft`), and that
# a rewritten page is not served to the public in the meantime.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root);
use ManagerSession    qw(new_site);
use Lazysite::Private ();

my $root = repo_root();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; return $t }

# One site per repair, each in the reported state: posts/ held as a draft, its
# files rewritten into the docroot, and one new one.
sub rewritten_site {
    my $s    = new_site( root => $root );
    my $d    = $s->docroot;
    my $priv = Lazysite::Private::private_root($d);
    make_path("$d/posts");
    spit( "$d/posts/p$_.md", "---\ntitle: P$_\n---\nOLD-TEXT $_\n" ) for 1 .. 3;
    my $acl = sub {
        my $cmd = join ' ', map {quotemeta} $^X, "$root/tools/lazysite-acl.pl", @_, '--docroot', $d;
        my $out = qx($cmd 2>&1);
        return ( $? >> 8, $out );
    };
    my ($rc) = $acl->( 'set', 'posts', '--actor', 'local', '--draft' );
    is( $rc, 0, 'acl set posts --draft' );
    ok( !-e "$d/posts" && -e "$priv/posts/p1.md", '...moved the folder into the private store' );
    # The rewrite: a script writes the posts again, straight into the docroot.
    make_path("$d/posts");
    spit( "$d/posts/p$_.md", "---\ntitle: P$_\n---\nNEW-TEXT $_\n" ) for 1 .. 3;
    spit( "$d/posts/p4.md", "---\ntitle: P4\n---\nNEW-TEXT 4\n" );
    return ( $s, $d, $priv, $acl );
}
sub anon {
    my ( $d, $uri ) = @_;
    my $out = TestHelper::run_processor( $d, $uri, HTTP_X_REMOTE_USER => undef,
        HTTP_X_REMOTE_GROUPS => undef, LAZYSITE_AUTH_TRUSTED => undef, HTTP_COOKIE => undef );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, ( $out =~ /(?:OLD|NEW)-TEXT/ ? 1 : 0 ) );
}
sub repaired {
    my ( $d, $priv, $out, $how ) = @_;
    unlike( $out, qr/already holds this path/, "$how: no refusal" );
    ok( !-e "$d/posts", "$how: nothing of the folder is left in the docroot" ) or diag($out);
    like( slurp("$priv/posts/p4.md") // '', qr/NEW-TEXT 4/, "$how: the new file moved in" );
    like( slurp("$priv/posts/p1.md") // '', qr/OLD-TEXT 1/,
        "$how: for a file both held, the private store's copy is kept (SM981: never expose)" );
    like( $out, qr{posts/p1\.md.*private store's copy is kept}s, "$how: and says which store won" );
    my @kept = map { ( glob("$d/lazysite/displaced/*/posts/p$_.md") )[0] } 1 .. 3;    # list glob: a scalar one iterates
    is( scalar( grep { $_ && ( slurp($_) // '' ) =~ /NEW-TEXT/ } @kept ), 3,
        "$how: every rewritten copy is kept outside the docroot, recoverable" );
    like( $out, qr/\Q$kept[0]\E/, "$how: and the reply names where" ) if $kept[0];
    is( ( anon( $d, '/posts/p4' ) )[0], 404, "$how: the moved-in file is a draft to the public" );
}

subtest 'in the meantime: the rewritten pages are not served to the public' => sub {
    my ( undef, $d ) = rewritten_site();
    for my $p (qw(p1 p4)) {
        my ( $st, $text ) = anon( $d, "/posts/$p" );
        is( $st, 404, "/posts/$p: 404 to an anonymous visitor (the folder is a draft)" );
        ok( !$text, '...and none of its text' );
    }
};

subtest 'acl reapply --apply repairs it' => sub {
    my ( undef, $d, $priv, $acl ) = rewritten_site();
    my ( $rc, $out ) = $acl->( 'reapply', '--actor', 'local', '--apply' );
    is( $rc, 0, 'reapply --apply succeeds' ) or diag($out);
    repaired( $d, $priv, $out, 'reapply' );
};

subtest 're-issuing acl set --draft repairs it the same way' => sub {
    my ( undef, $d, $priv, $acl ) = rewritten_site();
    my ( $rc, $out ) = $acl->( 'set', 'posts', '--actor', 'local', '--draft' );
    is( $rc, 0, 'acl set posts --draft again succeeds' ) or diag($out);
    repaired( $d, $priv, $out, 'set again' );
};

done_testing();

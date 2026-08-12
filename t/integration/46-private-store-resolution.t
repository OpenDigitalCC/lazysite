#!/usr/bin/perl
# SM286 step 1, wiring: the processor resolves content from the private store,
# and governs it exactly as it governs content in the docroot.
#
# Nothing MOVES content yet - the files here are placed in the private tree by
# hand, which is precisely how the next step will find surfaces it forgot. The
# point of wiring the resolver before the move is that every surface behaves
# identically until a single switch flips, and this proves the read path is
# ready for it.
#
# THE TRAP THIS PROVES, stated carefully because the first version of this
# comment overstated it. Before the wiring nothing leaked: the private tree was
# never consulted, so a path there was not found and 404'd.
#
# But resolution and KEY DERIVATION must land together. Every ACL predicate in
# the processor derives its docroot-relative key with `s{^$DOCROOT/}{}`, which
# fails for a private-tree path, and each returns 0 on failure - "not governed",
# "not draft", "not refused". Add the resolver alone and this test goes red on
# "the bytes do not reach an anonymous visitor": the gated file is served to the
# public, to the wrong user, and out of a draft section. Measured by doing
# exactly that, not inferred.
#
# So the hazard is real and conditional, which is the useful form of it: anyone
# wiring the remaining surfaces should assume the same shape wherever a surface
# turns an absolute path back into a key.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper        qw(run_processor);
use Lazysite::Private qw(private_path);

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path( "$doc/lazysite/auth", "$doc/open" );

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$doc/index.md",               "---\ntitle: Home\n---\nHome.\n" );
spit( "$doc/open/public.pdf",        'PUBLICBYTES' );

# The private store, populated by hand - as the move will populate it.
spit( private_path( $doc, 'upcoming/secret.pdf' ), 'PRIVATEBYTES' );

sub with_acls {
    my ($map) = @_;
    spit( "$doc/lazysite/auth/acls.json", encode_json($map) );
    return;
}

sub get_anon { return run_processor( $doc, $_[0] ) }

sub get_as {
    my ( $uri, $user ) = @_;
    return run_processor( $doc, $uri,
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => $user );
}

# --- the gated case ---------------------------------------------------------
# Two assertions doing different jobs. "No bytes" is the security claim, and it
# held before the wiring too - by accident, because the file was never found.
# "302, not 404" is the one that says the file WAS found and then refused, which
# is the difference between a working private store and an empty one.
subtest 'a gated file in the private store is refused, not silently served' => sub {
    with_acls( { 'upcoming' => { read => ['alice'] } } );

    my $out = get_anon('/upcoming/secret.pdf');
    unlike( $out, qr/PRIVATEBYTES/,
        'the bytes do not reach an anonymous visitor' );
    like( $out, qr/Status: 302/, 'and the refusal is the ordinary login bounce' );
};

subtest 'and served to the user the ACL names' => sub {
    with_acls( { 'upcoming' => { read => ['alice'] } } );
    like( get_as( '/upcoming/secret.pdf', 'alice' ), qr/PRIVATEBYTES/,
        'alice gets the file from the private store' );
    unlike( get_as( '/upcoming/secret.pdf', 'bob' ), qr/PRIVATEBYTES/,
        'bob does not' );
};

# --- the draft policy reaches it too ----------------------------------------
# Draft is a different predicate with the same broken key derivation, so it gets
# its own assertion rather than being assumed to follow.
subtest 'a draft section in the private store 404s rather than bouncing' => sub {
    with_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true() } } );
    my $out = get_anon('/upcoming/secret.pdf');
    unlike( $out, qr/PRIVATEBYTES/, 'no bytes' );
    like( $out, qr/Status: 404/,
        'and 404, because a draft section does not admit that it exists' );
};

# --- an ungoverned file in the private store still resolves -----------------
# The store is where gated content lives, but resolution must not depend on the
# ACL: a path that is there for any reason is found, and the ACL decides
# separately. Coupling them would make a store/ACL mismatch fail open.
subtest 'resolution does not depend on there being an ACL' => sub {
    with_acls( {} );
    like( get_anon('/upcoming/secret.pdf'), qr/PRIVATEBYTES/,
        'with no ACL at all the private file is served - resolution and the '
            . 'access decision are separate questions' );
};

# --- the docroot is untouched ------------------------------------------------
subtest 'public content is unaffected by any of this' => sub {
    with_acls( { 'upcoming' => { read => ['alice'] } } );
    like( get_anon('/open/public.pdf'), qr/PUBLICBYTES/,
        'an ordinary public file is served exactly as before' );
    unlike( get_anon('/open/public.pdf'), qr/no-store/,
        'and stays ordinary cacheable content' );
};

# --- nothing was moved -------------------------------------------------------
# This increment wires resolution and moves nothing. Asserted so that if a later
# change starts moving content, it does so deliberately rather than as a
# side-effect nobody noticed.
subtest 'this increment moves no content' => sub {
    ok( -e "$doc/open/public.pdf",
        'the public file is still in the docroot' );
    ok( !-e private_path( $doc, 'open/public.pdf' ),
        'and has not been copied into the private store' );
};

done_testing();

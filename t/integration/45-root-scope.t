#!/usr/bin/perl
# SM287: "this whole site is private" is expressible.
#
# It was not. A root ACL entry was inert under every spelling - not by an
# oversight in one branch, but by construction: the prefix loop skips a
# zero-length key, and even without that guard the match test can never succeed
# for an empty prefix because the leading slash has already been stripped from
# the request path.
#
# That left NO mechanism for a wholly-private site. `auth_default: required`
# governs pages and deliberately does not reach static files (SM223, and that
# was the right call for upgrades), so an operator setting it on a client
# extranet had closed the pages and published the PDFs. The workaround -
# enumerate your top-level folders - fails OPEN as content grows: a file added
# at the root next month is public, and nothing in the manager, the audit trail
# or lazysite-check says so.
#
# Found by the operator asking, to check their reading of the design: "the root
# / cannot be restricted as a folder, but files can, did I read that right?"
# They had, and it was written down nowhere.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/sub", "$docroot/open" );

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$docroot/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$docroot/index.md",               "---\ntitle: Home\n---\nHome.\n" );
spit( "$docroot/page.md",                "---\ntitle: P\n---\nPAGEBODY\n" );
spit( "$docroot/top.pdf",                'SECRETBYTES' );
spit( "$docroot/sub/deep.pdf",           'SECRETBYTES' );
spit( "$docroot/open/public.pdf",        'SECRETBYTES' );

sub with_acls {
    my ($map) = @_;
    spit( "$docroot/lazysite/auth/acls.json", encode_json($map) );
    return;
}

sub get_anon { return run_processor( $docroot, $_[0] ) }

sub get_as {
    my ( $uri, $user ) = @_;
    return run_processor( $docroot, $uri,
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => $user );
}

# --- the canonical spelling gates everything --------------------------------
subtest 'a root entry gates the whole site, at every depth' => sub {
    with_acls( { '/' => { read => ['alice'] } } );

    for my $path (qw(/top.pdf /sub/deep.pdf /open/public.pdf)) {
        my $out = get_anon($path);
        unlike( $out, qr/SECRETBYTES/, "$path: no bytes to the public" );
        like( $out, qr/Status: 302/, "$path: bounced to sign in" );
    }

    # Pages too - the root rule is not a static-only mechanism.
    my $page = get_anon('/page');
    unlike( $page, qr/PAGEBODY/, '/page: the page body is not served either' );

    # And the permitted user gets everything back.
    for my $path (qw(/top.pdf /sub/deep.pdf)) {
        like( get_as( $path, 'alice' ), qr/SECRETBYTES/,
            "$path: served to the named user" );
    }
    like( get_as( '/page', 'alice' ), qr/PAGEBODY/, '/page: served to alice' );
};

# --- it is the WEAKEST rule -------------------------------------------------
# The shape that makes a site-wide rule usable at all: everything private except
# the front door. If root beat a longer prefix this would be unexpressible, and
# an operator would be back to enumerating folders.
subtest 'a more specific entry beats the root rule, in both directions' => sub {
    with_acls(
        { '/' => { read => ['alice'] },
            'open' => { read => [ 'alice', 'bob' ] },
        }
    );

    like( get_as( '/open/public.pdf', 'bob' ), qr/SECRETBYTES/,
        'bob is admitted to the carve-out by the longer prefix' );
    unlike( get_as( '/top.pdf', 'bob' ), qr/SECRETBYTES/,
        'and is still refused everywhere the root rule governs' );
    like( get_as( '/top.pdf', 'alice' ), qr/SECRETBYTES/,
        'while alice keeps the site-wide grant' );
};

# --- the alternative spellings ----------------------------------------------
# '' and '.' are accepted by the reader because a hand-edited store is a real
# interface here and both plainly mean the same thing. The point is that NONE of
# them may silently do nothing, which is what all five used to do.
subtest 'the other root spellings are honoured, not silently ignored' => sub {
    for my $key ( '', '.' ) {
        with_acls( { $key => { read => ['alice'] } } );
        my $shown = $key eq '' ? '(empty string)' : "'$key'";
        unlike( get_anon('/top.pdf'), qr/SECRETBYTES/,
            "root spelled $shown gates a top-level file" );
        unlike( get_anon('/sub/deep.pdf'), qr/SECRETBYTES/,
            "root spelled $shown gates a nested file" );
    }
};

# --- protection is still opt-in ---------------------------------------------
# The property that made SM223 safe to ship to every existing site, and this
# must not have changed it: a site with no root rule behaves exactly as before.
subtest 'a site without a root rule is untouched' => sub {
    with_acls( { 'sub' => { read => ['alice'] } } );
    like( get_anon('/top.pdf'), qr/SECRETBYTES/,
        'a top-level file is public when only a folder is gated' );
    unlike( get_anon('/sub/deep.pdf'), qr/SECRETBYTES/,
        'and the gated folder still gates' );

    with_acls( {} );
    like( get_anon('/top.pdf'),      qr/SECRETBYTES/, 'an empty store gates nothing' );
    like( get_anon('/sub/deep.pdf'), qr/SECRETBYTES/, '.. at any depth' );
};

# --- an owner-only root entry is not a read restriction ---------------------
# The same rule the rest of the store follows (SM268 H10): an entry with no list
# for the mode is NO rule, not a tighter one. Asserted at the root because that
# is where getting it wrong would close an entire site by accident.
subtest 'an owner-only root entry does not restrict reading' => sub {
    with_acls( { '/' => { owner => 'alice' } } );
    like( get_anon('/top.pdf'), qr/SECRETBYTES/,
        'served - an owner is not a read list, here as anywhere else' );
};

done_testing();

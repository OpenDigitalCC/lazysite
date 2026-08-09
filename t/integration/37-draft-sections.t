#!/usr/bin/perl
# SM181: a DRAFT section is hidden, not merely gated.
#
# The auth-gate half shipped first: a folder ACL entry protects a section's pages
# and assets, and deleting the entry publishes it atomically. But this filing
# LEADS with draft, and argues it is the better fit for "not yet ready for
# publication" - because a coming-soon section that answers a login form at
# /upcoming/pricing has confirmed that /upcoming/pricing exists. The URL is the
# thing being held back.
#
# Draft is an attribute of a protected entry rather than a second mechanism:
#
#   { "upcoming": { "read": ["@editors"], "draft": true } }
#
# It changes exactly two things - the refusal becomes a 404, and the section is
# absent from every listing.
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
make_path( "$docroot/lazysite/auth", "$docroot/lazysite/templates/registries",
    "$docroot/upcoming", "$docroot/open" );

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

spit( "$docroot/lazysite/lazysite.conf", "site_name: T\nsite_url: https://t.example\n" );
spit( "$docroot/index.md", "---\ntitle: Home\nregister:\n  - sitemap.xml\n---\nHome.\n" );
spit( "$docroot/open/free.md",
    "---\ntitle: Free\nregister:\n  - sitemap.xml\n---\nOUTSIDE-PAGE\n" );
spit( "$docroot/upcoming/pricing.md",
    "---\ntitle: Pricing\nregister:\n  - sitemap.xml\n---\nDRAFT-PAGE\n" );
spit( "$docroot/upcoming/hero.png", "PNGBYTES" );

# A minimal sitemap template, so registry generation has something to render.
spit( "$docroot/lazysite/templates/registries/sitemap.xml.tt",
    '[% FOREACH p IN pages %][% p.url %]' . "\n" . '[% END %]' );

sub write_acls {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}

sub clear {
    for my $f (qw(upcoming/pricing.html open/free.html index.html sitemap.xml)) {
        unlink "$docroot/$f" if -f "$docroot/$f";
    }
    return;
}

sub get {
    my ( $uri, %env ) = @_;
    clear();
    return run_processor( $docroot, $uri, %env );
}

sub get_as {
    my ( $uri, $user ) = @_;
    return get( $uri, LAZYSITE_AUTH_TRUSTED => '1', HTTP_X_REMOTE_USER => $user );
}

# --- the public gets 404, not a login form ----------------------------------
subtest 'a draft section 404s to the public' => sub {
    write_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true } } );

    my $out = get('/upcoming/pricing');
    like( $out, qr/Status: 404/,
        '404 rather than a 302 to login - a login form at this URL would '
            . 'confirm the page exists, which is what is being held back' );
    unlike( $out, qr/DRAFT-PAGE/,        'and no content' );
    unlike( $out, qr/Location: \/login/, 'and no redirect that discloses it' );
};

# --- an editor previews it ---------------------------------------------------
subtest 'a permitted editor can preview the draft' => sub {
    write_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true } } );
    like( get_as( '/upcoming/pricing', 'alice' ), qr/DRAFT-PAGE/,
        'the named editor sees it' );
};

# --- a signed-in NON-editor also gets 404 ------------------------------------
# A 403 to an authenticated non-editor discloses the section just as effectively
# as one to the public.
subtest 'a signed-in user outside the list gets 404, not 403' => sub {
    write_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true } } );
    my $out = get_as( '/upcoming/pricing', 'bob' );
    like( $out, qr/Status: 404/, 'hidden, not forbidden' );
    unlike( $out, qr/DRAFT-PAGE/, 'and no content' );
};

# --- draft with NO read list is still not public ----------------------------
# The ordinary rule is "no read list = allowed". Draft has to differ, or a draft
# with no list would be public, which is the opposite of the word.
subtest 'draft with no read list is still hidden from the public' => sub {
    write_acls( { 'upcoming' => { draft => JSON::PP::true } } );
    like( get('/upcoming/pricing'), qr/Status: 404/, 'anonymous is refused' );
    like( get_as( '/upcoming/pricing', 'anyone' ), qr/DRAFT-PAGE/,
        'while any signed-in user may preview - with no list, nobody is named' );
};

# --- absent from the registries ---------------------------------------------
# A sitemap is generated once and served from disk to the public, so a draft page
# listed in it is published regardless of what the page itself answers.
subtest 'a draft page is absent from the sitemap' => sub {
    write_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true } } );
    get('/');    # trigger registry generation
    my $map = do {
        open my $fh, '<', "$docroot/sitemap.xml" or return ok( 0, 'sitemap written' );
        local $/;
        <$fh>;
    };
    unlike( $map, qr{/upcoming/pricing},
        'the draft URL is not in the sitemap - a listed URL is a published one' );
    like( $map, qr{/open/free}, 'while an ordinary page still is' );
};

# --- generation by an EDITOR must not leak it either -------------------------
# The registry is a shared file. If an editor's request generated it, a draft
# page would be baked in and then served to everyone.
subtest 'a registry generated by an editor still excludes the draft' => sub {
    write_acls( { 'upcoming' => { read => ['alice'], draft => JSON::PP::true } } );
    unlink "$docroot/sitemap.xml" if -f "$docroot/sitemap.xml";
    get_as( '/', 'alice' );
    my $map = do {
        open my $fh, '<', "$docroot/sitemap.xml" or return ok( 0, 'sitemap written' );
        local $/;
        <$fh>;
    };
    unlike( $map, qr{/upcoming/pricing},
        'still absent - who triggered generation is irrelevant to a shared file' );
};

# --- publishing is removing the draft flag -----------------------------------
subtest 'clearing the entry publishes the section' => sub {
    write_acls( {} );
    like( get('/upcoming/pricing'),  qr/DRAFT-PAGE/, 'the page is public' );
    like( get('/upcoming/hero.png'), qr/PNGBYTES/,   'and its assets' );

    unlink "$docroot/sitemap.xml" if -f "$docroot/sitemap.xml";
    get('/');
    my $map = do {
        open my $fh, '<', "$docroot/sitemap.xml" or return ok( 0, 'sitemap' );
        local $/;
        <$fh>;
    };
    like( $map, qr{/upcoming/pricing}, 'and it enters the sitemap' );
};

done_testing();

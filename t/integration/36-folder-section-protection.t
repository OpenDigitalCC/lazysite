#!/usr/bin/perl
# SM181: a folder ACL entry gates the whole SECTION - its pages as well as its
# files - and deleting the entry publishes the section atomically.
#
# Access control was per-page or whole-site with nothing in between. Holding back
# an unfinished section meant stamping `auth:` on every page in it, and releasing
# it meant unstamping every page: error-prone, and with no moment at which the
# section became public as a unit.
#
# The mechanism is the ACL folder entry SM223 already introduced for static
# files, which is why this is small. It also closes the caveat SM181 left open -
# "a draft page is hidden but its /upcoming/hero.png may still be fetchable" -
# because one entry now covers the section's pages AND the assets inside it.
#
# NOT built, and recorded rather than implied: the DRAFT policy (404 to the
# public, absent from sitemap and search, previewable by an editor). This is the
# auth-gate half only.
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
make_path( "$docroot/lazysite/auth", "$docroot/upcoming", "$docroot/open" );

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

spit( "$docroot/index.md", "---\ntitle: Home\n---\nHome.\n" );
# A section: two pages and an asset, none of them carrying any auth front matter.
spit( "$docroot/upcoming/index.md",  "---\ntitle: Soon\n---\nSECTION-INDEX\n" );
spit( "$docroot/upcoming/launch.md", "---\ntitle: Launch\n---\nSECTION-PAGE\n" );
spit( "$docroot/upcoming/hero.png",  "PNGBYTES" );
# And a page that explicitly declares itself public, INSIDE the section.
spit( "$docroot/upcoming/public.md", "---\ntitle: Public\nauth: none\n---\nCLAIMS-PUBLIC\n" );
spit( "$docroot/open/free.md",       "---\ntitle: Free\n---\nOUTSIDE\n" );

sub write_acls {
    my ($map) = @_;
    my $p = "$docroot/lazysite/auth/acls.json";
    if ( !defined $map ) { unlink $p; return }
    open my $fh, '>', $p or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}

# The rendered-HTML cache must not carry a protected page between runs.
sub clear_cache {
    for my $f (qw(upcoming/index.html upcoming/launch.html upcoming/public.html open/free.html)) {
        unlink "$docroot/$f" if -f "$docroot/$f";
    }
    return;
}

sub get {
    my ( $uri, %env ) = @_;
    clear_cache();
    return run_processor( $docroot, $uri, %env );
}

sub get_as {
    my ( $uri, $user ) = @_;
    return get( $uri,
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => $user );
}

# --- before the rule: the section is public ---------------------------------
subtest 'with no rule the section is public, as it was' => sub {
    write_acls(undef);
    like( get('/upcoming/'),       qr/SECTION-INDEX/, 'the section index is served' );
    like( get('/upcoming/launch'), qr/SECTION-PAGE/,  'and a page inside it' );
};

# --- one entry gates the whole section --------------------------------------
subtest 'one folder entry protects every page in the section' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );

    my $idx = get('/upcoming/');
    like( $idx, qr/Status: 302/, 'the section index bounces to login' );
    unlike( $idx, qr/SECTION-INDEX/, 'and its content is not served' );

    my $pg = get('/upcoming/launch');
    like( $pg, qr/Status: 302/, 'so does a page inside it' );
    unlike( $pg, qr/SECTION-PAGE/, 'with no content' );

    # No per-page front matter was touched to achieve any of that.
    my $src = do {
        open my $fh, '<', "$docroot/upcoming/launch.md" or die $!;
        local $/;
        <$fh>;
    };
    unlike( $src, qr/^auth:/m,
        'and the pages carry no auth: front matter - the point of a section gate' );
};

# --- the asset inside the section is covered by the SAME entry --------------
# SM181's open caveat: "a draft page is hidden but its /upcoming/hero.png may
# still be fetchable". One store answers both questions, so it cannot drift.
subtest 'the section entry also covers its assets' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );
    my $img = get('/upcoming/hero.png');
    unlike( $img, qr/PNGBYTES/, 'the image inside the section is not served either' );
};

# --- a page cannot opt itself out of its section ----------------------------
subtest 'a page inside the section cannot declare itself public' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );
    my $out = get('/upcoming/public');
    unlike( $out, qr/CLAIMS-PUBLIC/,
        'auth: none inside a gated section does not override the gate - '
            . 'otherwise holding a section back would depend on every page in it' );
};

# --- the gate is confined to the section ------------------------------------
subtest 'nothing outside the section is affected' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );
    like( get('/open/free'), qr/OUTSIDE/, 'a page outside the folder is served' );
    like( get('/'),          qr/Home/,    'and so is the home page' );
};

# --- the permitted user sees the section ------------------------------------
subtest 'a permitted user reads the whole section' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );
    like( get_as( '/upcoming/',       'alice' ), qr/SECTION-INDEX/, 'index' );
    like( get_as( '/upcoming/launch', 'alice' ), qr/SECTION-PAGE/,  'and pages' );

    my $no = get_as( '/upcoming/launch', 'bob' );
    like( $no, qr/Status: 403/, 'a different user is refused' );
    unlike( $no, qr/SECTION-PAGE/, 'with no content' );
};

# --- a protected page is never left in the shared cache ---------------------
# The rendered .html cache is shared by every visitor. A gated page written into
# it would be served to the public by the front end on the next request, which
# would undo the gate completely and silently.
subtest 'a gated page is not written to the shared HTML cache' => sub {
    write_acls( { 'upcoming' => { read => ['alice'] } } );
    get_as( '/upcoming/launch', 'alice' );
    ok( !-f "$docroot/upcoming/launch.html",
        'no cache file after a permitted render' );
};

# --- and removing the entry publishes the section atomically ----------------
subtest 'deleting the one entry publishes the whole section' => sub {
    write_acls( {} );
    like( get('/upcoming/'),         qr/SECTION-INDEX/, 'index is public again' );
    like( get('/upcoming/launch'),   qr/SECTION-PAGE/,  'and every page' );
    like( get('/upcoming/hero.png'), qr/PNGBYTES/,      'and the assets' );
};

done_testing();

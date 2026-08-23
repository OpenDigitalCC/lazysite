#!/usr/bin/perl
# SM438: updating an existing mirrored theme asset over WebDAV was a silent
# no-op - 204, fresh mtime, old bytes serving. Filed WITHOUT a cause, with a
# settling test specified instead; this file is that test, kept as the
# regression.
#
# The mechanism, established by running it: a stale private-store copy of the
# mirror path made resolve_for_write send the UPDATE to the private store
# ("existing content keeps its home"), where nothing serves it - while the
# public mirror kept the old bytes. Create worked because no private copy
# existed to win. The mirror is engine-owned derived output whose canonical
# writer (activation's cp -r) is public-only, so writes to lazysite-assets/
# now resolve public unconditionally, and the PUT removes the stray private
# copy that caused it all.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root setup_dav_site);
use Lazysite::Private ();

my $root    = repo_root();
my $site    = setup_dav_site();
my $docroot = $site->{docroot};

sub dav_put {
    my ( $path, $body ) = @_;
    my $bf = tempdir( CLEANUP => 1 ) . '/body';
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;
    $ENV{SCRIPT_NAME}        = '/dav';
    $ENV{REMOTE_ADDR}        = '127.0.0.1';
    $ENV{HTTP_AUTHORIZATION} = $site->{auth};
    $ENV{REQUEST_METHOD}     = 'PUT';
    $ENV{PATH_INFO}          = $path;
    $ENV{CONTENT_LENGTH}     = length $body;
    my $out = qx(sh -c \Q$^X \Q$root/lazysite-dav.pl\E < \Q$bf\E 2>/dev/null\E);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    return $status;
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $rel = 'lazysite-assets/nova/dusk/main.css';
make_path("$docroot/lazysite-assets/nova/dusk");

subtest 'THE FIELD CASE: a stale private copy no longer captures the update' => sub {
    # The precondition the field site had, built exactly: the asset exists
    # publicly (the activation mirror put it there) AND a stale copy of the
    # same path sits in the private store.
    open my $pub, '>', "$docroot/$rel" or die $!;
    print {$pub} 'OLD-MIRRORED';
    close $pub;
    my $stray = Lazysite::Private::private_path( $docroot, $rel );
    make_path( $stray =~ s{/[^/]+\z}{}r );
    open my $pv, '>', $stray or die $!;
    print {$pv} 'STALE-PRIVATE';
    close $pv;

    is( dav_put( "/$rel", 'NEW-BYTES' ), 204, 'the update answers 204, as it always did' );
    is( slurp("$docroot/$rel"), 'NEW-BYTES',
        'and the PUBLIC mirror file - the one that serves - holds the new bytes' )
        or diag( 'Before the fix this held OLD-MIRRORED: the 204 was true and '
            . 'the bytes went to the private store, where nothing serves them.' );
    ok( !-e $stray, 'the stale private copy is removed, so the site is healed, not patched' );
};

subtest 'creating a new mirror asset still works and stays public' => sub {
    my $new = 'lazysite-assets/nova/dusk/extra.css';
    is( dav_put( "/$new", 'FRESH' ), 201,     'created' );
    is( slurp("$docroot/$new"),      'FRESH', 'in the public mirror' );
};

subtest 'THE LOAD-BEARING RULE IS UNTOUCHED for ordinary content' => sub {
    # A gated content file keeps its home: the mirror carve-out must not have
    # widened into the rule that stops a save republishing a private section.
    my $crel = 'content/private-note.md';
    make_path("$docroot/content");
    my $priv = Lazysite::Private::private_path( $docroot, $crel );
    make_path( $priv =~ s{/[^/]+\z}{}r );
    open my $pv, '>', $priv or die $!;
    print {$pv} "---\ntitle: Old\n---\nold\n";
    close $pv;

    is( dav_put( "/$crel", "---\ntitle: New\n---\nnew\n" ), 204, 'update accepted' );
    like( slurp($priv) // '', qr/New/, 'the PRIVATE copy took the write - its home' );
    ok( !-e "$docroot/$crel",
        'and no public copy appeared - the gated section stays gated' )
        or diag('If this exists, the carve-out republished private content.');
};

done_testing();

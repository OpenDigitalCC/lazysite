#!/usr/bin/perl
# SM286: the two surfaces that CANNOT carry protected content say so.
#
# Backups must carry the private store (t/unit/manager/69) because a backup is
# local recovery and losing content is the worst outcome. These two are the
# opposite case, and for different reasons:
#
#   - A site package TRAVELS between organisations, and the ACL rules that govern
#     the content live under lazysite/ and are deliberately never packaged. Gated
#     content in a package would arrive at the far end with nothing governing it -
#     published, on a site whose operator never chose to publish it.
#
#   - The content history's work tree is the docroot, and Git.pm's header makes
#     the exclude list a security boundary: a history that may be pushed to a
#     remote must never carry personal data.
#
# In BOTH cases the omission is already correct and already completely silent -
# the store is a sibling of the docroot, so neither one has to try. That silence
# is the defect. This file is about the REPORT, which is why every assertion
# below is about what the caller is told rather than about which bytes moved.
#
# SM261 was this same failure on this same history response: `enabled: 1` with an
# empty list reads as "no history exists" rather than "history does not cover
# this", and a caller acting on it reaches a confident wrong conclusion instead
# of an error.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use JSON::PP                  ();
use Lazysite::Private         qw(private_path count_private);
use Lazysite::Manager::Common ();

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/backups", "$d/lazysite/auth", "$d/open" );

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/open/public.md",        "PUBLIC\n" );
spit( "$d/lazysite.conf",         "site_name: t\n" );
spit( "$d/lazysite/domains.conf", "" );

subtest 'count_private counts content, not directories' => sub {
    is( count_private( $d, '' ), 0, 'an absent store counts zero, and does not die' );

    spit( private_path( $d, 'members/secret.md' ),    "S\n" );
    spit( private_path( $d, 'members/deep/more.md' ), "D\n" );
    spit( private_path( $d, 'elsewhere/other.md' ),   "O\n" );

    is( count_private( $d, '' ), 3, 'three files across the whole store' );
    is( count_private( $d, 'members' ), 2,
        'scoped to a prefix, so a per-domain caller counts only its own' );
    is( count_private( $d, 'nosuch' ), 0, 'a prefix with nothing under it' );
};

subtest 'a site package reports what it could not carry' => sub {
    require Lazysite::Manager::SitePackage;
    local $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    local $Lazysite::Manager::SitePackage::auth_user = 'alice';

    # The primary/default site: content is the docroot, so the whole store is
    # in scope for the count.
    require Lazysite::Manager::Domains;
    local $Lazysite::Manager::Domains::DOCROOT = $d;

    # '(default)' is the primary, which always exists. Deliberately NOT a
    # skip_all on a failed create: a skipped subtest reports as a pass, and a
    # test that quietly stops testing is the exact failure class this work item
    # keeps turning up.
    my $r = Lazysite::Manager::SitePackage::package_create('(default)');
    ok( $r->{ok}, 'the primary site packages' ) or do {
        diag( $r->{error} // '' );
        return;
    };

    is( $r->{private_omitted}, 3,
        'the count is reported to the operator building the package' );
    is( $r->{manifest}{private_omitted}, 3,
        'and recorded in the manifest, so the RECEIVING operator learns it '
            . 'from the package rather than from a gap they may not notice' );
    like( $r->{notice}, qr/protected/i,
        'with a sentence saying what happened, not just a number' );

    # The count is the only thing that may travel. A filename is content:
    # "members/2026-payroll" discloses the very thing the gate protects, and
    # this manifest travels further than the content ever would.
    my $json = JSON::PP::encode_json( $r->{manifest} );
    unlike( $json, qr/secret|payroll|more\.md|other\.md/,
        'and no gated FILENAME anywhere in the manifest' );

    # The archive itself must not contain the store, whatever the manifest says.
    my $tar     = "$d/lazysite/backups/$r->{name}";
    my $listing = `tar tzf \Q$tar\E 2>/dev/null`;
    unlike( $listing, qr/secret\.md/,
        'and the archive really does not contain the gated content' );
};

subtest 'history says protected content is not versioned' => sub {
    require Lazysite::Manager::Files;
    local $Lazysite::Manager::Files::DOCROOT      = $d;
    local $Lazysite::Manager::Files::LAZYSITE_DIR = "$d/lazysite";

    # validate_path - and therefore the private-store resolution - lives in
    # Common and reads COMMON's docroot. Setting only Files' left `store` empty,
    # which made the `versioned` assertion below pass for the wrong reason:
    # false because the git feature is off, not because the file is protected.
    local $Lazysite::Manager::Common::DOCROOT = $d;

    # Git history off in this fixture, which is the harder case for the report:
    # `enabled` is already false, so `versioned` has to carry the distinction
    # between "the feature is off" and "the feature does not cover this file".
    my $pub = Lazysite::Manager::Files::action_git_history( 'open/public.md', 'alice' );
    ok( $pub->{ok}, 'history for a public file answers' );

    # First prove the fixture actually resolves this path into the store. Without
    # this the subtest below passes whether or not the code recognises protected
    # content, because git is off here and `versioned` would be false anyway.
    my $v = Lazysite::Manager::Common::validate_path('members/secret.md');
    is( $v->{store}, 'private',
        'the fixture really does resolve this path into the private store' );

    my $prot = Lazysite::Manager::Files::action_git_history(
        'members/secret.md', 'alice' );
    ok( $prot->{ok}, 'history for protected content answers rather than erroring' );
    is_deeply( $prot->{versions}, [], 'with no versions' );
    ok( !$prot->{versioned},
        'and versioned:false - WITHOUT which an empty list reads as '
            . '"this file has no history" instead of "history does not cover it"' );
    like( $prot->{notice}, qr/protected/i,
        'and a sentence a person can act on' );

    ok( !exists $pub->{notice},
        'the control: a public file gets no such notice, so the notice means '
            . 'something when it appears' );
};

done_testing();

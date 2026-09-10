#!/usr/bin/perl
# SM836: uploading into a protected folder was refused as "Target is not a
# directory", while adding a page to the same folder worked.
#
# Reported from the field on a protected fileshare:
#
#   manager  ui  file-upload  /Intranet/fileshare/projects/.../Documents/  fail
#   Reason: Target is not a directory
#
# Protecting a section MOVES it into the private store - "re-applying access
# rules (moves protected content out of the docroot)" is what the deploy itself
# prints - so `$DOCROOT/$rel_dir` names a directory that is deliberately not
# there. The upfront convenience check tested exactly that path and refused
# before any file was looked at.
#
# THE PER-FILE GATE WAS ALREADY RIGHT. validate_path resolves the private store
# through resolve_for_write, and the comment above it says so. Only the upfront
# check disagreed, and it ran first - which is why "add page works, just not
# upload": the two took different routes to the same folder.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Private qw(private_path private_root);
use Lazysite::Manager::Upload qw(action_file_upload);
use Lazysite::Manager::Common ();

my $d = site_tempdir();    # lint 118: not a bare tempdir
make_path("$d/lazysite", "$d/open");

# A PUBLIC folder, and a PROTECTED one. The protected folder exists only in the
# private store - which is the whole point of protecting it.
open my $pf, '>', "$d/open/public.md" or die $!;
print {$pf} "public\n";
close $pf;

my $secret = private_path( $d, 'fileshare/Documents/existing.md' );
make_path( $secret =~ s{/[^/]+\z}{}r );
open my $sf, '>', $secret or die $!;
print {$sf} "private\n";
close $sf;

ok( !-d "$d/fileshare/Documents", 'the protected folder is NOT under the docroot' );
ok( -d private_path( $d, 'fileshare/Documents' ), '...it lives in the private store' );

for my $pkg (qw(Lazysite::Manager::Upload Lazysite::Manager::Common)) {
    no strict 'refs';
    ${"${pkg}::DOCROOT"}      = $d;
    ${"${pkg}::LAZYSITE_DIR"} = "$d/lazysite";
    ${"${pkg}::auth_user"}    = 'alice';
}

my $BOUND = 'xYzBOUNDARY';

sub upload_to {
    my ( $dir, $name ) = @_;
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$BOUND";
    my $body
        = "--$BOUND\r\n"
        . "Content-Disposition: form-data; name=\"file\"; filename=\"$name\"\r\n"
        . "Content-Type: text/plain\r\n\r\n"
        . "UPLOADED\r\n"
        . "--$BOUND--\r\n";
    return action_file_upload( $dir, $body );
}

# --- THE CANARY -------------------------------------------------------------
# A public upload must work, or the "protected works too" assertion below proves
# nothing about protection - only that the rig is broken in both directions.
{
    my $r = upload_to( '/open', 'canary.txt' );
    ok( $r->{ok}, 'an upload into an ordinary folder succeeds' )
        or diag "error: " . ( $r->{error} // '(none)' );
    ok( -e "$d/open/canary.txt", '...and the bytes land in the docroot' );
}

# --- THE FINDING ------------------------------------------------------------
{
    my $r = upload_to( '/fileshare/Documents', 'report.txt' );
    ok( $r->{ok}, 'an upload into a PROTECTED folder is not refused' )
        or diag "error: " . ( $r->{error} // '(none)' );
    isnt( $r->{error} // '', 'Target is not a directory',
        'the folder is found where protection actually put it' );

    # And it lands WITH the protected content, not in a public copy beside it -
    # half-publishing a gated section through an operation nobody thinks of as a
    # permission change is SM286's whole point.
    ok( -e private_path( $d, 'fileshare/Documents/report.txt' ),
        'the upload lands in the private store, with the content it belongs to' );
    ok( !-e "$d/fileshare/Documents/report.txt",
        '...and no public copy appears beside it' );
}

# --- THE CONFINEMENT IS UNCHANGED -------------------------------------------
# The boundary test still has to refuse a traversal; it is now measured against
# whichever root owns the target rather than always the docroot.
{
    my $r = upload_to( '/open/../../escape', 'x.txt' );
    ok( !$r->{ok}, 'a traversal out of the docroot is still refused' );
}

done_testing();

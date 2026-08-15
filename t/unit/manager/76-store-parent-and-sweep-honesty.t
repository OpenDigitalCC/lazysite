#!/usr/bin/perl
# SM313: the store gets created, and a sweep that moved nothing says so.
#
# THE FINDING. The docroot permission fault on edge was repaired - MKCOL, PUT,
# overwrite and DELETE at the site root all went from 507 to success - and
# protecting content STILL left it served. The private store is
# `<docroot>-lazysite-private`, a SIBLING of the document root, so creating it
# needs write access on the docroot's PARENT: a different directory, which
# SM270's repair never touched.
#
# Measured after that repair, on a fresh folder with an active read list:
# list_files reported 11 of 11 entries "store":"public", and eight of ten probed
# extensions served 200 anonymously, byte-identical to source. SM296 predicted
# this cause in its own open section and it is now confirmed to survive the
# documented recovery.
#
# THREE THINGS WERE WRONG, and all three are here.
#
# 1. `lazysite check --fix` reported the fault and repaired nothing. The report
#    has been correct since SM296; only the repair was missing.
#
# 2. THE OBVIOUS REPAIR WOULD HAVE BEEN WORSE. Making the parent group-writable
#    is "the same operation one directory up", and on the Hestia layout that
#    parent is the domain folder - which also holds cgi-bin. Write on a directory
#    is permission to create, delete and RENAME its entries. Repairing an
#    exposure by opening a larger one is not a repair, so --fix creates the store
#    instead: strictly narrower, and it removes the need for the permission
#    entirely.
#
# 3. THE SWEEP CALLED IT SUCCESS. `acl reapply --apply` counted every ok:1 as
#    re-applied, so a sweep that moved nothing printed "N re-applied, 0 failed"
#    and exited 0. The whole purpose of that command is to move content out of
#    the document root; a call that stored the rule and moved nothing has done
#    none of it. That is this project's recurring defect - a control reporting
#    success without doing the work - wearing the uniform of the tool built to
#    repair exactly that.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files qw(action_acl_set);
use Lazysite::Private        ();

my $root = "$FindBin::Bin/../../..";

subtest 'the store is a SIBLING, so the docroot is the wrong directory to fix' => sub {
    # The geometry is the whole finding. Asserted rather than described, because
    # every wrong repair proposed for this - including the one in the report that
    # raised it - follows from getting the geometry wrong.
    my $base = tempdir( CLEANUP => 1 );
    my $doc  = "$base/public_html";
    mkdir $doc or die $!;

    my $store = Lazysite::Private::private_root($doc);
    ok( defined $store, 'the store path resolves' );

    ( my $store_parent = $store ) =~ s{/[^/]+\z}{};
    isnt( $store_parent, $doc,
        'the store does NOT live inside the docroot' );
    is( $store_parent, $base,
        'it lives beside it, so creating it needs write on the docroot PARENT' )
        or diag( "store: $store\n"
            . "This is why `lazysite check --fix` repairing public_html left\n"
            . "the sweep broken: it repaired a directory that was never the\n"
            . "obstacle." );
};

subtest 'a move that did not happen is reported structurally, not just in prose' => sub {
    # A caller that must string-match a warning to learn whether content moved
    # will silently stop matching when the wording improves - and the sweep runs
    # unattended across a fleet. SM307 improved that exact wording in this same
    # release, which is the demonstration rather than a hypothetical.
    my $base = tempdir( CLEANUP => 1 );
    my $doc  = "$base/public_html";
    make_path("$doc/section");
    open my $fh, '>', "$doc/section/index.md" or die $!;
    print $fh "---\ntitle: S\n---\n\nBody.\n";
    close $fh;

    $Lazysite::Manager::Files::DOCROOT  = $doc;
    $Lazysite::Manager::Common::DOCROOT = $doc;
    $Lazysite::Auth::Acl::DOCROOT       = $doc;

SKIP: {
        skip 'running as root - a mode 0555 directory would still be writable', 3
            if $> == 0;
        chmod 0555, $base or skip "cannot chmod the fixture parent: $!", 3;
        ok( !-w $base, 'the store parent really is unwritable' );

        my $r = action_acl_set( '/section/', 'operator', ['alice'], ['alice'],
            undef, undef );

        ok( $r->{ok}, 'the call still succeeds - the RULE is stored and honoured' );
        is( $r->{content_moved}, 0,
            'and content_moved says plainly that the files did not move' )
            or diag( "Without this flag the sweep counts the call as a success\n"
                . "and exits 0, having moved nothing. Warnings were:\n  "
                . join( "\n  ", @{ $r->{warnings} || [] } ) );

        chmod 0755, $base;
    }
};

subtest 'a successful move reports content_moved true' => sub {
    # The other direction, so the flag cannot pass by always being 0.
    my $base = tempdir( CLEANUP => 1 );
    my $doc  = "$base/public_html";
    make_path("$doc/ok-section");
    open my $fh, '>', "$doc/ok-section/index.md" or die $!;
    print $fh "---\ntitle: S\n---\n\nBody.\n";
    close $fh;

    $Lazysite::Manager::Files::DOCROOT  = $doc;
    $Lazysite::Manager::Common::DOCROOT = $doc;
    $Lazysite::Auth::Acl::DOCROOT       = $doc;

    my $r = action_acl_set( '/ok-section/', 'operator', ['alice'], ['alice'],
        undef, undef );
    ok( $r->{ok}, 'protecting a folder on a healthy layout succeeds' );
    is( $r->{content_moved}, 1, 'and reports that the content moved' );

    my $store = Lazysite::Private::private_root($doc);
    ok( -d "$store/ok-section", 'the content really is in the store' )
        or diag('content_moved must mean the bytes moved, not that we tried');
    ok( !-d "$doc/ok-section", 'and no longer in the document root' );
};

subtest 'the sweep treats "moved nothing" as failure' => sub {
    # Asserted against the source: driving the CLI needs a fleet fixture, and
    # what matters is that the three states are distinguished and that the exit
    # status follows the outcome rather than the call.
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-acl.pl" or die $!;
        local $/;
        <$fh>;
    };

    like( $src, qr/\$r->\{content_moved\}/,
        'the sweep consults the structural flag' );
    unlike( $src, qr/warnings.*=~.*could not be moved/,
        'and does NOT string-match the warning text' );
    like( $src, qr/push \@unmoved/,
        'a call that moved nothing is counted separately from a re-apply' );
    like( $src, qr/\(\s*\@failed \|\| \@unmoved\s*\)\s*\?\s*1\s*:\s*0/,
        'and the exit status is non-zero when nothing moved' )
        or diag( "The sweep exiting 0 after moving nothing is what let an\n"
            . "operator believe SM283 had been closed on a fleet where it\n"
            . "had not." );

    # One summary naming the cause, not a per-folder warning: on a fleet sweep a
    # per-folder line reads as advisory noise and scrolls past.
    like( $src, qr/SIBLING of the document root/,
        'the summary names the actual cause' );
    like( $src, qr/lazysite check .*--fix/,
        'and gives the command that repairs it' );
};

subtest 'check --fix creates the store rather than widening its parent' => sub {
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-check.pl" or die $!;
        local $/;
        <$fh>;
    };

    like( $src, qr/\$store_create_needed/,
        'the check queues the store for creation' );
    like( $src, qr/chmod 02770, \$s/,
        'created setgid, so content moved in keeps the group' );
    like( $src, qr/chown \$exp_uid, \$exp_gid, \$s/,
        'and owned by the site user, so the engine can write into it' );

    # The guard on the guard: the repair must NOT be a chmod of the parent.
    unlike( $src, qr/chmod[^\n]*\$parent/,
        'the parent is NOT made writable - that would give the CGI group '
            . 'create/delete/rename on a directory holding cgi-bin' );
};

done_testing();

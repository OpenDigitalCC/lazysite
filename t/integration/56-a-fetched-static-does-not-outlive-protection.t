#!/usr/bin/perl
# SM331: a static file fetched BEFORE protection must not keep serving after it.
#
# WHAT WAS MEASURED IN THE FIELD, on edge/0.10.11, with the private store working
# correctly for the first time - which is what made it visible at all:
#
#   a folder of five identical-byte files
#   two fetched anonymously BEFORE protecting, three untouched
#   after protecting: the two fetched answer 200, the three untouched gate
#   list_files reports ALL of them "store":"private"
#
# So the engine moved everything, believes everything moved, and reports the move
# complete. The front end serves two of them anyway.
#
# WHY THE LEAKED SET IS THE DANGEROUS SET. Those are not random files - they are
# exactly the files somebody requested while the folder was public. On a site
# being protected after the fact, which is the whole SM283 remediation story and
# what `acl reapply` exists for, the documents fetched while public are the
# documents worth fetching.
#
# AND IT DEFEATS THE OUTSIDE-IN PROBE. SM285's check --check-acl creates its own
# folder, gates it, and fetches it - so its files are created and gated in one
# operation and never fetched while public. They are precisely the case that
# works. The probe would report the site healthy while this folder leaks, which
# is the same shape as SM283 itself.
#
# WHAT THIS FILE ESTABLISHES, and what it cannot. It answers the filing's first
# question - does serving a static file leave a copy the move does not carry? -
# against the real engine. The second half of the field report involves nginx
# serving from its own state, which needs the proxy harness; that is asserted
# separately below where the harness is available, and skipped where it is not.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper        qw(setup_test_site run_processor repo_root);
use Lazysite::Private ();

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
make_path("$docroot/zz-cache");

# Five files of identical bytes, as the field fixture had.
my %made;
for my $ext (qw(png zip pdf css txt)) {
    my $p = "$docroot/zz-cache/c.$ext";
    open my $fh, '>', $p or die $!;
    print $fh "IDENTICAL-BYTES-FOR-EVERY-EXTENSION\n";
    close $fh;
    $made{$ext} = $p;
}

# Every file in the docroot, so a copy appearing anywhere is visible.
sub docroot_files {
    my %seen;
    my @queue = ($docroot);
    while ( my $d = shift @queue ) {
        opendir my $dh, $d or next;
        for my $e ( readdir $dh ) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if ( -d $p ) { push @queue, $p; next }
            ( my $rel = $p ) =~ s{\A\Q$docroot\E/}{};
            $seen{$rel} = ( stat $p )[7];
        }
        closedir $dh;
    }
    return \%seen;
}

my $before = docroot_files();

# FETCH TWO OF THEM, exactly as the field fixture did.
run_processor( $docroot, "/zz-cache/c.$_" ) for qw(png zip);

my $after = docroot_files();

subtest 'serving a static file leaves no COPY OF IT in the docroot' => sub {
    # The filing's first question, asked of the engine directly.
    #
    # Scoped to copies of the fetched files, not to "no new files at all". A
    # request legitimately creates unrelated artefacts - a 404 page, a Template
    # Toolkit compile cache, an access-log line - and the first version of this
    # assertion flagged those and read as a reproduction when it was noise.
    my @new = grep { !exists $before->{$_} } sort keys %$after;
    note("request artefacts created (expected): $_") for @new;

    my @copies = grep {
        my $f = $_;
        grep { $f =~ /\bc\.\Q$_\E\z/ } qw(png zip pdf css txt)
    } @new;

    is_deeply( \@copies, [],
        'fetching a static created no copy the move would have to know about' )
        or diag( join "\n  ",
        '',
        @new,
        '',
        'A copy written on serve, in a location move_in does not carry, is the',
        'SM286 defect for static files - that one was found for pages, where a',
        '.html render cache was a complete public copy left in the docroot.' );
};

subtest 'after protecting, nothing the engine claims is private remains served' => sub {
    $Lazysite::Manager::Files::DOCROOT  = $docroot;
    $Lazysite::Manager::Common::DOCROOT = $docroot;
    $Lazysite::Auth::Acl::DOCROOT       = $docroot;
    require Lazysite::Manager::Files;

    my $r = Lazysite::Manager::Files::action_acl_set( '/zz-cache/', 'operator',
        ['alice'], ['alice'], undef, undef );
    ok( $r->{ok}, 'the folder is protected' ) or diag explain $r;
    is( $r->{content_moved}, 1, 'and the engine reports the content moved' );

    # THE ASSERTION THE FIELD REPORT IS ABOUT: what the engine claims is private
    # must not still be sitting in the served tree. A fetched file that stayed
    # behind is the leak, and it is invisible in every response field.
    my @left = grep { -f } map { "$docroot/zz-cache/c.$_" } qw(png zip pdf css txt);
    s{\A\Q$docroot\E/}{} for @left;

    is_deeply( \@left, [],
        'no file remains in the docroot after a move reported as complete' )
        or diag( join "\n  ",
        '',
        @left,
        '',
        'These were fetched while public. On a site being protected after the',
        'fact they are the documents worth fetching, and every signal - ',
        'content_moved, store:private, no warning - says they moved.' );

    my $store    = Lazysite::Private::private_root($docroot);
    my @in_store = grep { -f "$store/zz-cache/c.$_" } qw(png zip pdf css txt);
    is( scalar @in_store, 5, 'and all five are in the private store' );
};

subtest 'the outside-in probe can now generate this shape' => sub {
    # Recorded because it is the reason this went unseen: SM285's probe creates
    # its folder, gates it, and fetches it - so its files are never fetched while
    # public, which is exactly the case that works.
    my $chk = do {
        open my $fh, '<', "$root/tools/lazysite-check.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($probe) = $chk =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'the probe is present' ) or return;

    # SM331 CLOSED THE BLIND SPOT. The probe now fetches its files WHILE PUBLIC
    # before gating them, so the population the field found leaking - files that
    # had been requested before protection - is one it can generate.
    like( $probe, qr/FETCH THEM WHILE PUBLIC FIRST/,
        'the probe warms the folder before gating it' )
        or diag( 'Without this the probe creates, gates and fetches in one go, '
            . 'so its files are never requested while public - exactly the case '
            . 'that works, and never the one that leaks.' );

    my $warm_at = index( $probe, 'FETCH THEM WHILE PUBLIC FIRST' );
    my $gate_at = index( $probe, '_acl_write' );
    cmp_ok( $warm_at, '>=', 0, 'the warming pass is present' );
    cmp_ok( $warm_at, '<', $gate_at,
        'and it happens BEFORE the folder is gated, which is the whole point' );
};

done_testing();

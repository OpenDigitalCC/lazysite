#!/usr/bin/perl
# SM293: every surface agrees where a site's engine tree is.
#
# `lazysite/` holds config, credentials, the audit log, session state, form
# submissions and pre-install snapshots, and it sits inside the directory the web
# server serves - kept unreachable by a `deny /lazysite/` repeated in every
# shipped front-end template. That is the same arrangement SM248, SM268 H17 and
# SM283 each turned out to be. The concrete case: SM283's proxy answered static
# extensions off the docroot, so on any host whose list includes `gz` it would
# have served `lazysite/backups/preinstall-*.tar.gz` - the whole site, including
# the account store.
#
# The engine now ASKS where its tree is instead of computing one answer, so a
# site migrates by moving the directory and nothing else. That only holds while
# every surface asks the same question and gets the same answer:
#
#   - the processor carries a MODULE-FREE copy (ADR 0001 - the render path loads
#     no Lazysite modules), which is the copy that can drift;
#   - everything else calls Lazysite::Paths::lazysite_dir.
#
# A drifted copy here does not fail loudly. It means the renderer reads one
# config and the manager writes another, which presents as "my change did not
# take effect" and is diagnosed by nobody.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper      qw(repo_root);
use Lazysite::Paths qw(lazysite_dir external_lazysite_dir stray_lazysite);

my $root = repo_root();

subtest 'the module resolves both layouts' => sub {
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    make_path("$d/lazysite");

    is( lazysite_dir($d), "$d/lazysite",
        'an unmigrated site keeps its tree inside the docroot' );

    my $ext = external_lazysite_dir($d);
    is( $ext, "$base/public_html-lazysite",
        'the external location is named for the docroot, so two sites under '
            . 'one parent can never share one' );

    make_path($ext);
    is( lazysite_dir($d), $ext,
        'once the directory exists beside the docroot, that one wins - a site '
            . 'migrates by MOVING it, with no config key and no flag day' );

    ok( stray_lazysite($d),
        'and a tree in BOTH places is reported: the engine reads the outside '
            . 'copy while the front end can still serve the inside one, so the '
            . 'site works perfectly and publishes its account store' );

    require File::Path;
    File::Path::remove_tree("$d/lazysite");
    ok( !stray_lazysite($d), 'the control: one tree is not a stray' );
};

subtest 'the processor agrees with the module' => sub {
    # The processor cannot load the module (ADR 0001), so it carries its own
    # derivation. Drive BOTH and compare, rather than comparing source text -
    # two implementations that look alike can still disagree, and it is the
    # answer that matters.
    my $src = do {
        open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };

    my ($block) = $src =~ m{\nsub _lazysite_dir_for \{\n(.*?)\n\}\n}s;
    ok( $block, 'the processor derives its engine dir in one place' )
        or return;

    unlike( $block, qr/Lazysite::/,
        'and does so without loading a Lazysite module (ADR 0001)' );

    # Parameterised, not reading the file-scoped docroot: confine_content_root
    # is a pure function that must resolve against the root it was PASSED.
    like( $block, qr/my \(\$d\) = \@_/,
        'and takes the docroot as an argument' );

    my $base = tempdir( CLEANUP => 1 );
    for my $case (
        [ 'unmigrated', 0 ],
        [ 'migrated',   1 ],
        )
    {
        my ( $name, $external ) = @$case;
        my $d = "$base/$name/public_html";
        make_path("$d/lazysite");
        my $ext = external_lazysite_dir($d);
        make_path($ext) if $external;

        ## no critic (BuiltinFunctions::ProhibitStringyEval)
        my $got = eval "sub __probe {$block\n} __probe(\$d)";
        is( $got, lazysite_dir($d),
            "the processor and the module agree on a $name site" )
            or diag( "processor: " . ( $got // 'undef' )
                . "\nmodule:    " . lazysite_dir($d) );
    }
};

subtest 'the processor and the module agree where a configured path lives' => sub {
    # SM850: a nav_file is site-relative, and `lazysite/...` means the engine
    # tree wherever it is. The manager writes through Lazysite::Paths::site_path
    # and the processor reads through its own copy; if they drift, a nav save
    # answers ok and the live nav does not change. Driven, not compared as text.
    my $src = do {
        open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($block) = $src =~ m{\nsub _site_path \{\n(.*?)\n\}\n}s;
    ok( $block, 'the processor maps a configured path in one place' ) or return;
    unlike( $block, qr/Lazysite::/, 'without loading a Lazysite module (ADR 0001)' );
    like( $src, qr/_site_path\( \$LAZYSITE_DIR, \$DOCROOT, \$vars->\{nav_file\} \)/,
        'and the nav file a request renders with goes through it' );

    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    my $proc = eval "sub { $block\n }" or die $@;
    my $base = tempdir( CLEANUP => 1 );
    for my $external ( 0, 1 ) {
        my $d = "$base/s$external/public_html";
        make_path("$d/lazysite");
        make_path( external_lazysite_dir($d) ) if $external;
        my $lz = lazysite_dir($d);
        for my $rel ( qw(lazysite/nav.conf lazysite/nav-2.conf /lazysite/nav.conf lazysite sites/a/nav.conf
            lazysite-assets/nav.conf) )
        {
            is( $proc->( $lz, $d, $rel ), Lazysite::Paths::site_path( $d, $rel ),
                ( $external ? 'migrated' : 'unmigrated' ) . " site: '$rel' agrees" );
        }
    }
};

subtest 'nothing derives the engine dir behind the resolver' => sub {
    # The point of one resolver is that there is one. A file that rebuilds the
    # path itself keeps working today and silently stops finding the tree the
    # day a site is migrated - the failure this whole filing is about, one layer
    # down.
    #
    # SM850: EVERY FILE, NOT NINE. This used to read nine named entry points,
    # and the modules they call were where the paths were built: the data store,
    # the scheduler, the briefs, notifications, the stats and pandoc plugins -
    # 110 places across 38 files, each reading and writing a directory that a
    # migrated site no longer has. The form handler was found building SM842 by
    # refusing every submission as "not configured"; the rest were found by
    # reading. So the question is asked of everything that ships Perl, and the
    # shape is any interpolated "<something>/lazysite" - the variable names
    # varied ($docroot, $DOCROOT, $root, $d, $_[0], _docroot(...)), which is how
    # a list of two spellings missed most of them.
    #
    # A line whose question really is about the in-docroot place (a content walk
    # that must not descend into a stray tree, the migration reporting what it
    # would move) calls Lazysite::Paths::internal_lazysite_dir.
    my %allowed = (

        # The two module-free copies of the resolver itself, driven above and
        # compared with the module by the subtests before this one.
        'lazysite-processor.pl' => [qr{return -d \$ext \? \$ext : "\$d/lazysite";}],
        'install.pl'            => [qr{return -d \$ext \? \$ext : "\$d/lazysite";}],

        # nginx configuration text, in nginx's own variable - a front end's
        # rule, emitted for a sysop to paste, not a path this engine opens.
        'lib/Lazysite/DomainRewrites.pm' => [qr{'#.*\$document_root/lazysite/}],

        # A core-only root tool from its own package: it loads no Lazysite module,
        # and sets modes on the tree the install it just ran laid out in a fresh
        # docroot. And the `lazysite` CLI binary beside it, which is not a tree.
        'tools/lazysite-hestia-domain.pl' => [
            qr{"\$docroot/lazysite/auth", "\$docroot/lazysite/forms"},
            qr{"\$bin/lazysite"},
        ],

        # Builds its own fixture site in a tempdir, unmigrated by construction,
        # as the tests under t/ do.
        'tools/bench.pl' => [qr{.}],
    );

    my @files;
    File::Find::find(
        sub { push @files, $File::Find::name if /\.(?:pm|pl)\z/ && -f },
        "$root/lib", "$root/tools", "$root/plugins"
    );
    push @files, grep { -f } glob("$root/lazysite-*.pl"), "$root/install.pl";
    cmp_ok( scalar @files, '>', 100, 'the canary: found the Perl that ships' );

    my @offenders;
    my %used;
    for my $f ( sort @files ) {
        ( my $rel = $f ) =~ s{\A\Q$root/\E}{};
        next if $rel eq 'lib/Lazysite/Paths.pm';
        open my $fh, '<', $f or die "$rel: $!";
        my @lines = <$fh>;
        close $fh;
        for my $i ( 0 .. $#lines ) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;    # a comment describing it
            next
                unless $l
                =~ m{(?:\$\w+|\$\{\w+\}|\$_\[\d\]|\$ENV\{\w+\}|\$\w+->\{\w+\})/lazysite(?=[/"']|\s*$)}
                || $l =~ m{\)\s*\.\s*['"]/lazysite(?=[/"'])};
            if ( my ($re) = grep { $l =~ $_ } @{ $allowed{$rel} || [] } ) {
                $used{"$rel $re"} = 1;
                next;
            }
            push @offenders, "$rel:" . ( $i + 1 ) . ": $l";
        }
    }
    is_deeply( \@offenders, [],
        'nothing builds "<docroot>/lazysite" for itself - it asks Lazysite::Paths' )
        or diag( join '', @offenders );

    # An exception nothing needs any more is a hole waiting for a new line.
    my @stale = grep { !$used{$_} }
        map { my $r = $_; map { "$r $_" } @{ $allowed{$r} } } sort keys %allowed;
    is_deeply( \@stale, [], 'and every named exception is still in use' )
        or diag( join "\n", @stale );
};

done_testing();

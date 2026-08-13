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

subtest 'nothing derives the engine dir behind the resolver' => sub {
    # The point of one resolver is that there is one. A file that rebuilds the
    # path itself keeps working today and silently stops finding the tree the
    # day a site is migrated - the failure this whole filing is about, one layer
    # down.
    my @offenders;
    for my $rel (
        qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl
        lazysite-dav.pl lazysite-mcp.pl lazysite-oauth.pl
        tools/lazysite-users.pl tools/lazysite-acl.pl tools/lazysite-server.pl)
        )
    {
        open my $fh, '<', "$root/$rel" or next;
        my @lines = <$fh>;
        close $fh;
        for my $i ( 0 .. $#lines ) {
            my $l = $lines[$i];
            next if $l     =~ /^\s*#/;                  # a comment describing it
            next unless $l =~ m{\$DOCROOT/lazysite\b|\$docroot/lazysite\b};
            next if $l =~ /lazysite-assets/;            # served, and stays in the docroot
            next if $l =~ /lazysite\.conf\.example/;    # the seed template, not the tree
            push @offenders, "$rel:" . ( $i + 1 ) . ": $l";
        }
    }
    is_deeply( \@offenders, [],
        'no surface rebuilds "<docroot>/lazysite" for itself' )
        or diag( join '', @offenders );
};

done_testing();

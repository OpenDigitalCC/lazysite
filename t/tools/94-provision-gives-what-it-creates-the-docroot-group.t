#!/usr/bin/perl
#
# SM933 A2 / R13: EVERYTHING PROVISION CREATES TAKES THE DOCROOT'S GROUP.
#
# Measured before this was built (SM933 PR0): install.pl set no group on anything
# it wrote, so every created path took whatever the kernel handed out - the
# docroot's group under a setgid docroot, the installing process's PRIMARY group
# otherwise (202 of 202 paths, in the fixture). And one path was wrong under every
# docroot mode: the private store is created BESIDE the docroot, its setgid bit
# never reaches it, and it took the site root's group - on Hestia that is
# <user>:<user>, a store the www-data CGI cannot write.
#
# THE FIXTURE IS THE ONE THAT DISCRIMINATES: a docroot whose group is NOT the
# invoking user's primary group, and NOT setgid. Under a setgid docroot the kernel
# would produce the right group for everything inside it with no help from the
# installer, and a test there would pass on the unfixed code. So the docroot is
# 0755 here on purpose, and the private store - which no docroot mode can reach -
# is asserted separately.
#
# The mode is left wrong for the health check to complain about; this file is
# about GROUP, and 0755 on the docroot is the fixture's choice, not the
# installer's. The exit code is therefore 4 and that is expected.
use strict;
use warnings;
use Test::More;
use File::Find ();
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

# A group the user is in that is not their primary one. chgrp into it needs no
# root, which is what lets this run anywhere the suite runs.
my @gids    = split ' ', $);
my $primary = $gids[0];
my ($second) = grep { $_ != $primary } @gids[ 1 .. $#gids ];
plan skip_all => 'needs a supplementary group to discriminate the two mechanisms'
    unless defined $second;
my $PRIMARY   = getgrgid($primary) // $primary;
my $SECONDARY = getgrgid($second)  // $second;

my $MF_GUARD = repo_manifest_guard();

my $docroot = site_tempdir();
my $cgibin  = dirname($docroot) . '/cgi-bin';
make_path($cgibin);
chown -1, $second, $docroot or plan skip_all => "cannot chgrp the docroot: $!";
chmod 0755, $docroot;

sub install {
    my ($mode) = @_;
    my $out = `$^X \Q$INSTALL\E --mode \Q$mode\E --docroot \Q$docroot\E \\
        --cgibin \Q$cgibin\E --serving-group \Q$SECONDARY\E 2>&1`;
    return ( $out, $? >> 8 );
}

sub groups_under {
    my ($top) = @_;
    my %by;
    File::Find::find( {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $top;
                return if -l $File::Find::name;
                my $g = ( lstat $File::Find::name )[5];
                push @{ $by{ getgrgid($g) // $g } }, $File::Find::name;
            },
        },
        $top
    );
    return \%by;
}

my ( $out, $rc ) = install('provision');
cmp_ok( $rc, '!=', 1, 'provision ran (4 is expected: the fixture docroot is 0755)' )
    or diag $out;

subtest 'every path inside the docroot carries the docroot group' => sub {
    my $by = groups_under($docroot);
    my $n  = 0;
    $n += @{ $by->{$_} } for keys %$by;
    cmp_ok( $n, '>', 50, "provision created paths to check ($n)" )
        or diag( 'If this is small the fixture did not install and every '
            . 'assertion below passes on an empty tree.' );

    is_deeply( [ sort keys %$by ], [$SECONDARY],
        "all $n created paths are group '$SECONDARY'" )
        or diag( "found: "
            . join( ', ', map { "$_ x" . scalar @{ $by->{$_} } } sort keys %$by )
            . "\nThe unfixed installer gave every one of them '$PRIMARY' - the "
            . 'process group - because it set no group at all and this docroot '
            . 'is not setgid.' );
};

subtest 'the private store, which no docroot mode can reach, does too' => sub {
    my $store = dirname($docroot) . '/' . basename($docroot) . '-lazysite-private';
    ok( -d $store, 'the private store was created beside the docroot' )
        or return;
    my $g = getgrgid( ( stat $store )[5] ) // ( stat $store )[5];
    is( $g, $SECONDARY, "and it is group '$SECONDARY', the docroot's" )
        or diag( "It is '$g'. This is the path the field case broke: it sits "
            . 'beside the docroot, so it took the site ROOT\'s group, and on a '
            . 'Hestia domain that is a group the CGI is not in.' );
    my $parent = getgrgid( ( stat dirname($store) )[5] ) // '';
    isnt( $parent, $SECONDARY,
        'and its parent is NOT that group - so the answer came from the rule, '
            . 'not from inheritance' )
        or diag( 'If the site root already carried the docroot group this '
            . 'subtest proves nothing about which source the installer used.' );
};

subtest 'an existing path is never regrouped' => sub {
    # The upgrade half of the ruling: a group on an existing path may be a
    # sysop's deliberate choice, so only what a run CREATES is regrouped.
    my $file = "$docroot/lazysite/templates/registries/sitemap.xml";
    ($file) = grep { -f } $file, glob("$docroot/lazysite/templates/*/*") unless -f $file;
    ok( $file && -f $file, 'picked an installed file' ) or return;
    chown -1, $primary, $file or return fail("cannot chgrp $file: $!");

    my ( $out2, $rc2 ) = install('reinstall');
    cmp_ok( $rc2, '!=', 1, 'reinstall ran' ) or diag $out2;
    my $g = getgrgid( ( stat $file )[5] ) // '';
    is( $g, $PRIMARY, "the file a sysop regrouped kept '$PRIMARY'" )
        or diag( 'Regrouping existing paths is "align everything", the shape '
            . 'of the 0.6.5 outage - only a path this run created is touched.' );
};

subtest 'nothing it could not regroup goes unsaid' => sub {
    unlike( $out, qr/could not be given group/,
        'as a member of the group, no path was left behind' );
};

done_testing();

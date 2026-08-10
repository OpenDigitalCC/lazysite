#!/usr/bin/perl
# SM246: every directory the installer may create is DECLARED, with a mode and
# a reason, and the mode it declares is the mode a real install produces.
#
# The incident this comes from: install_file created directories with a bare
# make_path and no mode, so they landed at 0777 & ~umask - 0755 under a root
# umask of 022, no group write - and the docroot directories outside
# runtime_paths were corrected by nothing. The installer solves the identical
# umask problem three times for FILES and had never solved it once for
# directories.
#
# So this test has two halves, and both are needed:
#
#   * DECLARATION - the set of directories the manifest installs into is exactly
#     the set the model declares. This is what makes a newly shipped file in a
#     new directory fail the build until someone states the mode and the reason,
#     rather than inheriting whatever the build host's umask happened to be.
#   * REALITY - a real install into a temp docroot produces those modes. A model
#     nothing checks against a running installer is the same class of fiction as
#     runtime_files, which was declared, read, and never actually carried.
use strict;
use warnings;
use Test::More;
use JSON::PP       ();
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard);

my $ROOT     = "$FindBin::Bin/../..";
my $INSTALL  = "$ROOT/install.pl";
my $BUILD_MF = "$ROOT/tools/build-manifest.pl";
my $CLASS    = "$ROOT/dist/config/classification.json";

plan skip_all => "install.pl not found"        unless -f $INSTALL;
plan skip_all => "build-manifest.pl not found" unless -f $BUILD_MF;

sub slurp_json {
    my ($p) = @_;
    open my $fh, '<:raw', $p or die "cannot read $p: $!";
    my $t = do { local $/; <$fh> };
    close $fh;
    return JSON::PP::decode_json($t);
}

my $cfg      = slurp_json($CLASS);
my $declared = $cfg->{install_dirs} || [];

# install.pl reads a manifest from beside itself. release-manifest.json is not
# tracked (it ships only in release tarballs), so build one if it is absent and
# remove it again at END - same handling as t/tools/03, so a run here does not
# leave a phantom modified file behind, and does not delete an operator's own.
# SM269 phase 1: this test needs release-manifest.json AT THE REPO ROOT, and so
# do two others. Under `prove -j` they raced - one deleted at END what another
# was still using. The guard serialises just these three.
my $MF_GUARD = repo_manifest_guard();

my $REPO_MF = "$ROOT/release-manifest.json";
my $MF_OURS = 0;
unless ( -f $REPO_MF ) {
    system( $^X, $BUILD_MF ) == 0 or BAIL_OUT('failed to build release-manifest.json');
    $MF_OURS = 1;
}
END { unlink $REPO_MF if $MF_OURS && -f $REPO_MF }

# --- the model is well-formed ------------------------------------------------

subtest 'every declared directory states a mode and a reason' => sub {
    cmp_ok( scalar @$declared, '>=', 20, 'the model declares directories' );
    for my $d (@$declared) {
        like( $d->{mode}, qr/\A[0-7]{3,4}\z/, "$d->{path} declares an octal mode" );
        # The reason is the part that was missing everywhere in this installer,
        # and the reason a hand-maintained list drifts: without it a later
        # reader cannot tell a deliberate mode from an accident.
        ok( defined $d->{why} && length $d->{why}, "$d->{path} states why" );
    }
};

# --- the model and runtime_paths agree where they overlap --------------------
# Both tables can name the same directory (lazysite/auth is created by the file
# pass AND declared as a runtime path). If they disagree, whichever runs last
# wins and the answer depends on install order - which is exactly the class of
# bug this filing exists to remove.

subtest 'install_dirs and runtime_paths agree on shared paths' => sub {
    my %rp = map { $_->{path} => $_->{mode} } @{ $cfg->{runtime_paths} || [] };
    my @clash;
    for my $d (@$declared) {
        my $other = $rp{ $d->{path} } or next;
        push @clash, "$d->{path}: install_dirs says $d->{mode}, runtime_paths says $other"
            unless $other eq $d->{mode};
    }
    is_deeply( \@clash, [], 'no path is declared with two different modes' )
        or diag( join "\n  ", '', @clash );
};

# --- the model covers what the manifest actually installs --------------------

my $tmp = tempdir( 'lazysite-installdirs-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $mf  = "$tmp/manifest.json";
is( system( $^X, $BUILD_MF, '--version', '0.0.0-test', '--out', $mf ), 0,
    'built a manifest to check against' )
    or BAIL_OUT('cannot build a manifest');

my $manifest = slurp_json($mf);

my %needed;
for my $f ( @{ $manifest->{files} } ) {
    # "null = tarball-only" - build_plan skips these, so they are never a
    # destination directory and must not be declared as one.
    my $dest = $f->{install_to} or next;
    my $d    = dirname($dest);
    while ( length $d && $d ne '.' && $d ne '/' ) {
        $needed{$d} = 1;
        my $up = dirname($d);
        last if $up eq $d;
        $d = $up;
    }
}

subtest 'every directory the manifest installs into is declared' => sub {
    my %have       = map  { $_->{path} => 1 } @$declared;
    my @undeclared = grep { !$have{$_} } sort keys %needed;
    is_deeply( \@undeclared, [], 'no undeclared install destination' )
        or diag( join "\n  ", '', @undeclared,
        'Add each to install_dirs in dist/config/classification.json with a',
        'mode and a why. install.pl now REFUSES to create an undeclared',
        'directory rather than inheriting the build host umask.' );

    # And the other way: a declared path nothing installs into is dead weight
    # that will quietly stop describing reality. {DOCROOT} and {CGIBIN} are the
    # pre-existing roots and are declared for completeness, not because the
    # installer creates them.
    my %root   = map  { $_ => 1 } qw({DOCROOT} {CGIBIN});
    my @orphan = grep { !$needed{$_} && !$root{$_} } sort keys %have;
    is_deeply( \@orphan, [], 'no declared directory without a manifest entry' )
        or diag( join "\n  ", '', @orphan );
};

# --- the coverage proof and the runtime lookup use the SAME key space --------
#
# SM268 03-F8: the check above compares TEMPLATE strings, and install.pl looks
# up RESOLVED ones. Two key spaces, so the model's central guarantee was
# unverified for exactly the entries containing `..`: `{DOCROOT}/..` resolved to
# `/base/site/..`, which the parent walk never asks for (it asks for `/base`),
# and the declaration was dead. Nothing here could see it, because dirname on
# the template produced the same dead string the declaration used.
#
# So resolve both sides through install.pl's OWN resolve_placeholders - the
# function the installer calls - and compare what it produces.
subtest 'every needed directory is declared after resolution, too' => sub {
    my $src = do {
        open my $fh, '<', "$ROOT/install.pl" or die "install.pl: $!";
        local $/;
        <$fh>;
    };
    my ($resolver) = $src =~ /(sub resolve_placeholders\b.*?\n\})/s;
    ok( defined $resolver, 'resolve_placeholders extracted from install.pl' )
        or return;

    my $pkg = 'SM268F8';
    eval "package $pkg; $resolver; 1" or die $@;    ## no critic (ProhibitStringyEval)

    my %subs = ( DOCROOT => '/base/site', CGIBIN => '/base/cgi-bin' );
    my $r    = sub { return $pkg->can('resolve_placeholders')->( $_[0], \%subs ) };

    my %have_resolved = map { $r->( $_->{path} ) => $_->{path} } @$declared;

    my @missing;
    for my $n ( sort keys %needed ) {
        my $res = $r->($n);
        push @missing, "$n -> $res" unless exists $have_resolved{$res};
    }
    is_deeply( \@missing, [], 'no needed directory resolves to an undeclared path' )
        or diag( join "\n  ", '', @missing,
        'The template is declared but resolves to a string install.pl never',
        'looks up. That is what made {DOCROOT}/.. a dead declaration.' );

    # And the resolved form must be a path the parent walk can actually reach:
    # no `..` may survive resolution, or the lookup key can never match.
    my @unresolved = grep { m{(?:\A|/)\.\.(?:/|\z)} }
        map { $r->( $_->{path} ) } @$declared;
    is_deeply( \@unresolved, [],
        'no declared path still contains .. after resolution' )
        or diag( join "\n  ", '', @unresolved );
};

# SM268 03-F8: and the declaration that was dead now does its job. Provisioning
# a site whose own parent directory does not exist yet is the case the
# `{DOCROOT}/..` entry exists for, and it failed with "No declared mode for
# directory ..." - telling the operator to add an entry to classification.json
# that was already there.
subtest 'a site whose parent directory does not exist yet installs' => sub {
    my $base = tempdir( 'lazysite-greenfield-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    # $base/nx exists; $base/nx/site does NOT - it is what {DOCROOT}/.. declares.
    make_path("$base/nx");
    my $docroot = "$base/nx/site/public_html";
    my $cgibin  = "$base/nx/cgi-bin";

    my $out = `$^X \Q$INSTALL\E --docroot \Q$docroot\E --cgibin \Q$cgibin\E 2>&1`;
    is( $? >> 8, 0, 'install exited 0' ) or diag $out;
    ok( -d $docroot,        'the docroot was created' );
    ok( -d "$base/nx/site", 'and so was its parent, from its own declaration' );
};

# --- and a real install produces those modes ---------------------------------

subtest 'a fresh install creates the declared directories at the declared mode' => sub {
    my $base    = tempdir( 'lazysite-installrun-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $docroot = "$base/site";
    my $cgibin  = "$base/cgi-bin";
    make_path( $docroot, $cgibin );

    my $out = `$^X \Q$INSTALL\E --docroot \Q$docroot\E --cgibin \Q$cgibin\E 2>&1`;
    is( $? >> 8, 0, 'install exited 0' ) or diag $out;

    my %want;
    for my $d (@$declared) {
        my $p = $d->{path};
        # Only the docroot-relative ones: {DOCROOT}/.. paths land outside the
        # temp site directory and {CGIBIN} is pre-created by the harness.
        next unless $p =~ s{\A\Q{DOCROOT}\E/}{};
        next if $p eq '..' || $p =~ m{\A\.\./};
        $want{"$docroot/$p"} = oct( $d->{mode} );
    }
    cmp_ok( scalar keys %want, '>=', 15, 'checking a meaningful number of dirs' );

    my @wrong;
    for my $path ( sort keys %want ) {
        unless ( -d $path ) {
            # Not every declared directory is populated on every install (a
            # bucket may be empty in this build); absent is not a failure here,
            # the coverage check above is what guards the set.
            next;
        }
        my $got = ( stat $path )[2] & 07777;
        push @wrong, sprintf( '%s: want %04o, got %04o', $path, $want{$path}, $got )
            if $got != $want{$path};
    }
    is_deeply( \@wrong, [], 'every created directory carries its declared mode' )
        or diag( join "\n  ", '', @wrong,
        'A directory created at the umask default rather than the declared mode',
        'is the exact fault SM246 deliverable 1 identified.' );
};

done_testing();

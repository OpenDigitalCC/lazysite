#!/usr/bin/perl
# SM268: regression tests for the installer findings of the August 2026 review.
#
# These matter more than most, because install.pl runs as ROOT by the documented
# deploy path, and SM246 GUARANTEES the docroot and lazysite/ are group-writable.
# That combination is what turned "the installer trusts its destinations" into
# local privilege escalation: any account that can create a name in the docroot -
# the CGI, the site user, a compromised plugin - chose a file for the next
# upgrade to overwrite, chmod or chown as root.
#
#   H5   every write and every mode change followed symlinks. Five attacks
#        landed, including `chmod 2775` onto an arbitrary file outside the
#        docroot, and 39 files written outside via a symlinked intermediate.
#   H6   restore let the archive choose destinations via `..` members.
#   H7   the tar file-list was a predictable name in a group-writable directory.
#   H16  --restore-full omitted --no-same-permissions, so as root it restored
#        setuid bits out of the tarball.
#
# The symlink cases are driven as an unprivileged user, which is how the reviewer
# proved them: the guard is about what the code TRUSTS, not about being root.
#
# ON THE NEGATIVE CHECK, stated so nobody reads more into it than it carries.
# Run against the pre-fix tree this file fails at the extraction step - the
# guards do not exist to extract - rather than failing subtest by subtest. That
# is inherent: you cannot behaviourally test a guard that is absent. What each
# subtest does prove is that the guard REFUSES the attack and PERMITS the
# ordinary case, which is where a guard usually goes wrong later - by being
# quietly loosened, or by being tightened until someone removes it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $INSTALL = repo_root() . '/install.pl';
plan skip_all => 'install.pl not found' unless -f $INSTALL;

# The subs are extracted and driven directly - the same modulino trick
# t/tools/34 uses - so the guards can be exercised without a whole install.
my $src = do {
    open my $fh, '<', $INSTALL or die $!;
    local $/;
    <$fh>;
};
my ($symtest)  = $src =~ /(sub _is_symlink\b.*?\n\})/s;
my ($symguard) = $src =~ /(sub _refuse_symlink\b.*?\n\})/s;
my ($extract)  = $src =~ /(sub safe_tar_extract\b.*?\n\})/s;

# Comments stripped, and the guarded extractor itself removed, so the checks
# below cannot be satisfied (or defeated) by prose ABOUT the fix. Two tests
# earlier in this review passed for exactly that reason.
my $code         = join "\n", grep { !/^\s*#/ } split /\n/, $src;
my $code_outside = $code;
$code_outside =~ s/\Qsub safe_tar_extract\E.*?\n\}//s;
ok( defined $symtest && defined $symguard, 'the symlink guards were found' );
ok( defined $extract,                      'the guarded extractor was found' );
{
    no warnings 'redefine';
    eval "$symtest $symguard $extract 1" or die $@;    ## no critic
}

# --- H5 ---------------------------------------------------------------------
subtest 'a symlinked destination is refused, not followed' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/outside");
    open my $vf, '>', "$d/outside/victim" or die $!;
    print {$vf} "ORIGINAL\n";
    close $vf;
    symlink "$d/outside/victim", "$d/link" or plan skip_all => 'no symlink support';

    ok( main::_is_symlink("$d/link"),
        'the guard sees a link where -e / -d would see the target' );

    my $died = !eval { main::_refuse_symlink( "$d/link", 'write' ); 1 };
    ok( $died, 'and refuses' );
    like( $@, qr/symlink/, 'naming the reason' );

    # A real file is not refused - a guard that refuses everything gets removed.
    open my $rf, '>', "$d/real" or die $!;
    close $rf;
    ok( eval { main::_refuse_symlink( "$d/real", 'write' ); 1 },
        'a real file passes' );
    ok( eval { main::_refuse_symlink( "$d/absent", 'write' ); 1 },
        'and so does a path that does not exist yet' );
};

# --- H6 ---------------------------------------------------------------------
subtest 'an archive with a traversal member is refused' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/stage/sub", "$d/dest", "$d/outside" );
    open my $f, '>', "$d/stage/sub/payload" or die $!;
    print {$f} "PWNED\n";
    close $f;

    # A member spelled ../outside/payload - the shape that escapes -C.
    my $tar = "$d/evil.tar.gz";
    system( 'tar', 'czf', $tar, '-C', "$d/stage", '--transform',
        's|^sub/payload|../outside/payload|', 'sub/payload' ) == 0
        or plan skip_all => 'tar --transform unavailable';

    my @members = `tar tzf \Q$tar\E 2>/dev/null`;
    ok( ( grep { m{\.\./} } @members ),
        'the archive really does carry a traversal member - otherwise this '
            . 'test would pass for the wrong reason' );

    my $died = !eval { main::safe_tar_extract( $tar, "$d/dest" ); 1 };
    ok( $died, 'the extractor refuses the whole archive' );
    ok( !-e "$d/outside/payload",
        'and nothing was written outside the destination' );
};

subtest 'an ordinary archive still extracts' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/stage", "$d/dest" );
    open my $f, '>', "$d/stage/page.md" or die $!;
    print {$f} "# hello\n";
    close $f;
    my $tar = "$d/ok.tar.gz";
    system( 'tar', 'czf', $tar, '-C', "$d/stage", '.' ) == 0 or die;

    my $rc = main::safe_tar_extract( $tar, "$d/dest" );
    is( $rc, 0, 'extracted' );
    ok( -f "$d/dest/page.md", 'and the content landed' );
};

# --- H16 --------------------------------------------------------------------
subtest 'the extractor never restores setuid or archived modes' => sub {
    like( $extract, qr/--no-same-permissions/,
        'both restore paths pass --no-same-permissions - as root, without it, '
            . 'a tarball restores setuid bits' );
    like( $extract, qr/--no-same-owner/, 'and --no-same-owner' );

    # Both call sites must go through it, or the flag is decorative.
    my @raw = ( $code_outside =~ /system\(\s*'tar',\s*'-?xzf'/g );
    is( scalar @raw, 0,
        'no restore path shells out to tar -x directly any more - every one '
            . 'goes through the guarded extractor' );
};

# --- H7 ---------------------------------------------------------------------
subtest 'the backup file-list is never written to disk' => sub {
    unlike( $code, qr/\.backup-list-/,
        'the predictable name in the group-writable backups dir is gone - it '
            . 'was a symlink-plant target, and this runs as root' );
    like( $code, qr/'--files-from',\s*'-'/,
        'the list is piped to tar instead, so there is nothing to plant' );
    # Order is load-bearing: --verbatim-files-from is positional and tar exits
    # non-zero if it follows --files-from, which aborts the upgrade.
    like( $code, qr/'--verbatim-files-from',\s*\n?\s*'--files-from'/s,
        'and --verbatim-files-from precedes it' );
};

done_testing();

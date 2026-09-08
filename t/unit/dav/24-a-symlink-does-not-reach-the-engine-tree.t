#!/usr/bin/perl
# SM795, the DAV half. The engine tree is blocked by REQUEST REL - authorise()
# refuses a request whose relative path starts lazysite/ - and the resolver
# confined only to the DOCROOT BOUNDARY. In the inside-docroot layout the
# engine tree is under the docroot, so a symlink at content/leak.png resolving
# into lazysite/ passed both tests: its rel does not begin with lazysite/, and
# its real path is inside the docroot.
#
# The rule this project already holds (SM268): blocklist on the CANONICAL
# resolved path, never on the request string.
#
# THE DIFFICULT PART, and why this was filed as its own change rather than
# folded into the processor fix: DAV has SANCTIONED ways into the engine tree -
# lazysite/nav.conf, lazysite/forms/<name>.conf under manage_forms, the layouts
# subtree - each carved out in authorise() by request rel. A blanket exclusion
# refuses those, and the first version of this fix did exactly that. So the
# check applies only where the request does NOT name an engine path, which is
# precisely the symlink case and precisely what authorise() cannot see.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

plan skip_all => 'this filesystem does not do symlinks'
    unless eval { my $d = site_tempdir(); symlink( '/tmp', "$d/probe" ) };

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-dav.pl" or die $!;
    local $/;
    <$fh>;
};
my ($sub) = $src =~ /(sub resolve_under_docroot \{.*?\n\})/s;
ok( $sub, 'the resolver was found' ) or do { done_testing; exit };

subtest 'the resolver excludes the engine tree on the CANONICAL path' => sub {
    like( $sub, qr/realpath\(\$LAZYSITE_DIR\)/,
        'it resolves the engine tree rather than comparing strings' );
    like( $sub, qr/for my \$p \( \$rp, \$full \)/,
        'and checks the resolved PARENT as well as the target - a symlinked '
            . 'directory would otherwise put everything beneath it in reach' );
};

subtest 'the sanctioned ways in are preserved' => sub {
    like( $sub, qr/\$names_engine/,
        'the check is skipped where the request itself names an engine path' );
    like( $sub, qr{\\Alazysite\(\?:/\|\\z\)},
        'recognised by the request rel, which is what authorise() has already ruled on' );
    # The carve-outs this would have broken, named so the next reader knows
    # they are not hypothetical: t/unit/dav/13 is the one that caught it.
    like( $src, qr/manage_forms/,        'lazysite/forms/<name>.conf is one of them' );
    like( $src, qr/lazysite\/nav\.conf/, 'and lazysite/nav.conf another' );
};

# The mechanism itself, with a real symlink and real realpath, so this rests on
# the filesystem rather than on a reading of the source.
subtest 'a symlink out of the content tree resolves into the engine tree' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    make_path("$d/content");
    open my $fh, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$fh} 'the-session-secret';
    close $fh;
    symlink( "$d/lazysite/auth/.secret", "$d/content/leak.png" )
        or plan skip_all => 'could not create the symlink';

    require Cwd;
    my $real  = Cwd::realpath("$d/content/leak.png");
    my $droot = Cwd::realpath($d);
    my $lz    = Cwd::realpath("$d/lazysite");

    # Both of the OLD tests pass for this file, which is the whole finding.
    is( index( $real, "$droot/" ), 0,
        'the resolved path is inside the docroot, so the boundary check passes' );
    unlike( 'content/leak.png', qr{\Alazysite(?:/|\z)},
        'and the request rel does not name the engine tree, so authorise() allows it' );

    # And the new one refuses it.
    is( index( $real, "$lz/" ), 0,
        'while the CANONICAL path is inside the engine tree, which is what the '
            . 'resolver now refuses' );
};

done_testing;

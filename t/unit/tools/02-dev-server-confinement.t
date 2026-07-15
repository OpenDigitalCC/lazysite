#!/usr/bin/perl
# SEC-2026-07 (H7): the dev server's static/auto-index handlers run before the
# processor's confinement, so _dev_path_ok() must deny the lazysite/ management
# tree (secrets, hashes, ACLs, logs), dotfiles, and traversal - matching the
# production vhosts - while still allowing ordinary content files. The server is
# a require-safe modulino, so we drive the pure predicate directly (no port).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $server = repo_root() . '/tools/lazysite-server.pl';
require $server;
can_ok( 'main', '_dev_path_ok' );

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/sub" );
for my $f (
    "$d/page.html",           "$d/sub/a.css",
    "$d/lazysite/auth/users", "$d/lazysite/auth/.secret",
    "$d/.hidden",             "$d/audit.log"
    )
{
    open my $fh, '>', $f or die "$f: $!";
    print $fh "x\n";
    close $fh;
}
# --- allowed: ordinary content ---------------------------------------------
ok( main::_dev_path_ok( '/page.html', "$d/page.html", $d ), 'a normal file is served' );
ok( main::_dev_path_ok( '/sub/a.css', "$d/sub/a.css", $d ), 'a nested file is served' );

# --- denied: the lazysite/ management tree ---------------------------------
ok( !main::_dev_path_ok( '/lazysite/auth/users', "$d/lazysite/auth/users", $d ),
    'password-hash store denied' );
ok( !main::_dev_path_ok( '/lazysite/auth/.secret', "$d/lazysite/auth/.secret", $d ),
    'signing secret denied' );

# --- denied: dotfiles ------------------------------------------------------
ok( !main::_dev_path_ok( '/.hidden', "$d/.hidden", $d ), 'a dotfile is denied' );

# --- allowed by name but it is still content: a .log at the root -----------
# (audit.log lives under lazysite/ in a real site; a root-level log is content)
ok( main::_dev_path_ok( '/audit.log', "$d/audit.log", $d ),
    'a root-level .log is content (only lazysite/ logs are secret)' );

# --- denied: traversal -----------------------------------------------------
ok( !main::_dev_path_ok( '/../../etc/passwd', "$d/../../etc/passwd", $d ),
    'traversal out of the docroot is denied' );
ok( !main::_dev_path_ok( '/sub/../lazysite/auth/users', "$d/sub/../lazysite/auth/users", $d ),
    'traversal into lazysite/ is denied' );

done_testing();

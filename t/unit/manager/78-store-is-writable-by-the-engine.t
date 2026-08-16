#!/usr/bin/perl
# SM323: whoever creates the private store must not decide who can use it.
#
# THE FINDING, measured on 0.10.10 the day after it deployed. A fresh folder was
# protected through the control API on a site whose docroot was writable and
# whose operator sweep had already succeeded:
#
#   {"ok":1,"content_moved":0,
#    "warnings":["... could not move \"/home/.../public_html/zz-1010\" into
#     place: Permission denied ..."]}
#
# list_files reported 11 of 11 entries still public, and eight of ten probed
# extensions served 200 anonymously under an active read rule. The SAME rule
# applied by `acl reapply` on the SAME instance moved its content successfully.
#
# So two paths applying an identical rule had different privilege, and only one
# worked. Protecting content had become an OPERATOR-ONLY operation on a product
# whose partner surfaces - the manager UI, MCP, the control API - are supposed to
# perform it.
#
# THE CAUSE. Two creators, no agreement:
#
#   Private::_mkpath    a bare make_path. Whoever calls it owns the result with a
#                       umask default. The sweep runs as the SITE USER.
#   check --fix         chown to the site user + CGI group, chmod 2770 (SM313).
#
# Whichever runs first decides. On a site being repaired the sweep gets there
# first, so the store ends up owned by the site user with no group write, and the
# CGI is locked out of a directory it must write into on every protect.
#
# SM313 also taught --fix to CREATE a missing store and stopped there, so a store
# that existed in the wrong shape was reported on every run and repaired by
# nothing.
#
# WHY THE OBVIOUS HELPER IS THE WRONG ONE. Util::secure_write_perms mirrors a
# path's PARENT. The store's parent is the domain folder, which on the Hestia
# layout is root-owned 0551 - mirroring it would lock out everyone. The store is
# the docroot's private twin and carries the DOCROOT's identity.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Private ();

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path("$doc/section");

open my $fh, '>', "$doc/section/index.md" or die $!;
print $fh "---\ntitle: S\n---\n\nBody.\n";
close $fh;

subtest 'a store created by a protect carries the docroot identity' => sub {
    my ( $ok, $err ) = Lazysite::Private::move_in( $doc, 'section' );
    ok( $ok, 'the content moved' ) or diag( "error: " . ( $err // '' ) );

    my $store = Lazysite::Private::private_root($doc);
    ok( -d $store, 'the store exists' ) or return;

    my @d = stat $doc;
    my @s = stat $store;

    is( $s[5], $d[5],
        'the store carries the DOCROOT group, not its own parent\'s' )
        or diag( "docroot gid $d[5], store gid $s[5]\n"
            . "The store's parent is the domain folder - root-owned 0551 on\n"
            . "Hestia. Mirroring the parent is what locks the CGI out." );

    is( sprintf( '%04o', $s[2] & 07777 ), '2770',
        'and mode 2770 - setgid so moved content keeps the group, no world bit' );
};

subtest 'a directory created DEEP in the store gets it too' => sub {
    # make_path may create several levels, and the one that matters is whichever
    # the CGI writes into next. Getting only the leaf right leaves an
    # intermediate the engine cannot traverse.
    make_path("$doc/a/b/c");
    open my $p, '>', "$doc/a/b/c/index.md" or die $!;
    print $p "---\ntitle: Deep\n---\n\nBody.\n";
    close $p;

    my ( $ok, $err ) = Lazysite::Private::move_in( $doc, 'a/b/c' );
    ok( $ok, 'a nested section moves' ) or diag( "error: " . ( $err // '' ) );

    my $store = Lazysite::Private::private_root($doc);
    my @d     = stat $doc;
    for my $lvl ( '', '/a', '/a/b' ) {
        my $dir = "$store$lvl";
        next unless -d $dir;
        my @s = stat $dir;
        is( $s[5], $d[5], "the store$lvl level carries the docroot group" );
        is( sprintf( '%04o', $s[2] & 07777 ), '2770',
            "the store$lvl level is 2770" );
    }
};

subtest 'move_out does NOT apply store perms to a docroot directory' => sub {
    # The other direction creates a directory in the DOCROOT, which is 2775 and
    # world-readable on purpose - it is the served tree. Applying the store's
    # 2770 there would make un-protecting content quietly unreadable to the web
    # server, which is the opposite failure and just as silent.
    my $src = do {
        open my $r, '<', "$FindBin::Bin/../../../lib/Lazysite/Private.pm" or die $!;
        local $/;
        <$r>;
    };
    my ($move_out) = $src =~ /\nsub move_out \{(.*?)\n\}\n/s;
    ok( $move_out, 'move_out is present' ) or return;
    like( $move_out, qr/_mkpath\(\s*\$parent\s*\)/,
        'move_out calls _mkpath WITHOUT the docroot, so no store shape is applied' )
        or diag( 'A docroot directory made 2770 would be unreadable to the web '
            . 'server - un-protecting content would hide it instead.' );
};

subtest 'check --fix repairs a store that exists in the wrong shape' => sub {
    # SM313 created a missing store and stopped. A store that exists and is
    # unusable was reported on every run and repaired by nothing, which is the
    # state the field found.
    my $chk = do {
        open my $r, '<', "$FindBin::Bin/../../../tools/lazysite-check.pl" or die $!;
        local $/;
        <$r>;
    };

    like( $chk, qr/\$store_repair_needed/,
        'an unwritable existing store is queued for repair' );
    like( $chk, qr/chmod 02770, \$s/, 'repaired to 2770' );
    like( $chk, qr/File::Find::find/,
        'and its CONTENTS too - a store populated by a sweep running as the '
            . 'site user holds files the CGI cannot rewrite either, and '
            . 'un-protecting has to move them back out' );

    # The report must say what it actually costs, because "cannot write to it"
    # reads as housekeeping and this is a partner surface being unable to work.
    like( $chk, qr/only the operator sweep can/,
        'and the message names the real consequence' );
};

done_testing();

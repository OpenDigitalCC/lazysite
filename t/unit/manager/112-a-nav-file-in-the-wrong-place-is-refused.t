#!/usr/bin/perl
# SM581: a nav-shaped file under a CONTENT ROOT is not a navigation.
#
# Found by the site agent on a live instance: it wrote
# /sites/xisl/lazysite/nav.conf, was told created:1 with
# cache_rebuilt:all-pages, and the live nav did not change. The path is
# neither the primary's nav_file nor the domain's, and because the blocklist
# keys on a LEADING `lazysite/` it is not blocked either - so it lands as
# ordinary content that nothing reads, reported exactly like the write that
# would have worked.
#
# Two assertions, and they are separate defects sharing one cause:
#
#   1. THE WRITE. A path ending `lazysite/nav.conf` that is not the resolved
#      nav for any configured domain is REFUSED, naming set_nav and its host
#      argument. Refusal rather than a warning is affordable precisely because
#      the resolved navs are enumerable: the primary's nav_file and each
#      alias.<host>.nav_file are named and let through, so no legitimate write
#      reaches the refusal.
#
#   2. THE CLAIM. action_save treated ANY path ending nav.conf as a nav
#      change - dropping every generated .html and claiming all-pages for a
#      file that is not a navigation. The claim must follow what was actually
#      invalidated.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files   ();
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Nav     ();
use Lazysite::Auth::Acl        ();

# own.example's nav_file DELIBERATELY sits at the shape the refusal keys on.
# It is a configured nav, so it must still save - the guard has to know the
# difference between a nav in an unusual place and a file that is not a nav.
my $CONF = <<'CONF';
site_name: Primary
nav_file: lazysite/nav.conf
alias_hosts: xisl.example, own.example
alias.xisl.example.content_root: sites/xisl
alias.own.example.content_root: sites/own
alias.own.example.nav_file: sites/own/lazysite/nav.conf
CONF

sub write_file {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
    return;
}

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite", "$d/lazysite/cache", "$d/content",
        "$d/sites/xisl", "$d/sites/own/lazysite" );
    write_file( "$d/lazysite/lazysite.conf",      $CONF );
    write_file( "$d/lazysite/nav.conf",           "Home | /\n" );
    write_file( "$d/sites/own/lazysite/nav.conf", "Home | /\n" );

    # Generated renders, so a cache claim has something to be true about.
    write_file( "$d/index.html",            '<html>primary</html>' );
    write_file( "$d/sites/xisl/index.html", '<html>xisl</html>' );

    $Lazysite::Manager::Files::DOCROOT    = $d;
    $Lazysite::Manager::Files::LOCK_DIR   = "$d/lazysite/manager/locks";
    $Lazysite::Manager::Common::DOCROOT   = $d;
    $Lazysite::Auth::Acl::DOCROOT         = $d;
    $Lazysite::Manager::Domains::DOCROOT  = $d;
    $Lazysite::Manager::Nav::DOCROOT      = $d;
    $Lazysite::Manager::Nav::LAZYSITE_DIR = "$d/lazysite";
    return $d;
}

sub renders {
    my ($d) = @_;
    return scalar grep { -f } ( "$d/index.html", "$d/sites/xisl/index.html" );
}

my $NAV = "Home | /\nAbout | /about\n";

subtest 'a nav-shaped path under a content root is refused' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Files::action_save(
        'sites/xisl/lazysite/nav.conf', 'op', $NAV );

    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'nav-not-here', 'and says what kind of wrong this is' );
    like( $r->{error}, qr/\bset_nav\b/, 'the message names set_nav' );
    like( $r->{error}, qr/\bhost\b/,    'and its host argument' );
    like( $r->{error}, qr/xisl\.example/,
        'and the domain whose content root the caller was writing into' )
        or diag( 'The reply has to be actionable on its own: the agent that '
            . 'hit this had no way to tell a successful write from an inert one.' );

    ok( !-e "$d/sites/xisl/lazysite/nav.conf", 'nothing landed' );
    is( renders($d), 2, 'and no cached render was dropped for it' );
};

subtest 'the primary nav still saves' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Files::action_save(
        'lazysite/nav.conf', 'op', $NAV );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    is( $r->{cache_rebuilt}, 'all-pages', 'a real nav change rebuilds' );
    is( renders($d),         0,           'and every generated render is gone' );
    is( $r->{cache_cleared}, 2,           'the reply counts what it actually dropped' )
        or diag( 'all-pages is a label. The count is the fact, and it is the '
            . 'only thing that distinguishes a rebuild from a claim.' );
};

subtest "a domain's OWN nav_file at that shape still saves" => sub {
    # own.example resolves its nav to sites/own/lazysite/nav.conf. The guard
    # must let it through, or the refusal has broken a supported configuration.
    my $d = fixture();
    my $r = Lazysite::Manager::Files::action_save(
        'sites/own/lazysite/nav.conf', 'op', $NAV );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    open my $fh, '<', "$d/sites/own/lazysite/nav.conf" or die $!;
    my $got = do { local $/; <$fh> };
    close $fh;
    is( $got,                $NAV,        'and the configured nav is written' );
    is( $r->{cache_rebuilt}, 'all-pages', 'this one IS a nav change' );
};

subtest 'a file merely NAMED nav.conf claims nothing' => sub {
    # content/nav.conf is not the resolved nav for any domain. It is ordinary
    # content: it saves, and it must not drop every render on the instance
    # while reporting a rebuild that had nothing to do.
    my $d = fixture();
    my $r = Lazysite::Manager::Files::action_save(
        'content/nav.conf', 'op', "not a navigation\n" );
    ok( $r->{ok},                    'saved as ordinary content' ) or diag explain $r;
    ok( !exists $r->{cache_rebuilt}, 'no rebuild is claimed' )
        or diag( 'Claiming all-pages here is the second half of the defect: '
            . 'the reply that told the agent its nav had been published.' );
    is( renders($d), 2, 'and no render was dropped' );
};

done_testing();

#!/usr/bin/perl
# SM598: a handlers.conf path built from an undefined docroot landed at the
# filesystem root, and the WRITER tried to create a directory there.
#
# _lz() is Lazysite::Paths::lazysite_dir($DOCROOT), which returns undef for an
# undefined or empty docroot - a deliberate guard. _handlers_conf_path
# concatenated it anyway, producing "/forms/handlers.conf": an absolute path
# outside every site.
#
# It surfaced as a Perl warning in the 0.10.33 release run and the tests passed
# either way, because nothing exists at that path - so the READ found nothing
# and the code around it treated that as "no handlers configured". The wrong
# answer, arriving indistinguishably from the right one.
#
# The WRITER is the sharper half and the reason this is not merely tidy:
# make_path(dirname($path)) with no docroot is an attempt to create /forms at
# the root of the filesystem, and then to write a config file into it. It fails
# for want of permission on any sane host, which is luck, not design.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
require Lazysite::Manager::Plugins;

# --- 1. no docroot yields no path -------------------------------------------
{
    local $Lazysite::Manager::Plugins::DOCROOT = undef;
    my $p = Lazysite::Manager::Plugins::_handlers_conf_path();
    is( $p, undef, 'an undefined docroot yields no path at all' );
}
{
    local $Lazysite::Manager::Plugins::DOCROOT = '';
    my $p = Lazysite::Manager::Plugins::_handlers_conf_path();
    is( $p, undef, 'and neither does an empty one' );
}

# --- 2. it is never a root-anchored path ------------------------------------
# The specific shape of the defect: "/forms/handlers.conf". Asserted directly,
# because "undef" and "a path that happens to be wrong" are different failures
# and only one of them is caught by the check above.
{
    for my $d ( undef, '' ) {
        local $Lazysite::Manager::Plugins::DOCROOT = $d;
        my $p = Lazysite::Manager::Plugins::_handlers_conf_path();
        isnt( $p, '/forms/handlers.conf',
            'never the filesystem-root path the concatenation used to produce' );
    }
}

# --- 3. a real docroot still works ------------------------------------------
# The guard must not have made the ordinary case unreachable.
{
    local $Lazysite::Manager::Plugins::DOCROOT = '/srv/example/public_html';
    my $p = Lazysite::Manager::Plugins::_handlers_conf_path();
    ok( defined $p, 'a real docroot still yields a path' );
    like( $p, qr{^/srv/example/public_html/.*forms/handlers\.conf$},
        'inside the site, where it belongs' );
}

# --- 4. the writer refuses rather than writing to the root ------------------
# The assertion that matters. A reader returning [] is survivable; a writer
# creating /forms is not.
{
    local $Lazysite::Manager::Plugins::DOCROOT = undef;
    my $rc = Lazysite::Manager::Plugins::_write_handlers_conf( [] );
    ok( !$rc,         'the writer refuses when there is no docroot' );
    ok( !-e '/forms', 'and created nothing at the filesystem root' );
}

# --- 5. the reader says no-docroot is not no-handlers ----------------------
# Both return an empty list. One of them is a fault, and it says so once.
{
    local $Lazysite::Manager::Plugins::DOCROOT = undef;
    my $h = Lazysite::Manager::Plugins::_parse_handlers_conf();
    is_deeply( $h, [], 'the reader still returns an empty list' );

    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Plugins.pm" or die $!;
        local $/; <$fh>;
    };
    my ($fn) = $src =~ /(sub _parse_handlers_conf \{.*?\n\})/s;
    like( $fn, qr/log_event/,
        'and logs, so a missing docroot is distinguishable from a site with '
            . 'no handlers configured - the two are not the same finding' );
}

done_testing();

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
#
# SM842: handlers.conf moved to Lazysite::Handlers, the one reader and writer,
# and the guard moved with it. The reader is now stronger than SM598 left it:
# no docroot answers undef - "cannot tell" - rather than an empty list.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
require Lazysite::Handlers;

# --- 1. no docroot yields no path -------------------------------------------
for my $d ( undef, '' ) {
    local $Lazysite::Handlers::DOCROOT = $d;
    my $p = Lazysite::Handlers::handlers_file();
    is( $p, undef, 'no docroot (' . ( defined $d ? 'empty' : 'undef' ) . ') yields no path at all' );
    isnt( $p, '/forms/handlers.conf',
        'never the filesystem-root path the concatenation used to produce' );
    is( Lazysite::Handlers::schedule_file(), undef, 'nor a schedule path' );
}

# --- 2. a real docroot still works ------------------------------------------
{
    local $Lazysite::Handlers::DOCROOT = '/srv/example/public_html';
    my $p = Lazysite::Handlers::handlers_file();
    ok( defined $p, 'a real docroot still yields a path' );
    like( $p, qr{^/srv/example/public_html.*/forms/handlers\.conf$}, 'inside the site, where it belongs' );
}

# --- 3. the writer refuses rather than writing to the root ------------------
{
    local $Lazysite::Handlers::DOCROOT = undef;
    my ( $ok, $why ) = Lazysite::Handlers::write_handlers( [] );
    ok( !$ok,         'the writer refuses when there is no docroot' );
    like( $why, qr/no docroot/, 'and says why' );
    ok( !-e '/forms', 'and created nothing at the filesystem root' );
}

# --- 4. the reader says no-docroot is not no-handlers ----------------------
{
    local $Lazysite::Handlers::DOCROOT = undef;
    my @log;
    no warnings 'redefine';
    local *Lazysite::Handlers::log_event = sub { push @log, [@_] };
    is( Lazysite::Handlers::read_handlers(), undef,
        'the reader answers undef - cannot tell - not an empty list' );
    ok( ( grep { ( $_->[2] // '' ) =~ /no docroot/ } @log ),
        'and logs, so a missing docroot is distinguishable from a site with no handlers' );
    my $r = Lazysite::Handlers::action_handler_list();
    ok( !$r->{ok}, 'and the listing refuses rather than showing an empty site' );
}

done_testing();

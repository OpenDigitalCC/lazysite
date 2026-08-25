#!/usr/bin/perl
# SM582: PUT has TWO size gates and the suite only ever reached one of them.
#
# do_put refuses a declared CONTENT_LENGTH over max_bytes before it reads a
# byte; _stream_body counts what it actually copies and refuses past the same
# ceiling. Every existing test declares a length, so the pre-read gate always
# answered first and the streaming ceiling was unreachable in testing - which
# the SM516 sabotage sweep found by breaking it and seeing nothing fail.
#
# A client that does not know the size up front sends no CONTENT_LENGTH at all
# (chunked transfer), and then the byte counter is the ONLY thing between the
# docroot and an unbounded body. These three cases together pin it to the
# counter rather than to the header check:
#
#   under the ceiling, no length  -> written whole (the no-length path really
#                                    does reach the body writer)
#   over the ceiling,  no length  -> 413, nothing on disk (only the counter can
#                                    answer: `defined $clen` is false, so the
#                                    pre-read gate cannot fire)
#   over the ceiling, declared    -> 413 (the pre-read gate, a control that
#                                    passes either way)
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav);

# The smallest ceiling the conf can express is 1 MB, so the oversize bodies
# are just over that. The child stops reading the moment it passes the
# ceiling and exits, leaving the parent's write to meet EPIPE - which is the
# correct behaviour, not a test failure.
local $SIG{PIPE} = 'IGNORE';

my $MB       = 1024 * 1024;
my $CONF     = "webdav_enabled: true\nmanager_upload_max_mb: 1\n";
my $OVERSIZE = "---\ntitle: Big\n---\n" . ( 'x' x ( $MB + 128 * 1024 ) );
my $MODEST   = "---\ntitle: Modest\n---\n" . ( 'y' x ( 200 * 1024 ) );

sub tmp_artefacts {
    my ($dir) = @_;
    opendir my $dh, $dir or return ();
    my @t = grep { /\.tmp\./ } readdir $dh;
    closedir $dh;
    return @t;
}

# --- an undeclared body UNDER the ceiling is written whole -------------------
# Without this the oversize case below proves nothing: a 413 for a request with
# no CONTENT_LENGTH could just as well mean the surface refuses undeclared
# bodies outright.
{
    my $s = setup_dav_site( conf => $CONF );
    my $r = run_dav(
        $s->{docroot}, 'PUT', '/content/modest.md',
        body               => $MODEST,
        CONTENT_LENGTH     => undef,
        HTTP_AUTHORIZATION => $s->{auth},
    );
    is( $r->{code}, 201, 'a PUT with no declared length is accepted' );
    ok( -f "$s->{docroot}/content/modest.md", 'and the file is written' );
    is( -s "$s->{docroot}/content/modest.md",
        length($MODEST), 'with every byte of the body - it was read to EOF' );
}

# --- an undeclared body OVER the ceiling is refused BY THE COUNTER -----------
{
    my $s = setup_dav_site( conf => $CONF );
    my $r = run_dav(
        $s->{docroot}, 'PUT', '/content/undeclared-big.md',
        body               => $OVERSIZE,
        CONTENT_LENGTH     => undef,
        HTTP_AUTHORIZATION => $s->{auth},
    );
    is( $r->{code}, 413,
        'an undeclared body past the ceiling is refused - and nothing but '
            . 'the streaming counter can have refused it' );
    ok( !-e "$s->{docroot}/content/undeclared-big.md",
        'no file at the target path' );
    is( scalar tmp_artefacts("$s->{docroot}/content"),
        0, 'and no partial .tmp. file left behind by the abandoned stream' );
}

# --- the pre-read gate still answers a declared oversize length -------------
# The control: same body, same ceiling, one header different. It passes with
# the streaming counter broken, which is exactly why it cannot stand in for
# the case above.
{
    my $s = setup_dav_site( conf => $CONF );
    my $r = run_dav(
        $s->{docroot}, 'PUT', '/content/declared-big.md',
        body               => $OVERSIZE,
        CONTENT_LENGTH     => length($OVERSIZE),
        HTTP_AUTHORIZATION => $s->{auth},
    );
    is( $r->{code}, 413, 'a declared oversize length is still refused' );
    ok( !-e "$s->{docroot}/content/declared-big.md",
        'and nothing is written for it either' );
}

done_testing();

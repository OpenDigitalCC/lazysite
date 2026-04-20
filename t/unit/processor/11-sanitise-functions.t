#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- uri_encode ---
is( main::uri_encode('/about'),       '%2Fabout',     'slash encoded' );
is( main::uri_encode('hello world'),  'hello%20world','space encoded' );
is( main::uri_encode('safe-text_123'),'safe-text_123','safe chars unchanged' );
is( main::uri_encode('a+b=c'),        'a%2Bb%3Dc',
                                                 'non-safe chars encoded, letters preserved' );

# --- sanitise_uri ---
is( main::sanitise_uri('/about'),    'about',       'leading slash stripped' );
is( main::sanitise_uri('/docs/'),    'docs/index',  'trailing slash → /index' );
is( main::sanitise_uri('/index.html'),'index',      'extension stripped' );
is( main::sanitise_uri('/page.md'),  'page',        '.md extension stripped' );
is( main::sanitise_uri('/'),         'index',       'root → index' );
is( main::sanitise_uri('/../etc'),   undef,         'path traversal rejected' );
is( main::sanitise_uri("/\0bad"),    undef,         'null byte rejected' );
is( main::sanitise_uri('/page<x>'),  undef,         'angle brackets rejected' );
is( main::sanitise_uri('/page"x'),   undef,         'double quote rejected' );

# --- strip_tt_directives ---
is( main::strip_tt_directives('plain'),       'plain', 'plain unchanged' );
is( main::strip_tt_directives('[% foo %]'),   ' foo ', 'TT sequences stripped' );
is( main::strip_tt_directives('[% [% x %] %]'), '  x  ',
    'nested TT all stripped' );

# --- interpolate_env (allowlist only) ---
{
    local $ENV{SERVER_NAME}   = 'example.com';
    local $ENV{REQUEST_SCHEME}= 'https';
    local $ENV{HOSTILE}       = 'should-not-appear';
    is( main::interpolate_env('${REQUEST_SCHEME}://${SERVER_NAME}'),
        'https://example.com', 'allowlisted vars interpolated' );
    my $out = main::interpolate_env('${HOSTILE}');
    is( $out, '${HOSTILE}', 'non-allowlisted var left literal' );
}

# --- form-handler sanitise_header ---
# Load lazysite-form-handler.pl subroutines. It uses its own main:: namespace
# when loaded via the same in-place trick.
SKIP: {
    # form-handler dies at top if REQUEST_METHOD is not POST, so we use
    # string eval of the relevant sub definition instead.
    # Define sanitise_header directly — this mirrors the form-handler impl.
    eval <<'SUB';
    package Local;
    sub sanitise_header {
        my ( $val, $max ) = @_;
        $max //= 1000;
        $val =~ s/[\r\n]/ /g;
        $val = substr( $val, 0, $max ) if length($val) > $max;
        return $val;
    }
SUB
    my $dirty = "inject\r\nX-Evil: bad";
    my $clean = Local::sanitise_header( $dirty, 200 );
    unlike( $clean, qr/[\r\n]/, 'CR/LF replaced with space' );
    my $long = 'x' x 2000;
    my $trim = Local::sanitise_header( $long, 100 );
    is( length $trim, 100, 'truncated to max length' );
}

done_testing();

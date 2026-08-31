#!/usr/bin/perl
# SM694: the PDF export plugin, and the boundary the filing said to settle first.
#
# This plugin is unlike every other one shipped: it runs an EXTERNAL BINARY on
# operator-supplied input. The dependency half was answered in 0.11.7 (`bins`,
# so SM472's "a plugin that cannot run is not enabled" applies to a program as
# well as a module). What was left was the execution side, and these are the
# four decisions, asserted rather than described:
#
#   a bounded root      - pandoc resolves image and include paths, so an
#                         unbounded conversion is a file-read primitive with the
#                         CGI's privileges;
#   a fixed argument list - nothing a caller sends reaches the command line;
#   read authority      - converting a page produces a copy of it;
#   bounded work        - no queue and no daemon (SM666), so it runs in the
#                         request and must be unable to run away with it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $plug = "$FindBin::Bin/../../../plugins/pandoc.pl";
plan skip_all => "no $plug" unless -f $plug;
require $plug;

my $src = do { open my $fh, '<', $plug or die $!; local $/; <$fh> };

# CODE ONLY. This plugin explains itself in prose that quotes flags and class
# names in backticks, and a shell-safety pattern matched against the prose finds
# what the prose is describing rather than what the code does. Third time this
# session a comment has been read as code (t/lint/96 on a CSS comment, SM700's
# Content-Length on a Perl one), so it is worth doing deliberately.
( my $code = $src ) =~ s/^\s*#.*$//mg;

subtest 'the dependency is DECLARED, so enabling is refused without it' => sub {
    my $d = main::describe();
    is_deeply( $d->{owns}{bins}, ['md-to-pdf'],
        'the WRAPPER is declared, not pandoc' )
        or diag( 'md-to-pdf is what this plugin calls; it owns the pandoc and '
            . 'XeLaTeX invocation, the templates and the brands. Declaring '
            . 'pandoc would let the plugin enable on a host that has pandoc and '
            . 'not the wrapper - the state `bins` exists to prevent.' );
    is_deeply( $d->{owns}{capabilities}, [],
        'and it invents no capability of its own' )
        or diag( 'Converting a page is reading it in another format. A new '
            . 'capability would be one more thing an operator has to reason '
            . 'about for no authority they did not already have.' );
};

subtest 'the argument list is built here, never by a caller' => sub {
    like( $code, qr/exec \{ \$cmd\[0\] \} \@cmd/,
        'the binary is exec-ed as a LIST' )
        or diag( 'A string form would hand the arguments to a shell, and then '
            . 'the quoting of a filename becomes a security question.' );
    unlike( $code, qr/system\s*\(\s*"/, 'no string-form system()' );
    unlike( $code, qr/`[^`]*\$/,        'no backticks interpolating a variable' );
    like( $code, qr/'--no-viewer'/,
        'the viewer is suppressed' )
        or diag( 'On a server there is no viewer to open, and a converter that '
            . 'tries to open one blocks the request until it is killed.' );
    unlike( $code, qr/default\s*=>\s*'brand'/,
        'the brand folder is not a bare docroot directory' )
        or diag( 'A folder named brand/ in the document root is SERVED: the '
            . 'templates, fonts and logos answer an anonymous request. Keep '
            . 'the default under lazysite/, which is not served and which the '
            . 'Files page still manages.' );
    like( $code, qr{lazysite/brands},
        'brands default to a path under lazysite/' );
    like( $code, qr/MD_TO_PDF_BRANDS/,
        'the brands base is pinned to this site' )
        or diag( 'The wrapper resolves brands from an environment variable, a '
            . 'config file, or its bundled default. Left unset, a document '
            . 'could name a brand resolved from elsewhere on the host.' );
};

subtest 'it converts, and the refusals refuse' => sub {
    plan skip_all => 'no md-to-pdf on this host' unless main::_converter_path();

    my $d = tempdir( CLEANUP => 1 );
    # SM694 follow-up: brands live UNDER lazysite/, which is not served. In the
    # document root every template, font and logo answered an anonymous GET
    # with 200 - measured on the dev server - which publishes an operator's
    # letterhead to anyone who guesses the path.
    make_path( "$d/lazysite/cache", "$d/lazysite/brands/house", "$d/docs" );
    open my $f, '>', "$d/docs/page.md" or die $!;
    # Front matter, because that is where the wrapper reads title and brand.
    print {$f} "---\ntitle: A Test Page\nbrand: plain\n---\n\n"
        . "# A page\n\nWith an accent: Je\x{c3}\x{bb}ne.\n";
    close $f;

    my $ok = main::convert( docroot => $d, path => 'docs/page.md' );
    ok( $ok->{ok}, 'a page converts' ) or diag( $ok->{error} // '' );
    cmp_ok( $ok->{bytes} || 0, '>', 1000,
        'and produces a real document, not an empty file' );

    # A .md file OUTSIDE the docroot. This is the case that actually proves the
    # traversal guard: `../../etc/passwd` is refused by the .md check whatever
    # the traversal guard does, so it proves nothing about traversal. A sabotage
    # removing the guard left the suite green until this case existed.
    # The cache dir must exist UNDER the alternate docroot too, or the
    # conversion fails for want of an output directory and the assertion below
    # passes without the guard having done anything. A refusal for the wrong
    # reason is indistinguishable from the right one, which is precisely the
    # trap this suite warns the field about.
    make_path("$d/docs/lazysite/cache");
    open my $o, '>', "$d/escaped.md" or die $!;
    print {$o} "# Not yours\n";
    close $o;
    # docroot is the docs/ subfolder; the target sits one level above it and is
    # a real, convertible .md - so only the traversal guard can refuse it.
    my $esc = main::convert( docroot => "$d/docs", path => '../escaped.md' );
    ok( !$esc->{ok}, 'a .md file outside the docroot is refused' )
        or diag( 'The traversal guard is the only thing refusing this - the '
            . 'extension check passes, the file exists, and pandoc would '
            . 'happily convert it.' );
    unlink "$d/escaped.md";

    # Each of these is a way somebody could try to read a file the conversion
    # was never meant to reach.
    for my $bad ( '../../etc/passwd', 'docs/../../etc/passwd', '/etc/passwd',
        'docs/page.txt', 'nope.md' ) {
        my $r = main::convert( docroot => $d, path => $bad );
        ok( !$r->{ok}, "refused: $bad" )
            or diag( 'The content path decides which file is opened. If this '
                . 'passes, the plugin reads whatever it is pointed at.' );
    }

    my $t = main::convert( docroot => $d, path => 'docs/page.md', brand => '../../etc' );
    ok( !$t->{ok}, 'a brand cannot be a path' )
        or diag( 'A brand name is joined to a directory. A caller choosing the '
            . 'location chooses which files are included in the output.' );
    like( $t->{error}, qr/unknown brand/, 'and the refusal names what is available' );

    my $b = main::convert( docroot => $d, path => 'docs/page.md', brand => 'house' );
    ok( $b->{ok}, 'while a brand that exists is accepted' ) or diag( $b->{error} // '' );
};

subtest 'the work is bounded, because there is no queue to put it in' => sub {
    like( $code, qr/\$TIMEOUT_SECONDS\s*=\s*\d+/, 'a conversion has a timeout' );
    like( $code, qr/alarm \$TIMEOUT_SECONDS/,     'and it is armed' )
        or diag('A timeout nothing arms is a comment.');
    like( $code, qr/kill 'TERM', \$pid/, 'and it kills the converter' );
    like( $code, qr/\$MAX_INPUT_BYTES/,  'and the input is size-capped' )
        or diag( 'This runs inside the request. Without a cap a large page is a '
            . 'denial of service against the manager.' );
};

done_testing();

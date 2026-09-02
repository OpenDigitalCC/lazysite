#!/usr/bin/perl
# SM732: the PDF render is reachable.
#
# SM706 built convert() - the composed-document refusal, the per-part may_read
# check, the cache - and shipped it with NO CALLER. t/unit/plugins/41 passed
# throughout: eleven sabotages of a function nothing invoked. Two field rounds
# reported the positive path "not proved" for environmental reasons, and the
# deferral hid the gap.
#
# This test is about REACH. 41 still owns the conversion behaviour; what is
# asserted here is that a surface exists, that it is gated, and that the plugin
# can be loaded in-process without executing itself - the property the wiring
# depends on and the one most likely to break silently.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $api  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/; <$fh>;
};

subtest 'the action exists and is dispatched' => sub {
    like( $api, qr/\$action eq 'page-pdf'/, 'the dispatcher has a page-pdf branch' );
    like( $api, qr/sub action_page_pdf/,    'and the action it calls' );
    like( $api, qr/action_page_pdf\(\s*\$params\{path\}/,
        'the page path is passed from the request' );
};

subtest 'it is gated, on both sides' => sub {
    like( $api, qr/'page-pdf'\s*=>\s*\[qw\(manage_content\)\]/,
        'the TOKEN gate requires manage_content' );
    like( $api, qr/'page-pdf' => 'manage_content'/,
        'and so does the cookie gate' );

    # The register the generated reference is built from must agree, or an
    # integrator is told to ask for the wrong grant.
    my $act = do {
        open my $fh, '<', "$root/lib/Lazysite/ControlApi/Actions.pm" or die $!;
        local $/; <$fh>;
    };
    like( $act, qr/'page-pdf'\s*=>\s*\{\s*caps\s*=>\s*\['manage_content'\]/,
        'the control-API register agrees' );
};

subtest 'the path never reaches a shell' => sub {
    my ($body) = $api =~ /(sub action_page_pdf \{.*?\n\})/s;
    ok( $body, 'the action body is extractable' ) or return;

    # plugin-action refuses arbitrary arguments on purpose - "nothing
    # request-controlled ever reaches the command line". This calls convert()
    # in process, so the path is a Perl argument and sees no shell at all. A
    # future edit that shells out would undo that quietly.
    # Comments stripped first: the assertion is about CODE. The first version
    # of this test failed on the backticks inside a comment explaining why the
    # plugin can be loaded safely - a false positive from prose.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $body;
    unlike( $code, qr/qx\(|system\(|`|open\s+my\s+\$\w+,\s*['"]-\|/,
        'the action runs no external command' );
    like( $body, qr/\$conv->\(/, 'it calls the converter in process' );
    like( $body, qr/may_read\s*=>\s*sub/,
        'and supplies the content ACL, which convert() asks for rather than reaching for' );
};

subtest 'the plugin can be loaded without executing itself' => sub {
    # `run(@ARGV) unless caller` guards the entry point, and `do` sets a caller
    # frame - so loading defines the subs and prints nothing. If that ever
    # stopped being true, the plugin would emit JSON into the middle of an HTTP
    # response, which is the kind of fault that looks like a corrupt download.
    my $plugin = "$root/plugins/pandoc.pl";
    ok( -f $plugin, 'the plugin is present' ) or return;

    # LIST-FORM open, so there is no shell command string at all - t/lint/40
    # refuses an array interpolated into one, and it was right to: the first
    # version of this built the command with backticks. The arguments are real
    # argv here rather than a local @ARGV override, which tests more: the guard
    # has to hold when the process genuinely was given arguments.
    my $code = 'do $ARGV[0]; print "LOADED_QUIET"';
    open my $ph, '-|', $^X, '-e', $code, $plugin, '--describe'
        or do { fail('could not run the loader'); return };
    my $out = do { local $/; <$ph> };
    close $ph;
    like( $out, qr/LOADED_QUIET/, 'the loader ran to completion' );
    unlike( $out, qr/\{.*"id"\s*:\s*"pandoc"/,
        'and the plugin did NOT print its descriptor - it was loaded, not run' );
};

done_testing();

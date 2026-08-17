#!/usr/bin/perl
# SM347, SM348, SM351, SM360, SM361 - five findings from the partner agent's
# four-surface pass, each small and each about a surface saying something that
# is not quite what is true.
#
# They are tested together because they are one release's worth of the same
# defect class, not because they share code:
#
#   SM347  two content tools reject a path four others accept, so the natural
#          create-then-read sequence fails on a page that is serving 200
#   SM348  the orientation document contradicts the tool it describes
#   SM351  a success report is true of the engine and not yet of the world
#   SM360  a listing says a file is private and cannot say why
#   SM361  a shipped starter page models the pattern the briefing forbids
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site repo_root);
use lib repo_root() . '/lib';

my $root = repo_root();

subtest 'SM348: the task list no longer contradicts the tool' => sub {
    require Lazysite::Capabilities;
    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Capabilities.pm" or die $!;
        local $/;
        <$fh>;
    };
    # CAPTURE PARENS. Without them this matched in list context and yielded 1,
    # so $task was "1", the `unlike` below passed against a string that could
    # not contain the phrase, and only the positive assertion noticed. A check
    # that can only confirm will confirm anything.
    my ($task) = $src =~ /(id => 'switch-layout'.*?\],\n    \})/s;
    ok( $task, 'the switch-layout task was found' ) or return;
    like( $task, qr/install_layout/,
        'and it really is the task text, not a match flag' );

    # Comments strip first: this file now EXPLAINS the old wording, and a check
    # that reads documentation as code fails hardest on code that documents
    # itself.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $task;

    unlike( $code, qr/installs AND activates/,
        'the step no longer claims install activates' )
        or diag( 'SM314 corrected the TOOL and left this. An agent following '
            . 'the documented sequence installs a layout, believes the site '
            . 'switched, and finds it unchanged.' );
    like( $code, qr/activate_layout/,
        'and there is a separate activation step, because it is two operations' );
};

subtest 'SM361: the starter page says why it is an exception' => sub {
    my $page = do {
        open my $fh, '<', "$root/starter/forgot.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $page, qr/<form\b/, 'it still has the hand-authored form' )
        or diag( 'The form is not the defect - it posts to the auth CGI, and '
            . 'native forms bind to content handlers which cannot '
            . 'authenticate.' );
    like( $page, qr/SYSTEM PAGE/i,
        'and it now says it is a system page' );
    like( $page, qr/create_form/,
        'and points at what ordinary content should use instead' )
        or diag( 'An agent reads the starter pages to learn the conventions. A '
            . 'rule contradicted without comment by a shipped example teaches '
            . 'the contradiction.' );

    my $mcp = do {
        open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $mcp, qr/never hand-written form HTML.*?for CONTENT/s,
        'the rule states its boundary where agents actually read it' );
};

subtest 'SM347: one path vocabulary' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    setup_test_site($docroot);
    make_path("$docroot/zz");
    open my $fh, '>', "$docroot/zz/probe.md" or die $!;
    print $fh "---\ntitle: Probe\n---\n\nBody.\n";
    close $fh;

    # The resolver, exercised directly: it is the whole of the fix and the two
    # tools are one line each.
    my $src = do {
        open my $s, '<', "$root/lazysite-mcp.pl" or die $!;
        local $/;
        <$s>;
    };
    my ($sub) = $src =~ /(sub _resolve_page_path \{.*?\n\}\n)/s;
    ok( $sub, 'the resolver was found' )                          or return;
    eval "package PathCheck; our \$DOCROOT = '$docroot'; $sub 1;" or die $@;

    is( PathCheck::_resolve_page_path('/zz/probe'), '/zz/probe.md',
        'a page addressed as it is SERVED resolves to how it is stored' )
        or diag( 'create_page takes a slug and the page serves at /zz/probe, so '
            . 'reading it back at that path is the natural next call - and it '
            . 'returned not-found with retryable:false for a page answering '
            . '200.' );
    is( PathCheck::_resolve_page_path('/zz/probe.md'), '/zz/probe.md',
        'and the stored form still works, unchanged' );
    is( PathCheck::_resolve_page_path('/zz/absent'), '/zz/absent',
        'a path that resolves to nothing comes back as it was asked for' )
        or diag( 'The error should name what the caller said, not something '
            . 'the engine invented on their behalf.' );

    # The conservative half: an existing exact path is never re-pointed.
    open my $g, '>', "$docroot/zz/thing" or die $!;
    print $g "raw\n";
    close $g;
    open my $h, '>', "$docroot/zz/thing.md" or die $!;
    print $h "markdown\n";
    close $h;
    is( PathCheck::_resolve_page_path('/zz/thing'), '/zz/thing',
        'a file that EXISTS at the exact path wins over a .md beside it' )
        or diag( 'Anything addressing a file directly must not change '
            . 'behaviour.' );
};

subtest 'SM360: a listing says WHY an entry is private' => sub {
    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Files.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /(sub _governing_acl_key \{.*?\n\}\n)/s;
    ok( $sub, 'the resolver was found' ) or return;
    eval "package AclCheck; $sub 1;"     or die $@;

    my $acls = { 'docs/private' => {}, 'docs' => {}, '/' => {} };

    is( AclCheck::_governing_acl_key( $acls, 'docs/private/x.md' ), 'docs/private',
        'the nearest rule wins - longest match, walking up' );
    is( AclCheck::_governing_acl_key( $acls, 'docs/open/y.md' ), 'docs',
        'and a folder rule governs a file with no rule of its own' )
        or diag( 'This is the case the listing could not answer: store:private '
            . 'beside read:null, with no way to tell "private because the '
            . 'folder is gated" from "private because of its own stale rule".' );
    is( AclCheck::_governing_acl_key( $acls, 'elsewhere/z.md' ), '/',
        'the site-wide rule governs what nothing else does' );

    is( AclCheck::_governing_acl_key( { 'docs' => {} }, 'elsewhere/z.md' ), undef,
        'and an ungoverned file claims nothing' )
        or diag( 'Reporting a rule that does not cover the file would be worse '
            . 'than reporting none.' );
};

subtest 'SM351: the success report says what it does not cover' => sub {
    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Files.pm" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/content_moved_note/,
        'a completed move carries a note of its own' )
        or diag( 'Not a warning: `warnings` means something went wrong, and a '
            . 'caller filtering on it would read this caveat as a failure. '
            . 't/unit/73 asserts a successful move carries no warnings, and it '
            . 'is right to.' );
    like( $src, qr/open_file_cache_valid/,
        'and it names the front end\'s cached descriptor' )
        or diag( 'content_moved:1 is true of the ENGINE and, for up to a '
            . 'minute, false about what a visitor gets. SM331 closed the '
            . 'caching question; this is the sentence.' );
    like( $src, qr/nothing needs changing on the front end/,
        'and says nothing is required of the front end' )
        or diag( 'The standing constraint: lazysite asks nothing of the proxy. '
            . 'A warning that reads as an instruction to go and configure '
            . 'nginx would breach it.' );
};

done_testing();

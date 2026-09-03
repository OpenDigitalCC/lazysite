#!/usr/bin/perl
# SM748: action_save itself refuses an unparseable page, so every caller
# inherits the refusal.
#
# The defect this closes was not subtle once measured: the same bytes through
# WebDAV answered 415, and through the manager's action=save answered
# {"ok":true} - and action=save is what /manager/edit actually posts to. The
# guard existed, in lazysite-mcp.pl, guarding one caller of a shared function.
#
# t/unit/manager/141 asserts the guard's LOCATION by walking the tree. This
# file asserts its BEHAVIOUR by calling action_save, because a guard in the
# right place that does not fire is the same defect wearing a better address.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
use TestHelper qw(repo_root);

my $root = repo_root();

# A docroot the module will accept, arranged the way the other Files.pm tests
# arrange one.
my $tmp = tempdir( CLEANUP => 1 );
mkdir "$tmp/lazysite";

require Lazysite::Manager::Files;
require Lazysite::Auth::Acl;

# The package globals the other Files.pm tests set. Without them the module
# runs on undef and emits uninitialized-value warnings - passing, but noisily,
# and a test that warns teaches readers to ignore warnings.
$Lazysite::Manager::Common::DOCROOT = $tmp;
$Lazysite::Manager::Files::DOCROOT  = $tmp;
$Lazysite::Manager::Files::LOCK_DIR = "$tmp/lazysite/locks";
$Lazysite::Auth::Acl::DOCROOT       = $tmp;
$Lazysite::Auth::Acl::token_auth    = 0;

my $unparseable = <<'PAGE';
---
title: g
---

unmatched [% END %]
PAGE

my $fine = <<'PAGE';
---
title: g
---

Hello [% auth_user %], this parses.
PAGE

subtest 'an unparseable body is refused, and nothing lands' => sub {
    my $r = Lazysite::Manager::Files::action_save( '/probe.md', 'tester',
        $unparseable, undef );

    ok( ref $r eq 'HASH', 'action_save returned a result' ) or return;
    is( $r->{ok}, 0, 'the save is REFUSED - this is the case that returned ok:true' );
    is( $r->{kind}, 'template-parse-refused', 'and it says which rule refused it' );
    like( $r->{error}, qr/does not parse/,
        'the message names the fault rather than saying only "no"' );

    ok( !-f "$tmp/probe.md",
        'and the page is NOT on disk - refused before the write, not after' );
};

# The two cases below are the ones that would catch an over-tight guard, which
# is the failure direction SM744 had just spent a day on. Both assert the save
# SUCCEEDS as well as not being refused by this rule, because "not refused by
# the parse guard" would also be satisfied by a save that failed for some other
# reason - and a green test that permits a broken save is how SM748 happened.

subtest 'a page that parses still saves' => sub {
    my $r = Lazysite::Manager::Files::action_save( '/ok.md', 'tester', $fine, undef );
    ok( ref $r eq 'HASH', 'action_save returned a result' ) or return;
    isnt( $r->{kind} // '', 'template-parse-refused',
        'an ordinary page using template variables is not caught by the guard' );
    ok( $r->{ok}, 'and it actually saves' )
        or diag( $r->{error} // 'no error field' );
};

subtest 'a non-markdown file is not template-checked' => sub {
    # The guard keys on .md. A .txt carrying the same bytes is not a page and
    # must not be refused for failing to be one.
    my $r = Lazysite::Manager::Files::action_save( '/notes.txt', 'tester',
        $unparseable, undef );
    ok( ref $r eq 'HASH', 'action_save returned a result' ) or return;
    isnt( $r->{kind} // '', 'template-parse-refused',
        'a .txt with the same body is not template-checked' );
    ok( $r->{ok}, 'and it saves - it is not a template' )
        or diag( $r->{error} // 'no error field' );
};

done_testing();

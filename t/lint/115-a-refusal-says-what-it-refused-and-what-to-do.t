#!/usr/bin/perl
# SM750: WHAT A REFUSAL MUST SAY. The inverse of t/lint/112 (what it must not).
#
# Four filings in one week - SM712, SM730, SM749, SM750 - were the same defect:
# a refusal that named a verdict and sent its reader to ask a person. The house
# rule was written each time and enforced by nothing, so each instance was found
# in the field. This file is the enforcement, in the shape a test can hold:
#
#   1. Every content-write rule (t/lint/114's table) answers in list context
#      with (error, audit_detail): the detail is exactly `kind: cause - remedy`
#      on one line, the error carries a remedy, and a NON-refusal is the empty
#      list - `return undef` there is a one-element list that reads as a refusal
#      with no error, which t/unit/mcp/05 caught the first time it was tried.
#   2. The choke point's own refusals carry `kind` and echo the caller's path;
#      bare verdicts ("File not found", "Path is blocked") are counted against
#      a ceiling that only goes DOWN, the SM728 pattern.
#   3. Every dispatcher that writes the audit trail prefers audit_detail, so a
#      refusal's cause and remedy reach the log and not only the caller.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

require Lazysite::Manager::Common;
require Lazysite::Manager::Nav;

my $t = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $doc = "$t/site/public_html";
mkdir $doc;
mkdir "$doc/lazysite";
$Lazysite::Manager::Common::DOCROOT = $doc;

# rule => [ triggering args, non-triggering args ]
my %CASES = (
    raw_html_page_refusal => [
        ["---\ntitle: x\napi: true\ncontent_type: text/html\n---\n<html>"],
        ["---\ntitle: x\n---\nHello"],
    ],
    page_parse_refusal => [
        [ 'p.md', "---\ntitle: X\n---\nunmatched [% END %]\n" ],
        [ 'p.md', "---\ntitle: X\n---\nHello [% auth_user %]\n" ],
    ],
    active_artifact_refusal => [
        [ 'lazysite/layouts/studio/themes/live/main.css',  'studio', 'live' ],
        [ 'lazysite/layouts/studio/themes/draft/main.css', 'studio', 'live' ],
    ],
);

my $DETAIL = qr/\A[a-z][a-z-]+: \S.* - \S.*\z/;

for my $rule ( sort keys %CASES ) {
    subtest "$rule: the shape of a refusal" => sub {
        my $fn = Lazysite::Manager::Common->can($rule) or return fail("no $rule");
        my ( $trigger, $pass ) = @{ $CASES{$rule} };

        my @r = $fn->(@$trigger);
        is( scalar @r, 2, 'list context: (error, audit_detail)' ) or return;
        my ( $err, $detail ) = @r;
        ok( length $err, 'error is present' );
        like( $detail, $DETAIL, "audit_detail is `kind: cause - remedy`: $detail" );
        unlike( $detail, qr/\n/, 'on one line' );
        cmp_ok( length $detail, '<=', 220, 'and short enough to scan' );
        my ($kind) = $detail =~ /\A([a-z-]+):/;
        like( $kind, qr/-refused\z|-here\z/, 'the kind names a class, as the choke point records it' );

        # The error carries a remedy: a verb telling the reader what to do.
        like( $err, qr/\b(?:instead|write it as|publish|author|copy|activate|append|set_nav|fix|put the value|use a|install)\b/i,
            'the error says what to do, not only what was refused' );

        my $scalar = $fn->(@$trigger);
        is( $scalar, $err, 'scalar context: the error alone, for the DAV stack' );

        my @none = $fn->(@$pass);
        is( scalar @none, 0, 'a non-refusal is the EMPTY list, not (undef)' )
            or diag('a `return undef` in a rule reads as a refusal with no error at the choke point');
        ok( !defined scalar $fn->(@$pass), 'and undef in scalar context' );
    };
}

subtest 'brief_write_refusal and nav_write_refusal have the shape too' => sub {
    # These two need a site to trigger; assert the source rather than run them.
    my $common  = slurp("$root/lib/Lazysite/Manager/Common.pm");
    my $nav     = slurp("$root/lib/Lazysite/Manager/Nav.pm");
    my ($brief) = $common =~ /(sub brief_write_refusal \{.*?\n\})/s;
    like( $brief, qr/_refusal\(/, 'brief_write_refusal returns through the builder' );
    unlike( $brief, qr/return undef/, 'and has no `return undef` (a one-element list)' );
    my ($navr) = $nav =~ /(sub nav_write_refusal \{.*?\n\})/s;
    like( $navr, qr/refusal_detail\(/, 'nav_write_refusal builds a detail' );
    like( $navr, qr/wantarray/,        'and answers both contexts' );
    unlike( $navr, qr/return undef/, 'with no `return undef`' );
};

subtest 'the choke point: kind, echoed path, and a ceiling on bare verdicts' => sub {
    my $files  = slurp("$root/lib/Lazysite/Manager/Files.pm");
    my $common = slurp("$root/lib/Lazysite/Manager/Common.pm");

    unlike( $files, qr/error => ["']Path is blocked/, 'no refusal says "Path is blocked" - the rule\'s reason is returned' );
    unlike( $common . $files, qr/error => ["']Invalid path["']/, 'no refusal says "Invalid path" without the path' );
    like( $common, qr/kind => 'invalid-path'/, 'validate_path refusals carry a kind' );

    # Bare verdicts: a literal error string of four words or fewer with no
    # interpolation. LOWER IS THE ONLY DIRECTION; a new one fails here.
    my @bare;
    while ( $files =~ /error\s*=>\s*(["'])((?:(?!\1).)*)\1/g ) {
        my $s = $2;
        next if $s =~ /\$/;

        # not `( () = split ... )`: a split assigned to an empty list is given an
        # implicit LIMIT of one, and every string counts as one word.
        my @w = split /\s+/, $s;
        push @bare, $s if @w <= 4;
    }
    my $ceiling = 11;
    cmp_ok( scalar @bare, '<=', $ceiling, "bare verdicts in Files.pm: " . scalar(@bare) . " <= ceiling $ceiling" )
        or diag( "a NEW refusal must echo the path and name the fix (_refused / _blocked). If you converted some, LOWER the ceiling. Bare now:\n  "
            . join( "\n  ", @bare ) );
    for my $helper (qw(_refused _blocked)) {
        like( $files, qr/^sub \Q$helper\E \{/m, "$helper exists for the next refusal to use" );
    }
};

subtest 'every dispatcher prefers audit_detail on the way to the trail' => sub {
    my $api = slurp("$root/lazysite-manager-api.pl");
    my $mcp = slurp("$root/lazysite-mcp.pl");
    my $dav = slurp("$root/lazysite-dav.pl");
    like( $api, qr/\$result->\{audit_detail\} \|\| \$result->\{kind\} \|\| \$result->\{error\}/,
        'control API: audit_detail, then kind, then error' );
    like( $mcp, qr/\$out->\{audit_detail\} \|\| \$out->\{kind\} \|\| \$out->\{error\}/,
        'MCP: the same order' );
    like( $mcp, qr/"invalid arguments: \$bad"/, 'MCP: an argument refusal names the argument in the trail' );
    like( $dav, qr/\$REFUSAL_DETAIL \/\/ "http \$code"/, 'WebDAV: a 415 refusal\'s detail reaches the trail' );
    like( $dav, qr/defined \$DENY_DETAIL \? \$DENY_DETAIL/, 'WebDAV: a 403 deny\'s detail reaches the trail' );
};

done_testing();

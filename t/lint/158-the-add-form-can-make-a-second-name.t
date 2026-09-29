#!/usr/bin/perl
# SM217: the Add form can make a domain a SECOND NAME for an existing site.
#
# The engine half shipped `domain-alias-add`, and the Domains list marks the
# result - but nothing on the page could invoke it, so the action was reachable
# only over the API. This pins the control that closes that, and three decisions
# a reader would otherwise have to rediscover from the engine.
#
# WHY IT IS AN OPTION AND NOT A BUTTON. A separate "Add alias" control would be a
# second door to the same room. The Add form already asks where this domain's
# content lives; "the same place as <existing domain>" is one more answer to that
# question, so it belongs in the picker that asks it.
#
# The three things that must not drift, each of which the ENGINE enforces and
# would therefore fail as a refusal rather than as a visible bug:
#
#   1. an alias sends NO content_root - domain_add_alias refuses one outright,
#      naming the refusal, rather than dropping it;
#   2. an alias never offers `seed` - the action forces seed => 0, because
#      seeding an alias writes a starter page into the canonical domain's own
#      content, and a checkbox that cannot do what it says is worse than none;
#   3. only domains with a NAMED content root are offerable - a rootless host
#      serves the default site, which is already the first option in the same
#      select. That is the same narrowing the row marker got (t/lint/155) and
#      for the same reason.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/domains.md';
open my $fh, '<:utf8', $page or die "$page: $!";
my $src = do { local $/; <$fh> };
close $fh;

# THE CANARY. Every assertion below is a match against this one file, so a file
# that failed to load, or that no longer holds the create sheet at all, must fail
# first rather than letting a string of `like`s pass on emptiness.
ok( $src =~ qr/function createDomain\s*\(/,
    'the page still holds the create form this test is about' )
    or BAIL_OUT('domains.md does not contain createDomain - nothing below is meaningful');

subtest 'THE CONTROL EXISTS, in the picker that already asks the question' => sub {
    ok( $src =~ qr/function aliasOptionsHtml\s*\(/, 'the alias choices are built' );
    ok( $src =~ qr/optgroup label="Share an existing site"/,
        'and offered as a group inside the content-folder picker' )
        or diag( 'A separate Add-alias button would be a second door to the same '
            . 'room; this belongs where the form already asks where content lives.' );
    # THE CALL, not merely the name. The first version of this asserted
    # /aliasOptionsHtml\(\)/, which the function's own DEFINITION satisfies - so
    # deleting the line that appends the options to the select changed nothing
    # the test could see, and the control would have vanished from the page with
    # every assertion still green. Sabotage found it; the pattern now requires
    # the options to reach the option string.
    ok( $src =~ qr/opts \+= aliasOptionsHtml\(\)/,
        'and the picker actually appends them to its options' )
        or diag( 'The builder can exist and never be called. Assert the call '
            . 'site, because that is the thing that puts the control on screen.' );
};

subtest 'AN ALIAS POSTS domain-alias-add, WITH alias_of AND NO content_root' => sub {
    ok( $src =~ qr/domain-alias-add/, 'the action is named' );
    ok( $src =~ qr/body\.alias_of\s*=/, 'alias_of is sent' );
    # The negative that matters: content_root and seed must be set only on the
    # NON-alias branch. domain_add_alias refuses a content_root outright, so
    # sending one turns an ordinary add into a refusal the operator did not ask
    # for - and it would look like the form being broken, not like a rule.
    my ($branch) = $src =~ /if \(aliasOf\) \{(.*?)\n  \}/s;
    ok( defined $branch, 'the alias branch is findable' ) or return;
    unlike( $branch, qr/content_root/,
        'the alias branch sends no content_root - the action refuses one' );
    unlike( $branch, qr/\bseed\b/,
        'and no seed - the action forces it off' );
};

subtest 'SEED IS HIDDEN FOR AN ALIAS, not merely ignored' => sub {
    # A checkbox that submits a value the engine discards is a control that lies
    # about what it does - the shape SM217's own engine half refused when it made
    # a dropped content_root into a named refusal.
    ok( $src =~ qr/contentRootValue\(\)\s*&&\s*!aliasOfValue\(\)/,
        'the seed option requires a folder AND not being an alias' )
        or diag( 'Seeding an alias would write a starter page into the canonical '
            . 'domain\'s content. The action forces seed => 0, so the box must '
            . 'not be offered.' );
};

subtest 'ONLY A DOMAIN WITH A NAMED FOLDER CAN BE SHARED' => sub {
    my ($fn) = $src =~ /function aliasOptionsHtml\s*\(\)\s*\{(.*?)\n\}/s;
    ok( defined $fn, 'the builder is findable' ) or return;
    like( $fn, qr/!r\.content_root/,
        'a domain with no content root is not offered' )
        or diag( 'A rootless host serves the default site, and "an alias of that" '
            . 'is already the first option in this select. Same narrowing as the '
            . 'row marker (t/lint/155), same reason.' );
};

subtest 'THE PREVIEW SAYS WHAT WILL HAPPEN, and does not promise a folder' => sub {
    my ($fn) = $src =~ /function syncContentRoot\s*\(\)\s*\{(.*?)\n\}/s;
    ok( defined $fn, 'the preview is findable' ) or return;
    like( $fn, qr/aliasOfValue\(\)/, 'the preview knows about the alias case' );
    # The ordinary path says "(created if it does not exist)". An alias creates
    # nothing, so that sentence must be on the other side of the branch.
    like( $fn, qr/no new folder/,
        'and an alias says plainly that no folder is created' )
        or diag( 'The ordinary path promises to create a folder. Saying that of '
            . 'an alias would describe an act that does not happen.' );
};

done_testing();

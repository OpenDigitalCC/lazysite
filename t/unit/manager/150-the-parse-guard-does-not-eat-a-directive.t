#!/usr/bin/perl
# SM744: the guard refused pages that parse.
#
# page_parse_issues strips Markdown code before parsing, so that a [% %] shown
# as an EXAMPLE is not read as a directive. The indented-code half of that rule
# fired on any four-space indent, with no idea whether it was inside a
# directive - so the continuation lines of a multi-line [%# comment %] were
# deleted, taking the closing %] with them. The truncated comment then swallowed
# whatever directive followed, and its END was reported as unexpected far below.
#
# Measured across 495 markdown files carrying [% in every reachable tree: seven
# refusals, of which FIVE were pages that parse - and all five were real site
# pages, four of them in a live application whose author could not save an edit
# to them. The two genuine failures were CHANGELOGs, which no one saves through
# the manager.
#
# The fixtures could not have caught it: every one of them wrote the code-block
# rule and the directive so that they never met. That is the same shape as
# SM738, whose composed-document fixtures used parts carrying no front matter.
# THE POINT OF THIS FILE IS THE CASE, not the mechanism - a directive that spans
# lines, indented, the way a person actually writes one.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(page_parse_issues);

my $refused = sub { return scalar( () = page_parse_issues( $_[0] ) ) };

subtest 'the reported case: a multi-line comment with indented continuation' =>
    sub {
    # Lifted from the shape found in the field, reduced to its bones. The
    # comment closes properly; only the guard's copy of it did not.
    my $body = <<'PAGE';
<div class="head"><h1>Catalogue</h1></div>
[%# Programmes grouped by category, each ordered by position. The internal
    tier is filtered out here so it never appears in the public catalogue.
    Tier, supervision and draft state show as badges. %]
[%- FOREACH cat IN categories -%]
<section><h2>[% cat.name %]</h2></section>
[%- END -%]
PAGE

    is( $refused->($body), 0,
        'a page whose directive spans indented lines is NOT refused' );

    # The proof that it is the same body, not a weaker one: it really does
    # parse. If this ever fails the fixture has drifted into an easier case.
    require Template;
    my $out = '';
    ok( Template->new( {} )->process( \$body, {}, \$out ),
        'and Template agrees - the page parses as written' );
    };

subtest 'an indented directive still is not code when a blank line is absent' =>
    sub {
    # The rule that replaced the old one: an indented line opens a Markdown
    # code block only where one may begin, which is after a blank line.
    my $body = <<'PAGE';
Intro text.
[%- IF user -%]
    [% user.name %]
[%- END -%]
PAGE
    is( $refused->($body), 0,
        'an indented directive body inside an IF is not mistaken for code' );
    };

subtest 'a real indented code block is still stripped' => sub {
    # The behaviour the old rule existed for, and which must survive: a TT
    # example indented after a blank line is documentation, not a directive,
    # and an unbalanced one must not refuse the page.
    my $body = <<'PAGE';
Here is how a loop is written:

    [% FOREACH item IN items %]
    [% END %]
    [% END %]

That trailing END is deliberate - it is prose about a mistake.
PAGE
    is( $refused->($body), 0,
        'an indented example, however unbalanced, does not refuse the page' );
};

subtest 'a fenced example is still stripped' => sub {
    my $body = <<'PAGE';
Here is how a loop is written:

```
[% FOREACH item IN items %]
[% END %]
[% END %]
```

Prose continues.
PAGE
    is( $refused->($body), 0, 'a fenced example does not refuse the page' );
};

subtest 'the guard still refuses what it was built to refuse' => sub {
    # SM708's reported case: a literal [% in page JavaScript, which really does
    # blank every substitution on the page. Fixing the false refusals must not
    # cost the true one.
    # The body t/unit/manager/140 already proves is refused, repeated here so
    # this file fails if the SM744 change ever costs the original refusal.
    #
    # A first draft of this subtest invented its own JavaScript instead, and it
    # was not refused - by the shipped guard either, so nothing had regressed;
    # the fixture was simply describing a case the guard never caught. Using
    # the one with a known verdict is the point.
    is( $refused->(
            "<script>u = /\\[%/.test(u) ? '' : u;</script>\n[% auth_user %]\n"
        ),
        1,
        'an unterminated literal [% in page script is still refused'
    );

    my $unbalanced = <<'PAGE';
[% FOREACH x IN xs %]
<p>[% x %]</p>
[% END %]
[% END %]
PAGE
    is( $refused->($unbalanced), 1,
        'and a genuinely unbalanced body is still refused' );
};

subtest 'a blank line does not close an indented block' => sub {
    # Markdown lets an indented code block resume across a blank line. If the
    # stripper closed the block there, the second half would be parsed as
    # template and the page refused for its own documentation.
    my $body = <<'PAGE';
An example in two parts:

    [% FOREACH item IN items %]

    [% END %]
    [% END %]

Prose continues.
PAGE
    is( $refused->($body), 0,
        'the indented block survives the blank line inside it' );
};

done_testing();

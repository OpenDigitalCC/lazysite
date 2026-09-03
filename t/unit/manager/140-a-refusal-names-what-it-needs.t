#!/usr/bin/perl
# SM712: a capability refusal names the capability, not only the action.
# SM708: a page whose template body does not parse is refused at WRITE time.
#
# Both are refusals that say more than "no", and both are here for the same
# reason: a refusal a caller cannot act on sends them to ask a person.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

subtest 'SM712: the control-API refusal names the capability' => sub {
    my $src = do {
        open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
        local $/; <$fh>;
    };
    like( $src, qr{needs \$names},
        'the refusal interpolates the capability names' );
    like( $src, qr/join\(\s*' or ',\s*\@\$d\s*\)/,
        'ANY-OF is rendered with "or", matching the arrayref semantics' );

    # The value it reads must be the same table the predicates are derived
    # from, or the message could name a capability the gate does not test.
    like( $src, qr/my \%need = map \{.*?\$need_caps\{\$_\}/s,
        '%need is derived from %need_caps, so the message and the gate agree' );
};

subtest 'SM708: the template-parse check refuses the real case only' => sub {
    # SM729: the check moved to Lazysite::Manager::Common, so that BOTH write
    # stacks reach it - it was private to lazysite-mcp.pl and WebDAV could not.
    # This test follows it there; t/unit/manager/141 owns the reach itself.
    require Lazysite::Manager::Common;
    ok( Lazysite::Manager::Common->can("page_parse_issues"),
        'the check is published by the shared module' ) or return;

    my $refused = sub {
        my @issues;
        push @issues, Lazysite::Manager::Common::page_parse_issues($_[0]);
        return scalar @issues;
    };

    # The reported case: a literal [% inside page JavaScript.
    ok( $refused->( "<script>u = /\\[%/.test(u) ? '' : u;</script>\n[% auth_user %]\n" ),
        'a literal [% in page script is refused' );
    ok( $refused->( "[% 1 +++ 2 %] and [% auth_user %]\n" ),
        'a malformed directive is refused' );

    # The false positives that would make this unshippable.
    ok( !$refused->( "Hello [% auth_user %] and [% auth_name %]\n" ),
        'a page using template variables normally is accepted' );
    ok( !$refused->( "See:\n\n```\n[% 1 +++ 2 %]\n```\n\n[% auth_user %]\n" ),
        'a FENCED code block documenting bad syntax is accepted' );
    ok( !$refused->( "See:\n\n    [% INCLUDE \"c/\${t}.tt\" data = s.\$t %]\n\n[% auth_user %]\n" ),
        'an INDENTED code block is accepted - ai-briefing-layouts ships one' );
    ok( !$refused->( "Write `[% 1 +++ 2 %]` inline.\n" ),
        'inline code is accepted' );
    ok( !$refused->( "Just prose, no template syntax.\n" ),
        'a page with no template syntax is not even checked' );

    # A missing INCLUDE is a FILE error, not a parse error. It may resolve at
    # render where INCLUDE_PATH is set, so refusing it here would be wrong.
    #
    # QUOTED, and that matters. An UNQUOTED `[% INCLUDE a-b.tt %]` is a genuine
    # parse error - a hyphen is not valid in a bare TT identifier - so it is
    # refused, correctly. The first version of this test used the unquoted form
    # and failed; the fixture was wrong, not the check. The quoted form is also
    # the one starter/docs/ai-briefing-layouts actually ships.
    ok( !$refused->( qq{[% INCLUDE "definitely-not-here.tt" %]\n} ),
        'a missing INCLUDE is NOT refused - only parse errors are' );
};

subtest 'SM708: the refusal happens BEFORE the write, not after it' => sub {
    my $src = do {
        open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
        local $/; <$fh>;
    };

    # The distinction this subtest exists for: _validate_page's issues are
    # ADVISORY - write_file calls action_save first and attaches them to the
    # result, so a page carrying an issue is already on disk. A parse failure
    # must not be reported that way, because the page renders every variable
    # literally and the author who can fix it is present at the write.
    # SM748 MOVED THE GUARD, and this subtest moved with it.
    #
    # It used to assert three inline guards in lazysite-mcp.pl, each sitting
    # above its own action_save. That was true, and it was the defect: guarding
    # the CALLER meant the control API - which calls the same action_save from
    # the same shared module - was never covered, so `action=save` accepted an
    # unparseable body for four releases while WebDAV refused it.
    #
    # The property is unchanged: the refusal happens BEFORE the write, not as
    # an advisory attached afterwards. Only its location changed, from three
    # callers to the one function they all go through. t/unit/manager/141 owns
    # the reach; what is asserted here is that MCP no longer carries a private
    # copy of a shared rule.
    unlike( $src, qr/sub _page_parse_refusal/,
        'MCP no longer defines a private parse guard' );
    unlike( $src, qr/_page_parse_refusal\(/,
        'and no longer calls one - action_save carries it' );

    # The advisory path is a different thing and stays: _validate_page reports
    # issues without refusing, which is right for a validator and wrong for a
    # write.
    like( $src, qr/page_parse_issues/,
        'the ADVISORY use survives, because a validator reports rather than refuses' );
};

done_testing();

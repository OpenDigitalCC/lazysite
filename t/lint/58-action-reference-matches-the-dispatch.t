#!/usr/bin/perl
# SM350: the published action reference must be what the dispatch chain does.
#
# WHY THIS IS THE WHOLE POINT. The filing asked for the reference to be GENERATED
# from the dispatch table rather than hand-written, and named three defects
# already caused by hand-maintained lists - t/lint/31's templates, t/lint/39's
# scripts, t/lint/41's packaging. There is no dispatch table to generate from:
# the control API is a 108-branch if/elsif chain, which SM237 met, worked around
# with a literal %KNOWN_ACTION, and said plainly deserves its own request.
#
# So Lazysite::ControlApi::Actions is a fourth hand-maintained list, and this is
# what stops it being the fourth defect. The table was EXTRACTED from the chain
# rather than typed; this re-extracts it and fails on any difference. A published
# reference that has drifted from the code is worse than none, because a caller
# trusts it.
#
# WHAT IT CANNOT SEE, stated so a green run is not read as more than it is. The
# extraction reads `$params{x}` and `$req->{x}` within each branch, plus the
# shared `$path`. A branch that hands the whole request to a helper which reads a
# parameter internally is invisible to both this and the declaration - so the
# reference is accurate about what it lists and does not claim to be exhaustive
# per action. Replacing the chain with a real table is what would close that, and
# it remains its own piece of work.
#
# SM944 S33a (ruled 2026-10-11): A BRANCH IS READ WITH ITS CALLEES. The
# request's parameters are Manager::Common's context now (%params, and the body
# memo behind _json_body), so a branch's body can move into a `dispatch_`
# handler in an area module and read them unchanged - and would leave this
# extraction behind. So each branch is read together with the `dispatch_`
# handlers it calls, and every sub they call, in the script or a Manager
# module, that itself reads %params or calls _json_body (and theirs in turn).
# A sub that is handed its arguments (`action_*( $req->{x} )`) is not one: the
# branch already shows what it reads, and its own `$req` is its argument, not
# the request. Nor is a pipeline gate a branch happens to call
# (`_confine_scope` reads `to` and `from` for the scope check of the actions
# declared `scoped`, which are not the branch's parameters).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root gate_caps);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};
my @lines = split /\n/, $src, -1;

# --- what the chain actually is ----------------------------------------------
# SM943: %KNOWN_ACTION is derived from the reference now, so comparing the two
# would compare it with itself. The chain's own `$action eq '...'` names are what
# the reference must match, as t/lint/22 extracts them.
my %chain = map { $_ => 1 } ( $src =~ /\$action\s+eq\s+'([a-z0-9_-]+)'/g );
my @known = sort keys %chain;
cmp_ok( scalar @known, '>=', 90, 'the dispatch chain was found and parsed' );

# SM662: read as DATA. The warning that stood here is worth keeping as
# history: parsing a predicate with /sub \{([^}]*)\}/ stopped at the closing
# brace of $_[0]->{manage_themes} and yielded an empty capability list - which
# looks exactly like a working extraction that found no capability required,
# the most dangerous shape a mistake can take in a security-adjacent reference,
# and it cost an hour. A declared list cannot fail that way, which is most of
# why the table was made declarative.
my %need = gate_caps($src);

my ( %branch, @cur, $depth );
for my $i ( 0 .. $#lines ) {
    if ( !@cur && $lines[$i] =~ /^(?:els)?if\s*\(/ ) {
        my $cond = $lines[$i];
        $cond .= $lines[ $i + 1 ] if $i < $#lines && $lines[$i] !~ /\)\s*\{/;
        my @names = $cond =~ /\$action eq '([^']+)'/g;
        if (@names) { @cur = @names; $depth = 0 }
    }
    next unless @cur;
    $depth += () = $lines[$i] =~ /\{/g;
    $depth -= () = $lines[$i] =~ /\}/g;
    $branch{$_} .= $lines[$i] . "\n" for @cur;
    @cur = () if $depth <= 0;
}

# SM944 S33a: the subs that read the request's parameters from the context.
sub code_of {
    my ($s) = @_;
    $s =~ s/^__(?:END|DATA)__\b.*//ms;
    $s =~ s/^=[a-zA-Z].*?^=cut\b[^\n]*//gms;
    $s =~ s/^\s*#.*$//gm;
    $s =~ s/(?<=[;{}),])\s*#.*$//gm;
    return $s;
}
my %SUB;
for my $file ( "$root/lazysite-manager-api.pl", sort glob "$root/lib/Lazysite/Manager/*.pm" ) {
    open my $fh, '<', $file or die "$file: $!";
    my $code = code_of( do { local $/; <$fh> } );
    while ( $code =~ /^sub\s+(\w+)\s*\{(?:([^\n]*)\}[ \t]*$|(.*?)^\})/msg ) {
        $SUB{$1} .= $2 // $3;
    }
}
my %READS_REQUEST = map { $_ => 1 }
    grep { $_ ne '_json_body' && $SUB{$_} =~ /\$params\{|\b_json_body\s*\(/ } keys %SUB;
ok( $READS_REQUEST{_missing_required}, 'the subs that read the request\'s parameters were found' );

# A branch, then the dispatch_ handlers it calls, and each sub they call
# (transitively) that reads them.
sub with_callees {
    my ($text) = @_;
    my ( %seen, @todo );
    my $out = $text;
    @todo = grep { /\Adispatch_\w+\z/ } $text =~ /\b(\w+)\s*\(/g;
    while ( defined( my $n = shift @todo ) ) {
        next if $seen{$n}++             || !defined $SUB{$n};
        next unless $n =~ /\Adispatch_/ || $READS_REQUEST{$n};
        $out .= "\n$SUB{$n}";
        push @todo, $SUB{$n} =~ /\b(\w+)\s*\(/g;
    }
    return $out;
}

# --- 1 and 2, removed in SM943 stage 3 ----------------------------------------
# Two subtests stood here, and neither could still fail on its own:
#
#   1. "the reference lists exactly the actions that exist" compared %ACTION's
#      names with the chain's. t/lint/22 makes the same comparison, action by
#      action, since stage 1 made %KNOWN_ACTION the declared set - so this was a
#      second copy of one check, and the copy went.
#   2. "and requires what the token gate requires" compared each entry's `caps`
#      with need_caps(). Both are read from %GATE by the same module - `caps` is
#      derived from it at load and need_caps() reads `caps` back - so the two
#      sides were one value and the comparison was true by construction. What
#      the gate decides is pinned by t/lint/98's ledger and spot checks.

# --- 3. the same parameters --------------------------------------------------
subtest 'and names the parameters each branch reads' => sub {
    for my $a (@known) {
        next unless defined $branch{$a};
        my $b    = with_callees( $branch{$a} );
        my $spec = $Lazysite::ControlApi::Actions::ACTION{$a} or next;

        # SM605: COLLECTED AS SETS, because a name may be read more than once
        # from the SAME source. This built `query_or_body` from "have I seen
        # this name before", so a parameter read twice out of the body - which
        # is what a branch does when it tests a value and then passes it -
        # was reported as also accepted from the query string. The reference
        # would then have published a second source that does not exist, which
        # is precisely the drift this lint is here to prevent.
        my ( %from_query, %from_body );
        $from_query{$_} = 1 for $b =~ /\$params\{(\w+)\}/g;
        $from_body{$_}  = 1 for $b =~ /\$(?:req|in|payload)->\{(\w+)\}/g;

        my %want;
        for my $n ( keys %from_query, keys %from_body ) {
            $want{$n}
                = ( $from_query{$n} && $from_body{$n} ) ? 'query_or_body'
                : $from_query{$n}                       ? 'query'
                :                                         'body';
        }
        $want{path} //= 'query' if $b =~ /\$path\b/;

        my %got = map { $_->{name} => $_->{in} } @{ $spec->{params} };
        is_deeply( \%got, \%want, "$a: parameters and their source" )
            or diag( 'Regenerate rather than edit by hand - the chain is the '
                . 'authority and this table is extracted from it.' );
    }
};

# --- 4. the reference is reachable without holding anything ------------------
subtest 'introspection, like the map it accompanies' => sub {
    # An agent needs the reference BEFORE it knows what it may call, so gating
    # it behind a capability would put the answer behind the question.
    like( $src, qr/%introspection\s*\n?\s*=\s*\([^)]*'actions-list'\s*=>\s*1/s,
        'actions-list is in the introspection set' );
    # Read as DATA, not as source text: SM662 turned the gate into a table, so
    # `sub { 1 }` is no longer written anywhere and a regex for it asserted the
    # shape of the old code rather than the openness of the action.
    ok( exists $need{'actions-list'} && !keys %{ $need{'actions-list'} },
        'and needs no capability' )
        or diag( 'An agent needs the reference before it knows what it may '
            . 'call. A capability here puts the answer behind the question.' );
};

# --- 5. what it hands back is subset by grant --------------------------------
subtest 'and it is subset by grant, not a menu of refusals' => sub {
    my $none  = Lazysite::ControlApi::Actions::actions_for( {}, cookie => 0 );
    my @names = map { $_->{action} } @$none;
    # SM781: connector-call joins the three - it is served to every
    # authenticated caller (gate 'ALWAYS') and the CONNECTOR decides, by its
    # callers groups, so a capless account in a named group may call it.
    #
    # SM778: and display-names, for a different reason worth stating rather
    # than assuming. It takes no capability because it DISCLOSES NOTHING A
    # CALLER DOES NOT ALREADY HAVE: it answers only for the logins it is
    # given, one at a time, and it is not a listing - a caller that does not
    # already hold a login learns nothing by asking about it. That is the
    # whole justification, so it is also the thing that would have to be
    # re-argued if the action ever grew a "list them all" mode. This list is
    # short deliberately; adding to it is a decision, not a detail.
    #
    # SM943 ruling 2 (2026-10-09): and nav-read - the nav is public, so its
    # structured read needs no capability, and it reads only the caller's own
    # domains (SM976).
    is_deeply( [ sort @names ],
        [ 'actions-list', 'connector-call', 'describe-capabilities', 'display-names', 'nav-read', 'whoami' ],
        'a capless token sees the introspection actions, connector-call, display-names and nav-read' )
        or diag( 'Listing everything would be a list of things to try and be '
            . 'refused - and the refusals then read as defects.' );

    my $themes = Lazysite::ControlApi::Actions::actions_for(
        { manage_themes => 1 }, cookie => 0 );
    ok( ( grep { $_->{action} eq 'theme-activate' } @$themes ),
        'manage_themes reaches theme-activate' );
    ok( !( grep { $_->{action} eq 'domain-add' } @$themes ),
        'and not domain-add' );

    my $cookie = Lazysite::ControlApi::Actions::actions_for( {}, cookie => 1 );
    ok( ( grep { $_->{cookie_only} } @$cookie ),
        'a cookie session sees the cookie-only actions' );
    is( scalar( grep { $_->{cookie_only} } @$none ), 0,
        'and a token does not' );
};

done_testing();

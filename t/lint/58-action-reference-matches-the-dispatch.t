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
my ($known_src) = $src =~ /my %KNOWN_ACTION = map \{ \$_ => 1 \} qw\(\s*(.*?)\s*\);/s;
my @known       = sort split /\s+/, $known_src;

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

# --- 1. the same set ---------------------------------------------------------
subtest 'the reference lists exactly the actions that exist' => sub {
    my @declared = sort keys %Lazysite::ControlApi::Actions::ACTION;
    is_deeply( \@declared, \@known,
        scalar(@known) . ' actions, no more and no fewer' )
        or diag( 'A published reference naming an action that does not exist '
            . 'sends a caller after nothing; one missing an action hides it.' );
};

# --- 2. the same capabilities ------------------------------------------------
subtest 'and requires what the token gate requires' => sub {
    for my $a (@known) {
        my $spec = $Lazysite::ControlApi::Actions::ACTION{$a} or next;
        if ( exists $need{$a} ) {
            # SM662: gate_caps hands back a SET per action, so the comparison
            # is against its keys. The old array shape died here as an
            # "Not an ARRAY reference", which took the whole file with it.
            is_deeply( [ sort @{ $spec->{caps} // [] } ],
                [ sort keys %{ $need{$a} } ],
                "$a: capabilities match the token gate" );
        }
        else {
            # The state a caller cannot discover any other way, and the reason
            # SM237 needed %KNOWN_ACTION: without it the token gate could not
            # tell "exists, but cookie-only" from "no such action".
            is( $spec->{caps}, undef, "$a: cookie-only, and declared so" );
        }
    }
};

# --- 3. the same parameters --------------------------------------------------
subtest 'and names the parameters each branch reads' => sub {
    for my $a (@known) {
        my $b = $branch{$a};
        next unless defined $b;
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
    is_deeply( [ sort @names ], [ 'actions-list', 'describe-capabilities', 'whoami' ],
        'a capless token sees only the three introspection actions' )
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

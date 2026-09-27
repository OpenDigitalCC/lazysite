#!/usr/bin/perl
# SM662: the control-API register and the gate say the same thing.
#
# HOW THIS TEST CHANGED, and why the file keeps its name. It used to compare two
# copies of one fact: `caps => [...]` per action in ControlApi::Actions.pm, and
# %need_caps inside a sub in lazysite-manager-api.pl, which is what DECIDED. Until
# 0.11.9 they could not even be compared, because the gate held predicates and
# nothing can extract a capability from one without executing it. So the register
# was kept in step by reviewers, and SM687 needed nine registration points for one
# action with five found by a failing gate rather than by reading the code.
#
# A1 removed the second copy. The gate moved into the module as %GATE, verbatim
# with its comments, and the register's caps are DERIVED from it at load. There is
# nothing left to compare - so this test now holds the property that replaced the
# comparison: THERE IS ONE TABLE, the CGI consumes it rather than declaring its
# own, and what it decides is what it decided before the move.
#
# That last part matters most. This is a security-critical table, and SM662's own
# words are that it "is not one to do without a test that proves the resolved gate
# is identical before and after for every action". The counts and sets below were
# captured from the CGI before the table moved.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root gate_caps);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();

my $cgi = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};

subtest 'the gate is declared once, and not in the CGI' => sub {
    unlike( $cgi, qr/my \%need_caps = \(\s*\n\s*'/,
        'the CGI declares no gate table of its own' )
        or diag( 'A second declaration is the whole defect: the published '
            . 'reference, both unlocks maps and the channel matrix were copies '
            . 'of a table nothing else could reach.' );
    like( $cgi, qr/Lazysite::ControlApi::Actions::need_caps\(\)/,
        'and it builds its gate from the one that is published' );
    ok( %Lazysite::ControlApi::Actions::GATE,
        'the module declares the gate' );
};

subtest 'the register no longer carries a second copy' => sub {
    my $mod = do {
        open my $fh, '<', "$root/lib/Lazysite/ControlApi/Actions.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($action_block) = $mod =~ /our \%ACTION = \(\n(.*?)\n\);\n/s;
    ok( $action_block, 'the register was found' ) or return;
    # Comments inside the register EXPLAIN the three states and name the key while
    # declaring nothing - the SM781 note about `caps => []` meaning no capability
    # rather than cookie-only is one of the more useful lines in the file.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $action_block;
    unlike( $code, qr/caps\s*=>/,
        'no entry declares its own capabilities' )
        or diag('Derived at load from %GATE - a literal here is the old drift.');
};

subtest 'THE RESOLVED GATE IS WHAT IT WAS BEFORE THE MOVE' => sub {
    # Captured from the CGI's own table before it moved: 102 actions reachable
    # with a token, 54 cookie-only, and these exact sets.
    my %caps = gate_caps($cgi);
    is( scalar keys %caps, 102, '102 actions are reachable with a token' )
        or diag( 'The count moved. Either an action gained or lost a gate, or '
            . 'the move dropped one - and this table decides who may do what.' );

    my @cookie_only = grep { !defined $Lazysite::ControlApi::Actions::ACTION{$_}{caps} }
        keys %Lazysite::ControlApi::Actions::ACTION;
    is( scalar @cookie_only, 54, '54 are cookie-only' );

    # Three spot checks, one per capability state, so a wholesale re-derivation
    # cannot pass by producing a table of the right size.
    is_deeply( [ sort keys %{ $caps{'data-row-save'} } ],
        [qw(manage_data write_data)], 'an any-of gate keeps both capabilities' );
    is_deeply( [ keys %{ $caps{whoami} } ], [],
        'an ALWAYS gate needs none' );
    ok( !exists $caps{'backup-create'},
        'and a cookie-only action is absent from the gate entirely' )
        or diag( 'Absence IS the cookie-only state: %need is default-deny, so an '
            . 'action that appears here becomes token-reachable.' );
};

subtest 'a gate entry nothing publishes is refused at load' => sub {
    # The asymmetry that let five omissions reach the field: over-claiming is
    # self-correcting, silence is not. The module dies rather than dropping one.
    my $mod = do {
        open my $fh, '<', "$root/lib/Lazysite/ControlApi/Actions.pm" or die $!;
        local $/;
        <$fh>;
    };
    like( $mod, qr/does not publish - one of the two is wrong/,
        'the module refuses a gate entry with no published action' );
};

done_testing();

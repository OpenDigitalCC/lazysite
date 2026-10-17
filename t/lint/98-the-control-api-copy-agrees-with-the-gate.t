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
    #
    # The number is a LEDGER, not a constant: every change to it is an action
    # gaining or losing a gate, which is a decision, and the line below is where
    # it gets written down. Raise it only with the action named and the reason
    # given - a bump to make the suite green is the drift this test exists to
    # catch.
    #   106 / 52, SM924 (0.15.2): form-submission-delete and
    #        form-submissions-delete-bulk, gated delete_submissions - a capability
    #        of their own, OFF BY DEFAULT, so no existing account gains them. They
    #        were cookie-only under SM214, and that reasoning now sets the default
    #        rather than closing the door: a partner that could read every
    #        submission could delete none, so an agent's own test rows could only be
    #        cleared by a person. Both numbers move, because this is the first
    #        change that takes actions OUT of the cookie-only set.
    #   104, SM217 (0.15.1): domain-alias-add, gated manage_domains, the same
    #        capability domain-add needs - it IS a domain-add that reads the
    #        shared content root instead of being told it.
    #   103, SM905 U5 (0.15.1): form-uploads-save, gated manage_forms, the same
    #        capability its only writer form-targets-save already needed.
    #   107, SM938 D4 (0.15.2): form-notify-save, gated manage_forms, the same
    #        capability as form-uploads-save, which writes the same file.
    #   108, SM938 D5 (0.15.2): form-submission, gated read_submissions - one
    #        row of what form-submissions reads.
    #   110, SM1050: groups-list and group-set, gated manage_users (ruled
    #        2026-10-12, "Yes, within the delegation limit").
    #   111, SM1053: accounts-import-stage, gated manage_users; its review and
    #        apply (list, plan, apply) are cookie-only, which makes 56 of those.
    #   115, SM747 CU: odoo-status, odoo-calls, odoo-secret-set, odoo-secret-clear,
    #        gated manage_connectors as the connector's own four are.
    my %caps = gate_caps($cgi);
    #   118, SM747 E: odoo-bindings, odoo-run, odoo-confirm, gate ALWAYS as
    #        connector-call is - the BINDING decides, by its modes, callers and caps.
    #   119, SM1072: notify-outbox-list, gated manage_notifications - the
    #        notification outbox, read only; it shows recipients.
    #   120, n571 (SM1053): accounts-import-remove, gated manage_users as staging
    #        is - the account that staged an import removes it, or the operator.
    #   121, SM1107: notify-outbox-retry, gated manage_notifications as the list beside it
    #        is - it ends the backoff of what the outbox holds; the job still sends.
    #   122, SM1138 (slice A of SM1134): address-lists, gated manage_users as groups-list is -
    #        the named address lists, read only. Their writers are the operator's and cookie-only.
    is( scalar keys %caps, 122, '122 actions are reachable with a token' )
        or diag( 'The count moved. Either an action gained or lost a gate, or '
            . 'the move dropped one - and this table decides who may do what.' );

    my @cookie_only = grep { !defined $Lazysite::ControlApi::Actions::ACTION{$_}{caps} }
        keys %Lazysite::ControlApi::Actions::ACTION;
    #   53 cookie-only, SM858 (0.15.3): form-submission-approve - it creates an
    #        account, and SM268 keeps minting credentials a human act. The token
    #        count does not move: no gate was added.
    #   61 cookie-only, SM1043: me, me-password, me-sessions, me-session-revoke,
    #        me-sign-out-everywhere - self actions, a person's own account,
    #        never a token's. No gate was added.
    #   63 cookie-only, SM1034 1b: me-notices, me-notices-seen - the member's own bell. No gate was added.
    #   67 cookie-only, SM1042: me-2fa-enrol, -confirm, -disable, me-recovery-codes - a person's own second factor. No gate was added.
    #   69 cookie-only, SM1138: address-list-set, address-list-delete - the operator's, and the
    #        operator is never a token (SM991). The token count moves by the read alone.
    is( scalar @cookie_only, 69, '69 are cookie-only' );

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

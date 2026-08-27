#!/usr/bin/perl
# SM467: a manager group may CONFER api/mcp without HOLDING them.
#
# THE FIELD REPORT: on a new site, the setup-sysop admin could not add anyone
# to `agent-ai`. "You cannot add anyone to 'agent-ai': it grants 'api', which
# you may not confer."
#
# Every refusal in the chain was correct and together they left no path. The
# admin group is seeded with every capability EXCEPT api and mcp, because SM127
# makes manager groups interactive-only - a stolen manager session must not
# become a remote channel. Joining a group ACQUIRES its capabilities, so adding
# anyone to agent-ai counts as conferring `api`. And the account could not
# repair that itself, because `grantable` is operator-only to set - which is
# also right: a delegate that could widen its own grant authority has no
# ceiling at all.
#
# HOLDING AND CONFERRING ARE DIFFERENT QUESTIONS, and SM127 only bounds the
# first. `grantable` (SM195) is the mechanism for exactly that split. So the
# seed now carries grant authority for the two channels it deliberately
# withholds.
#
# THE CLAIM THE WHOLE CHANGE RESTS ON is the second subtest: grant authority
# must confer NO ability to use the channel. If `grantable: api` leaked into
# caps_for, this would have quietly handed every manager group the remote API
# access SM127 exists to deny - the exact opposite of the intent, on every site
# that runs setup-sysop.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

# STDERR IS CAPTURED DELIBERATELY. Every refusal in this tool is a `die`, so
# it goes to STDERR - and a helper that reads only STDOUT makes
# `unlike($out, qr/refused/)` pass whether or not the refusal happened. The
# first version of this file did exactly that, and its headline assertion was
# vacuous until the ceiling subtest exposed it.
sub run_cli {
    my ( $docroot, @args ) = @_;
    my @cmd = ( $^X, $script, '--docroot', $docroot, @args, '2>&1' );
    pop @cmd;
    my $cmd = join ' ', map { "\Q$_\E" } @cmd;
    my $out = `$cmd 2>&1`;
    return $out // '';
}

sub fresh_site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    # SM659: setup-sysop, and a NAME is required - there is no default account.
    # The password stays positional here so this fixture keeps testing the
    # capability question rather than the registration-link flow.
    run_cli( $d, 'setup-sysop', '--user', 'sjm', 'secretpw123' );
    return $d;
}

my $d = fresh_site();

# --- the reported case ------------------------------------------------------
subtest 'the manager can add an account to a group granting api' => sub {
    run_cli( $d, 'add', 'aiagent', 'pw12345678' );
    my $out = run_cli( $d, 'group-add', 'aiagent', 'agent-ai', 'sjm' );
    unlike( $out, qr/which you may not confer/,
        'no confer refusal for the bootstrap admin' )
        or diag( 'This is the field report verbatim: the only account on a '
            . 'fresh site could not set up an AI agent, and could not grant '
            . 'itself the authority to.' );
    open my $g, '<', "$d/lazysite/auth/groups" or die $!;
    my $groups = do { local $/; <$g> };
    close $g;
    like( $groups, qr/^agent-ai:.*\baiagent\b/m, 'and the membership is stored' );
};

# --- the claim everything rests on -----------------------------------------
subtest 'grant authority confers NO ability to use the channel (SM127)' => sub {
    my $gs = decode_json( do {
        open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
        local $/; <$fh>;
    } );
    my $admin = $gs->{sysops};    # SM659: renamed from sysops
    # SM630 widened this from exactly ['api','mcp'] to every capability. The
    # INTENT this subtest protects is unchanged and is now stronger: the admin
    # group may CONFER the channels it does not hold. Pinning the exact pair
    # would have pinned the old bootstrap decision rather than the property.
    my %grant = map { $_ => 1 } @{ $admin->{grantable} || [] };
    ok( $grant{api} && $grant{mcp},
        'the admin group carries grant authority for both channels' );
    cmp_ok( scalar keys %grant, '>=', 20,
        'and for every other capability too, so narrowing what it HOLDS never '
            . 'costs it the authority to delegate (SM630)' );
    ok( !$admin->{api}, 'and does NOT hold api' );
    ok( !$admin->{mcp}, 'and does NOT hold mcp' );

    # Through the resolver every consumer actually uses, not by reading the
    # file: caps_for is what the DAV endpoint, manager API and MCP consult.
    require Lazysite::Auth::Settings;
    our $AUTH_DIR;    # declared so the local() below is not a lone-name warning
    local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
    my $caps = Lazysite::Auth::Settings::caps_for('sjm');
    ok( !$caps->{api}, 'caps_for says the manager may NOT use api' )
        or diag( 'If grant authority leaked into caps_for, this change would '
            . 'hand every manager group the remote access SM127 denies.' );
    ok( !$caps->{mcp}, 'caps_for says the manager may NOT use mcp' );
    ok( $caps->{manage_users}, 'while the capabilities it does hold are intact' );
};

# --- the ceiling is still a ceiling ----------------------------------------
subtest 'a delegate outside the manager group still cannot confer' => sub {
    # A user-managers member holds manage_users and no grant authority, which
    # is the population the SM195 ceiling exists to bound. If seeding the
    # MANAGER group had widened this, the ceiling would be decorative.
    run_cli( $d, 'add', 'delegate', 'pw12345678' );
    run_cli( $d, 'group-add', 'delegate', 'user-managers' );
    run_cli( $d, 'add', 'target', 'pw12345678' );
    my $out = run_cli( $d, 'group-add', 'target', 'agent-ai', 'delegate' );
    like( $out, qr/which you may not confer/,
        'a manage_users delegate is still refused' );
    # Not a specific capability - _caps_granted_by_group reports whichever it
    # reaches first, so pinning one pins hash order rather than behaviour.
    #
    # SM645 CHANGED WHICH REMEDY COMES FIRST, and SM467's requirement is
    # unchanged: the refusal must name a remedy rather than stopping at the
    # capability, so the reader learns that grant authority exists. What moved
    # is that the remedy named first is one the reader can actually perform -
    # they are an app administrator who by policy has no shell, and this named
    # a shell command. t/unit/tools/41 already states that rule for
    # lazysite-check; this said the opposite.
    like( $out, qr/Groups page/,
        'the refusal names a remedy the reader can perform' )
        or diag( 'The old message named the capability and stopped, so the '
            . 'reader had no way to learn that grant authority exists. Naming '
            . 'a shell command instead is the same failure one step on.' );
    like( $out, qr/grantable-add \w+/,
        'and keeps the CLI as a stated fallback, using SM643\'s single verb' );
};

done_testing();

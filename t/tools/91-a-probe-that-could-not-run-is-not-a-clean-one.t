#!/usr/bin/perl
# SM912 P1, P2 and P3: the SM283 exposure probe can protect its own fixture
# again, a probe that could not run says so to a PROGRAM, and re-applying a rule
# that is already stored is not refused.
#
# WHAT HAPPENED. SM901 (0.15.0) began refusing a read list where every name is
# unknown to the store - right, for a rule somebody is authoring. The probe's read
# list is a sentinel chosen precisely because nobody has it, which is how it
# proves a protected file is withheld. So the probe stopped being able to
# establish its own precondition on any site that has accounts, and the fleet run
# of 2026-09-28 reported SKIPPED - while the summary line counted it in the clean
# column, because the only thing it reads is an exit code that had two states for
# three answers.
#
# THE GATE THIS FILE REPLACES DID NOT EXIST. Every probe fixture in the suite,
# t/integration/43 included, has an auth store that knows nobody - the one
# condition SM901 exempts - so the suite exercised the probe only where the check
# it now failed does nothing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir add_account);

my $root  = repo_root();
my $CHECK = "$root/tools/lazysite-check.pl";
my $CLI   = "$root/tools/lazysite-cli.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub a_site {
    my (%o) = @_;
    my $d = Cwd::realpath( site_tempdir() );
    make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/zz-content" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/zz-content/page.md",     "---\ntitle: P\n---\nbody\n" );
    add_account( $d, 'alice' ) if $o{with_account};
    return $d;
}

subtest 'P1: the probe protects its fixture on a site that HAS accounts' => sub {
    plan skip_all => "no $CHECK"                            unless -f $CHECK;
    plan skip_all => 'running as root - the probe declines' if $> == 0;

    # An unreachable URL, deliberately: the protect step happens BEFORE any
    # fetch, so this separates "could not establish the state" from "could not
    # measure it". Only the first is P1's business.
    my $d   = a_site( with_account => 1 );
    my $out = qx($^X \Q$CHECK\E --docroot \Q$d\E --check-acl http://127.0.0.1:1/ 2>&1);

    # THE ASSERTION IS POSITIVE, and the first version of it was not. It said
    # "the output does not mention refusing to protect", which any OTHER skip
    # reason satisfies - and a sabotage proved it: with the sentinel restored the
    # probe skipped for a different reason (the rule stored, no content moved)
    # and the test passed. What has to be true is that the probe ESTABLISHED its
    # state and went on to measure; there is only one way to say that.
    unlike( $out, qr/ACL PROBE SKIPPED/,
        'the probe establishes its own state and goes on to measure' )
        or diag( 'SM912 P1: the sentinel read list is the shape SM901 refuses, '
            . 'so from 0.15.0 the probe could not gate anything on a site with '
            . 'accounts - and it stops before the measurement either way.' );
    like( $out, qr/no usable answer/,
        'reaching the fetch, which is as far as it can get with no front end' )
        or diag( 'If it did not reach the fetch, it did not protect anything, '
            . 'whatever the reason given.' );
};

# THE NO-ACCOUNTS PATH IS NOT ASSERTED HERE, and the reason is worth writing down
# because I asserted it twice and was wrong twice.
#
# The fallback keeps a store that knows nobody on the pre-SM901 sentinel, and the
# coverage for that path is t/integration/43, which drives the real probe against
# two real front ends on a fixture with no accounts and expects it to PROTECT
# successfully. My own synthetic fixture would not move content for the sentinel -
# so a subtest asserting "a no-accounts site cannot be probed" passed here and was
# an artefact of the fixture, not a property of the engine: the integration test
# disproves it. A test that agrees with one docroot and not another is testing the
# docroot.

subtest 'P2: a probe that could not run exits 3, not 0' => sub {
    plan skip_all => "no $CLI"                              unless -f $CLI;
    plan skip_all => 'running as root - the probe declines' if $> == 0;

    # Addressed through the REGISTRY, which is what this verb accepts:
    # `probe --docroot D` is in the usage text and is not implemented - neither
    # here nor in `repair`, which has the same addressing - and that is a
    # separate finding rather than something to fix inside SM912.
    # LAZYSITE_REGISTRY_DIR exists for exactly this.
    my $d   = a_site( with_account => 1 );
    my $reg = Cwd::realpath( site_tempdir() ) . '/registry';
    make_path($reg);
    spit( "$reg/zz-probe", "docroot=$d\nurl=http://127.0.0.1:1/\n" );

    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    qx($^X \Q$CLI\E probe --domain zz-probe 2>&1);
    my $rc = $? >> 8;

    is( $rc, 3, 'exit 3: nothing exposed, and nothing measured either' )
        or diag( 'A skipped probe exited 0, so the fleet summary counted it in '
            . 'the clean column - the tool said SKIPPED in its own output the '
            . 'whole time, and could not say it to a program.' );
    isnt( $rc, 1, 'and NOT 1, which stays exposure only' )
        or diag( 'Any caller reading non-zero as "exposed" must not become '
            . 'wrong because a probe could not run.' );
};

subtest 'P2: the fleet summary counts the third state' => sub {
    my $sh = "$root/installers/hestia/lazysite-hestia-update-all.sh";
    plan skip_all => "no $sh" unless -f $sh;
    my $src = do { open my $fh, '<', $sh or die $!; local $/; <$fh> };

    like( $src, qr/_probe_none/, 'a third counter exists' );
    like( $src, qr/3\)\s*_probe_none/,
        'and exit 3 is what increments it' );
    like( $src, qr/could not run/,
        'and the summary line says so in words' )
        or diag( 'Three states in the exit code and two in the report is the '
            . 'same defect one layer up.' );
};

subtest 'P3: re-applying a stored rule is not refused for a stale name' => sub {
    require Lazysite::Manager::Files;
    require Lazysite::Manager::Common;
    require Lazysite::Auth::Acl;

    my $d = a_site( with_account => 1 );
    no warnings 'once';
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Auth::Acl::DOCROOT       = $d;
    $Lazysite::Auth::Acl::token_auth    = 0;
    local $Lazysite::Manager::Files::auth_user = 'alice';
    local $Lazysite::Auth::Acl::auth_user      = 'alice';

    # A rule naming somebody real, then that account goes away - which is what
    # happened on edge, where a rule named `agent-ai`.
    my $set = Lazysite::Manager::Files::action_acl_set( '/zz-content/', 'alice',
        ['alice'], undef, undef, undef );
    ok( $set->{ok}, 'a rule naming a real account is stored' ) or diag explain $set;

    open my $u, '>', "$d/lazysite/auth/users" or die $!;
    print {$u} "bob:x\n";    # alice is gone; the store still knows somebody
    close $u;

    my $again = Lazysite::Manager::Files::action_acl_set( '/zz-content/', 'alice',
        ['alice'], undef, undef, undef );
    ok( $again->{ok}, 'the same list, re-applied, is ACCEPTED' )
        or diag( 'Refusing this stopped --reapply-acls at the first stale name, '
            . 'and that command is the repair for content sitting unprotected.' );
    is_deeply( $again->{unknown}, ['alice'],
        'and the name is still reported as unknown' )
        or diag( 'Accepted is not the same as unremarked: SM901 carries the '
            . 'names, and that part is unchanged.' );

    # The ruling itself is untouched: a NEW list of unknowns is still refused.
    my $fresh = Lazysite::Manager::Files::action_acl_set( '/zz-content/page.md',
        'alice', ['never-existed'], undef, undef, undef );
    ok( !$fresh->{ok}, 'a NEW rule naming nobody who exists is still refused' );
    is( $fresh->{kind}, 'unknown-principals', 'with its own kind' );
};

done_testing();

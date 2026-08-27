#!/usr/bin/perl
# SM659: three principals shared two ambiguous words, and first run created a
# role account with a password to hand over.
#
# THE THREE, already distinct in code and collapsed in the words: a lazysite
# account with full capabilities, working through the UI/API and subject to the
# capability model; a Unix account running the CLI, exempt from that model by
# construction and logged as getpwuid($<); and no principal at all. `operator`
# was used for the first two, which are not different privilege LEVELS but
# different KINDS of principal.
#
# Settled: sysadmin is the host, sysop is the app and is a GROUP with named
# members, manager is the SURFACE and never a person.
#
# WHAT IS ASSERTED
#   a CLI actor is `system:<name>` - unresolvable BY CONSTRUCTION, because `:`
#     cannot appear in an account name, so it can never collide with one
#   setup-sysop REFUSES without a username - no role account by default
#   --link is the default, so nothing hands a password over
#   a second run makes a second sysop - no first-user special case
#   sysops is renamed on upgrade, carrying members, the manager flag
#     and grant authority
#   setup-manager is GONE - no alias
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

sub fresh {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    return $d;
}
# Each argument quoted individually: interpolating a list into a shell string
# re-splits on whitespace, which t/lint/40 refuses - and this file passes
# `--user sjm`, which is exactly the shape that would re-split wrongly.
sub run {
    my ( $d, @args ) = @_;
    my @cmd = ( $^X, $tool, '--docroot', $d, map { split ' ', $_ } @args );
    my $cmd = join ' ', map { quotemeta } @cmd;
    return qx($cmd 2>&1);
}
sub audit {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# --- the CLI actor ----------------------------------------------------------
{
    my $d = fresh();
    run( $d, 'add probe pw' );
    my $log = audit($d);
    like( $log, qr/\|\s*system:\w+\s*\|/,
        'a CLI action is recorded against system:<unix name>' );
    unlike( $log, qr/\|\s*[a-z]+\s*\|\s*user-add/,
        'and NOT a bare name - which would be indistinguishable from an '
            . 'account of that name, and would be LINKED as one by SM641' );

    # The property that makes it safe rather than merely conventional.
    my $bad = run( $d, 'add system:root pw' );
    like( $bad . run( $d, 'list' ), qr/systemroot|Invalid|not found|^(?!.*system:root)/ms,
        'and `:` cannot appear in an account name, so the two namespaces '
            . 'cannot meet' );
}

# --- setup-sysop ------------------------------------------------------------
{
    my $d  = fresh();
    my $no = run( $d, 'setup-sysop' );
    like( $no, qr/needs a username/,
        'setup-sysop refuses without a name - no role account by default' );
    like( $no, qr/Deploying with no accounts is fine/,
        'and says why refusing is safe: deploy and first user are separate' );

    my $ok = run( $d, 'setup-sysop --user sjm' );
    like( $ok, qr/single-use self-service link/,
        '--link is the DEFAULT, so no password is handed over' );
    unlike( $ok, qr/Password:/, 'and no password is printed' );

    open my $g, '<', "$d/lazysite/auth/groups" or die $!;
    my $groups = do { local $/; <$g> };
    close $g;
    like( $groups, qr/^sysops:.*\bsjm\b/m, 'the named account is in sysops' );

    # No first-user special case: the second account is the same shape.
    run( $d, 'setup-sysop --user chris' );
    open my $g2, '<', "$d/lazysite/auth/groups" or die $!;
    my $after = do { local $/; <$g2> };
    close $g2;
    like( $after, qr/^sysops:.*\bchris\b/m,
        'a second run makes a second sysop, rather than a special case' );

    unlike( $groups . $after, qr/\bmanager\b\s*$/m,
        'and no account called `manager` was ever created' );
}

# --- the old name is gone ---------------------------------------------------
{
    my $d = fresh();
    like( run( $d, 'setup-manager' ), qr/unknown command/,
        'setup-manager is GONE - no alias, because keeping it would teach the '
            . 'way this replaces' );
}

# --- the rename, on an upgraded site ----------------------------------------
{
    my $d = fresh();
    open my $s, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print {$s} '{"lazysite-admins":{"manager":1,"assignable":1,"seeded":1,'
        . '"label":"lazysite-admins","ui":1,"manage_users":1,"grantable":["ui"]}}';
    close $s;
    open my $m, '>', "$d/lazysite/auth/groups" or die $!;
    print {$m} "lazysite-admins: sjm, chris\n";
    close $m;
    run( $d, 'add sjm pw' );
    # THE TRIGGER IS AN ORDINARY MANAGER READ. _ensure_groups_seeded is what
    # runs the migration, and the manager's own reads call it - so a site
    # renames the next time somebody opens the Users page, not on a command
    # nobody runs twice. The CLI `groups` listing does not call it, which is
    # why the first version of this test saw nothing happen.
    my $api = qq({"action":"users-page","me":"sjm"});
    qx(echo \Q$api\E | $^X \Q$tool\E --api --docroot \Q$d\E 2>/dev/null);

    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
    my $gs = decode_json( do { local $/; <$fh> } );
    close $fh;
    ok( $gs->{sysops},              'sysops is renamed to sysops' );
    ok( !$gs->{'lazysite-admins'}, 'and the old name is gone' );
    is( $gs->{sysops}{manager}, 1,  'the manager flag moves with it' );
    cmp_ok( scalar @{ $gs->{sysops}{grantable} || [] }, '>', 1,
        'and grant authority survives (SM645 tops it up in the same pass)' );

    open my $g3, '<', "$d/lazysite/auth/groups" or die $!;
    my $members = do { local $/; <$g3> };
    close $g3;
    like( $members, qr/^sysops:.*sjm.*chris/m,
        'members move with it - the rename must not empty the group that '
            . 'identifies the administrators' );
}

done_testing();

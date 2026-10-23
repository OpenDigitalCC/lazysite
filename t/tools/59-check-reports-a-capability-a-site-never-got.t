#!/usr/bin/perl
# SM471: lazysite-check tells an operator that their manager group is missing
# a capability this release added.
#
# THE DEFECT: the manager group is seeded ONCE, with the capabilities that
# existed that day, and _ensure_manager_group_caps returns early when the group
# already has an entry - so no later release backfills. Every capability added
# since is absent from every site created before it, permanently, and the
# operator meets it as "you do not hold it" about something their role is
# designed to hold.
#
# SM645 since tops a manager group up with every capability it has no decision
# on, on the next use of the users tool (never at upgrade or sign-in: SM685,
# kept 2026-10-23). SM1272: so the check says it WILL be granted, and when,
# rather than asking for a decision - and the last subtest holds it to that.
#
# t/lint/81 pins the capability LIST the check carries. This asserts the check
# actually SAYS something - a correct list nobody reports is a check that
# passes while the operator stays stuck.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $check = "$root/tools/lazysite-check.pl";
my $users = "$root/tools/lazysite-users.pl";
plan skip_all => 'tools missing' unless -f $check && -f $users;

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    qx($^X \Q$users\E --docroot \Q$d\E setup-sysop --user sjm pw123456789-long-enough 2>/dev/null);
    return $d;
}
sub run_check { return qx($^X \Q$check\E --docroot \Q$_[0]\E 2>&1) }

sub drop_cap {
    my ( $d, $cap ) = @_;
    my $p = "$d/lazysite/auth/groups-settings.json";
    open my $fh, '<', $p or die $!;
    my $g = decode_json( do { local $/; <$fh> } );
    close $fh;
    delete $g->{'sysops'}{$cap};
    open my $out, '>', $p or die $!;
    print {$out} JSON::PP->new->canonical->encode($g);
    close $out;
    return;
}

subtest 'a site with every capability is reported clean' => sub {
    my $d   = site();
    my $out = run_check($d);
    like( $out, qr/manager group\(s\) carry a decision on every capability/,
        'the check says so' )
        or diag( 'Saying nothing when all is well would make the warning '
            . 'below indistinguishable from the check not running.' );
    unlike( $out, qr/have not decided/, 'and warns about nothing' );
};

subtest 'a site missing one is told, and told what to run' => sub {
    my $d = site();
    drop_cap( $d, 'manage_data' );    # as every pre-0.10.24 site is
    my $out = run_check($d);

    # SM1272: sysops is a manager group, so the SM645 top-up fills the gap on
    # the next use of the manager or the users tool. The check says that, and
    # stops asking for a decision the code has already taken.
    like( $out, qr/manager group\(s\) do not hold capabilities this release has yet/,
        'the check warns' )
        or diag( 'This is the whole finding: the operator otherwise meets it '
            . 'as a refusal about a capability their role should hold.' );
    like( $out, qr/sysops\/manage_data/, 'naming the group and the capability' );
    like( $out, qr/added after the group was seeded/,
        'and saying WHY it is absent' )
        or diag( 'Without that, an operator reads it as their configuration '
            . 'being wrong rather than as a seed that predates the feature.' );
    like( $out, qr/granted them on the next use of the manager or the users\s+tool/,
        'it says the group is granted it, and when' );
    like( $out, qr/Config page/, 'naming a use that does it' );
    unlike( $out, qr/have not decided on capabilities/,
        'it no longer calls it undecided' );
    unlike( $out, qr/grant or dismiss/, 'nor asks for a decision on the Groups page' );
    like( $out, qr/or now: \S.* repair --domain DOMAIN \(it runs the top-up\)/,
        'with repair as the simplest route (SM1273), spelled as this host runs the CLI' );
    like( $out, qr/group-reach sysops/,
        'and a command that grants it now as the shell fallback' );
};

subtest 'what the warning says will happen does happen (SM1272)' => sub {
    # The Config page's call (capability-holders) and the shell fallback each
    # top the group up, after which the check is clean. Either failing would
    # make the new wording a promise the code does not keep.
    for my $how ( 'config page', 'group-reach' ) {
        my $d = site();
        drop_cap( $d, 'manage_data' );
        if ( $how eq 'config page' ) {
            my $req = "$d/.req.json";
            open my $rf, '>', $req or die $!;
            print {$rf} '{"action":"capability-holders","actor":"sjm"}';
            close $rf;
            qx($^X \Q$users\E --docroot \Q$d\E --api < \Q$req\E 2>/dev/null);
        }
        else {
            qx($^X \Q$users\E --docroot \Q$d\E group-reach sysops 2>/dev/null);
        }
        my $out = run_check($d);
        like( $out, qr/manager group\(s\) carry a decision on every capability/,
            "$how: the group holds it afterwards, and the check is clean" );
    }
};

subtest 'the remote channels are not reported as missing' => sub {
    # SM127 keeps manager groups off api and mcp deliberately, so flagging them
    # would cry wolf on every site - and a warning that cries wolf trains an
    # operator to skip the one time it is real.
    my $d   = site();
    my $out = run_check($d);
    unlike( $out, qr{sysops/(?:api|mcp)},
        'their absence is the design, not drift' );
};

done_testing();

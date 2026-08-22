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
# REPORTED RATHER THAN REPAIRED, deliberately: the code cannot tell "this did
# not exist when the group was made" from "an operator turned it off on
# purpose", and granting on upgrade gets the second silently wrong. Re-granting
# something somebody removed is worse than telling them about something they
# are missing.
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
    qx($^X \Q$users\E --docroot \Q$d\E setup-manager pw123456789 2>/dev/null);
    return $d;
}
sub run_check { return qx($^X \Q$check\E --docroot \Q$_[0]\E 2>&1) }

sub drop_cap {
    my ( $d, $cap ) = @_;
    my $p = "$d/lazysite/auth/groups-settings.json";
    open my $fh, '<', $p or die $!;
    my $g = decode_json( do { local $/; <$fh> } );
    close $fh;
    delete $g->{'lazysite-admins'}{$cap};
    open my $out, '>', $p or die $!;
    print {$out} JSON::PP->new->canonical->encode($g);
    close $out;
    return;
}

subtest 'a site with every capability is reported clean' => sub {
    my $d   = site();
    my $out = run_check($d);
    like( $out, qr/manager group\(s\) carry every capability/,
        'the check says so' )
        or diag( 'Saying nothing when all is well would make the warning '
            . 'below indistinguishable from the check not running.' );
    unlike( $out, qr/lack capabilities/, 'and warns about nothing' );
};

subtest 'a site missing one is told, and told what to run' => sub {
    my $d = site();
    drop_cap( $d, 'manage_data' );    # as every pre-0.10.24 site is
    my $out = run_check($d);

    like( $out, qr/lack capabilities this release has/, 'the check warns' )
        or diag( 'This is the whole finding: the operator otherwise meets it '
            . 'as a refusal about a capability their role should hold.' );
    like( $out, qr/lazysite-admins\/manage_data/, 'naming the group and the capability' );
    like( $out, qr/added after the site was created/,
        'and saying WHY it is absent' )
        or diag( 'Without that, an operator reads it as their configuration '
            . 'being wrong rather than as a seed that predates the feature.' );
    like( $out, qr/group-set lazysite-admins manage_data on/,
        'with the exact command' );
};

subtest 'the remote channels are not reported as missing' => sub {
    # SM127 keeps manager groups off api and mcp deliberately, so flagging them
    # would cry wolf on every site - and a warning that cries wolf trains an
    # operator to skip the one time it is real.
    my $d   = site();
    my $out = run_check($d);
    unlike( $out, qr{lazysite-admins/(?:api|mcp)},
        'their absence is the design, not drift' );
};

done_testing();

#!/usr/bin/perl
# SM1023: `lazysite check` tells an absent auth store from one it cannot read
# and from one that does not decode.
#
# On sites.lazysite.io, right after the 0.15.4 upgrade, the check run as an
# account outside the site group said "no group grants manager access - the
# manager is unconfigured (every authenticated user would be a manager)". Run
# as root it said "manager bootstrapped". groups-settings.json was read with
# `|| {}`, so a store the check could not open read as one with no groups. The
# engine does not treat an unreadable store as unsecured (SM906), and the check
# must not report that it does. Absent is the unconfigured manager; unreadable
# is unknown, said as such; undecodable is a FAIL naming the file.
use strict;
use warnings;
use Test::More;
use File::Compare qw(compare);
use File::Path    qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

plan skip_all => 'root reads every file, so nothing is unreadable' if $> == 0;

my $script = repo_root() . '/tools/lazysite-check.pl';
ok( -f $script, 'the check tool is present' ) or BAIL_OUT('no check tool');

my $doc  = site_tempdir();
my $cgi  = "$doc/../cgi-bin";
my $auth = "$doc/lazysite/auth";
make_path( $auth, "$doc/lazysite/cache", $cgi );
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return;
}

sub check {
    my (@extra) = @_;
    return run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname, @extra );
}

# Locks a file for one run and opens it again, so the tempdir can be removed
# even when an assertion fails.
sub check_with_unreadable {
    my ( $path, @extra ) = @_;
    chmod 0000, $path or die "chmod $path: $!";
    my $out = check(@extra);
    chmod 0660, $path;
    return $out;
}

my $UNCONFIGURED = qr/no group grants manager access - the manager is unconfigured/;
my $GS           = "$auth/groups-settings.json";

put( "$doc/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
put( "$auth/groups",                "sysops: ann\n" );
put( "$auth/users",                 "ann:\$2b\$12\$abcdefghijklmnopqrstuuv\n" );

subtest 'an absent groups-settings.json is the unconfigured manager' => sub {
    my $out = check();
    like( $out, $UNCONFIGURED, 'the unconfigured-manager warning stands' ) or diag($out);
    unlike( $out, qr/cannot read groups-settings\.json/, 'and nothing claims it could not be read' );
};

put( $GS, qq({ "sysops": { "manager": 1, "ui": 1, "manage_users": 1 } }\n) );

subtest 'a readable store with a manager group and member is bootstrapped' => sub {
    my $out = check();
    like( $out, qr/manager bootstrapped \(group \+ user \+ password\)/, 'bootstrapped' ) or diag($out);
    unlike( $out, $UNCONFIGURED, 'not unconfigured' );
};

subtest 'an unreadable groups-settings.json is unknown, not unconfigured' => sub {
    my $out = check_with_unreadable($GS);
    unlike( $out, $UNCONFIGURED, 'no unconfigured-manager alarm' ) or diag($out);
    like( $out,
        qr/^\[ warn \] cannot read groups-settings\.json as \S+ \(Permission denied\) - which groups grant manager access is unknown, so the manager state is not reported/m,
        'a WARN names the store, the user and that the state is unknown' );
    like( $out, qr/-> run the check as root \(sudo lazysite check \.\.\.\) or as the site user/,
        'and how to run the check so it can read it' );
    unlike( $out, qr/manager bootstrapped/, 'and no bootstrap verdict either way' );
};

subtest 'an undecodable groups-settings.json FAILs, naming the file' => sub {
    put( $GS, qq({ "sysops": { "manager": 1, "ui": 1 \n) );
    my $out = check();
    like( $out,
        qr/\Qgroups-settings.json does not decode as a JSON object ($GS)\E - no group.s capabilities can be read from it/,
        'the FAIL names the file and what the engine makes of it' ) or diag($out);
    # SM1024: every reader now fails closed on it, and the FAIL says so.
    like( $out, qr/the manager refuses every signed-in request \(cannot tell\) until it is repaired/,
        'and says the manager refuses until it is repaired' );
    like( $out, qr/^\[[^\]]*FAIL[^\]]*\] groups-settings\.json does not decode/mi, 'at FAIL' );
    unlike( $out, $UNCONFIGURED, 'not reported as an unconfigured manager' );
    put( $GS, qq({ "sysops": { "manager": 1, "ui": 1, "manage_users": 1 } }\n) );
};

subtest 'an unreadable users or groups file leaves the manager account unknown' => sub {
    for my $f (qw(users groups)) {
        my $out = check_with_unreadable("$auth/$f");
        like( $out,
            qr/^\[ warn \] cannot read auth\/$f as \S+ - whether a manager group \(sysops\) has a member with a password is unknown/m,
            "auth/$f: named as unread, the answer unknown" ) or diag($out);
        unlike( $out, qr/no user in a manager group/, "auth/$f: no false 'no user' warning" );
        unlike( $out, qr/manager bootstrapped/,       "auth/$f: no bootstrap verdict" );
    }
};

subtest "an unreadable lazysite.conf leaves 'manager: enabled' unknown" => sub {
    my $out = check_with_unreadable("$doc/lazysite/lazysite.conf");
    like( $out, qr/^\[ warn \] cannot read lazysite\.conf as \S+ \(Permission denied\) - whether 'manager: enabled' is set is unknown/m,
        'unknown, said as such' ) or diag($out);
    unlike( $out, qr/'manager: enabled' is not set/, 'not reported as unset' );
};

my $ACLS = "$auth/acls.json";
subtest 'acls.json: absent, unreadable, undecodable' => sub {
    my $out = check();
    unlike( $out, qr/acls\.json/, 'absent: no rules, nothing said about the store' ) or diag($out);

    put( $ACLS, qq({ "docs/": { "read": ["\@sysops"] } }\n) );
    $out = check();
    like( $out, qr/\@sysops is granted by docs\/ \(read\)/, 'readable: the @group reach is reported' )
        or diag($out);

    $out = check_with_unreadable($ACLS);
    like( $out,
        qr/^\[ warn \] cannot read acls\.json as \S+ \(Permission denied\) - which paths are protected, and to whom, is unknown/m,
        'unreadable: unknown, said as such' ) or diag($out);
    unlike( $out, qr/access is granted per path; there is no site-wide rule/,
        'unreadable: no claim that there is no site-wide rule' );

    put( $ACLS, qq({ "docs/": { "read": ["\@sysops"] }\n) );
    $out = check();
    like( $out, qr/^\[[^\]]*FAIL[^\]]*\] acls\.json does not decode as a JSON object \(\Q$ACLS\E\) - the renderer refuses every page/mi,
        'undecodable: a FAIL naming the file' ) or diag($out);
};

subtest 'the ACL probe does not rewrite a store it could not decode' => sub {
    # Still undecodable from the subtest above. The probe returns before it
    # makes any request, so the URL is never fetched.
    my $before = "$doc/../acls.before";
    put( $before, do { open my $fh, '<', $ACLS or die $!; local $/; <$fh> } );
    my $out = check( '--check-acl', 'http://127.0.0.1:9' );
    like( $out, qr/ACL PROBE SKIPPED: acls\.json does not decode as a JSON object - the probe rewrites that store/,
        'the probe is skipped, saying why' ) or diag($out);
    is( compare( $ACLS, $before ), 0, 'and acls.json is byte-for-byte as it was' );
    my @litter = glob("$doc/lazysite-acl-probe-*");
    is( scalar @litter, 0, 'and no probe folder is left in the docroot' );

    $out = check_with_unreadable( $ACLS, '--check-acl', 'http://127.0.0.1:9' );
    like( $out, qr/ACL PROBE SKIPPED: acls\.json cannot be read as \S+ - the probe rewrites/,
        'nor one it could not read' ) or diag($out);
    is( compare( $ACLS, $before ), 0, 'which is left as it was' );
};

done_testing();

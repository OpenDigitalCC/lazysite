#!/usr/bin/perl
# SM906: an auth store that cannot be read is not an account that holds nothing.
#
# FROM A NEW 0.14.4 INSTALL. The CGI user could not read
# lazysite/auth/groups-settings.json - the one file that records what each group
# grants. caps_for therefore resolved to zero for everybody, and four separate
# sentences were wrong at once:
#
#   * the capability grid showed every cell empty
#   * group labels fell back to their technical names (cap-content, ch-ui)
#   * the backend cap-/ch- groups were offered as though assignable
#   * account-create refused: "Creator 'sjm' lacks create_sub_users permission"
#
# The last one sent the operator to look at grants that were already correct. The
# engine knew - cannot_read had logged "it exists and this process cannot open
# it" - and nothing carried that to the person reading the refusal.
#
# AND lazysite check WAS SILENT, which is the part that cost the day: it checks
# users, groups and acls.json in that directory for exactly this fault, and the
# file that decides capabilities was never on the list.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";
my $check = "$root/tools/lazysite-check.pl";
plan skip_all => 'running as root - file modes do not bind' if $> == 0;
plan skip_all => "no $users" unless -f $users;

sub spit { open my $h, '>', $_[0] or die "$_[0]: $!"; print {$h} $_[1]; close $h }

# The tool's JSON API reads its request on stdin - the shape every web surface
# uses, so what is asserted here is what the manager would receive.
# STDERR STAYS OUT OF IT. The whole point of this file is that the engine WARNS
# when a store will not open, so folding stderr into stdout - which the first
# version of this helper did - puts that warning inside the JSON and every decode
# fails. The answer is the response; the warning is asserted where it belongs.
sub api_call {
    my ( $docroot, $action ) = @_;
    open my $ph, '|-',
        "$^X \Q$users\E --api --docroot \Q$docroot\E > \Q$docroot\E/api.out 2>\Q$docroot\E/api.err"
        or die $!;
    print {$ph} qq({"action":"$action"});
    close $ph;
    open my $rh, '<', "$docroot/api.out" or die $!;
    my $out = do { local $/; <$rh> };
    close $rh;
    return $out;
}

# A fresh site with one sysop, created the way an operator creates one.
sub fresh_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    my $out = qx{$^X \Q$users\E --docroot \Q$d\E setup-sysop --user ada 2>&1};
    die "setup-sysop failed: $out" unless -f "$d/lazysite/auth/groups-settings.json";
    return $d;
}

subtest 'the sysop can create a sub-user when the store is readable' => sub {
    my $d  = fresh_site();
    my $o  = qx{$^X \Q$users\E --docroot \Q$d\E account-create bob --by ada 2>&1};
    my $rc = $? >> 8;
    is( $rc, 0, 'it succeeds' ) or diag $o;
    like( $o, qr/Sub-user 'bob' created/, 'and says so' );
};

subtest 'THE REFUSAL NAMES THE STORE, not the account' => sub {
    my $d   = fresh_site();
    my $gsf = "$d/lazysite/auth/groups-settings.json";
    chmod 0000, $gsf or plan skip_all => 'cannot chmod';

    my $o = qx{$^X \Q$users\E --docroot \Q$d\E account-create carol --by ada 2>&1};
    chmod 0644, $gsf;

    unlike( $o, qr/lacks create_sub_users/,
        'it does NOT say the account lacks the capability' )
        or diag( 'That sentence sent an operator to check grants that were '
            . "already correct.\n$o" );
    like( $o, qr/could not be read/i,    'it says the store could not be read' );
    like( $o, qr/permission fault/i,     'names it as a permission fault' );
    like( $o, qr/groups-settings\.json/, 'and names the file' );
    like( $o, qr/lazysite check/,        'and the command that reports and repairs it' );
};

subtest 'an ordinary refusal is unchanged' => sub {
    # The point is to tell the two apart, not to stop refusing. A creator who
    # genuinely holds nothing must still be told so, in the old words.
    my $d = fresh_site();
    my $o = qx{$^X \Q$users\E --docroot \Q$d\E add plain x 2>&1};
    $o = qx{$^X \Q$users\E --docroot \Q$d\E account-create dave --by plain 2>&1};
    like( $o, qr/lacks create_sub_users/,
        'an account that really holds nothing gets the plain refusal' )
        or diag( "If this changed, the fix has started blaming the store for "
            . "every refusal.\n$o" );
    unlike( $o, qr/could not be read/i,
        'and the store is not blamed when it read fine' );
};

subtest 'lazysite check reports the file this fault lives in' => sub {
    my $d   = fresh_site();
    my $gsf = "$d/lazysite/auth/groups-settings.json";
    chmod 0000, $gsf or plan skip_all => 'cannot chmod';

    my $o = qx{$^X \Q$check\E --docroot \Q$d\E 2>&1};
    chmod 0644, $gsf;

    like( $o, qr/groups-settings\.json/,
        'the check names groups-settings.json' )
        or diag( 'It checks users, groups and acls.json in the same directory '
            . "for exactly this fault. This one was never on the list.\n$o" );
};

subtest 'the manager group carries a descriptive label, not its own name' => sub {
    # The half that survives the permission fix. Every seeded group gets a real
    # label - "Website editor", "Capability: content" - and this one was written
    # as `label => $group`, so the group the site owner belongs to was the one
    # shown as a technical string in the picker and the membership list.
    my $d = fresh_site();
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $gs = JSON::PP::decode_json($raw);

    ok( ref $gs->{sysops} eq 'HASH', 'the manager group is recorded' ) or return;
    isnt( $gs->{sysops}{label}, 'sysops',
        'its label is not just its own name' )
        or diag('The picker shows the label, so this is what an operator reads.');
    is( $gs->{sysops}{label}, 'Site operator', 'it says what the group is' );
};

# --- the rest of the field report (SM906 remainder) --------------------------
#
# Two of the four reported symptoms survived the first pass, because two more
# answers are computed from the store without asking whether it could be read:
# whether a group may be given to a person, and what its name is. On the reported
# host both went the wrong way at once - the backend `cap-*` and `ch-*` groups
# were offered in the Add User picker, and every group appeared under its internal
# name - and neither is a fact the site had any basis for.

subtest 'an unreadable store does not make every group assignable' => sub {
    my $d   = fresh_site();
    my $gsf = "$d/lazysite/auth/groups-settings.json";

    # Readable first, as the control: the backend groups say they are not roles.
    my $ok = api_call( $d, 'group-settings-get' );
    require JSON::PP;
    my $r = eval { JSON::PP::decode_json($ok) } || {};
    ok( $r->{ok}, 'the view reads' ) or diag $ok;
    my ($backend) = grep { /^(?:cap|ch)-/ } sort keys %{ $r->{groups} || {} };
    ok( $backend, 'a backend group exists to test with' ) or return;
    ok( !$r->{groups}{$backend}{assignable},
        "$backend is not assignable while the store reads" );
    ok( !$r->{store_unreadable}, 'and the response does not claim the store is unreadable' );

    chmod 0000, $gsf or plan skip_all => 'cannot chmod';
    my $bad = api_call( $d, 'group-settings-get' );
    chmod 0644, $gsf;
    my $b = eval { JSON::PP::decode_json($bad) } || {};

    ok( $b->{store_unreadable},
        'the response SAYS the store could not be read' )
        or diag( 'Without this the page cannot tell an empty store from an '
            . "unreadable one, and it showed the second as the first.\n$bad" );
    my @assignable = grep { $b->{groups}{$_}{assignable} } keys %{ $b->{groups} || {} };
    is_deeply( \@assignable, [],
        'and no group is offered as a role while nothing can be read' )
        or diag( 'These were offered in the Add User picker on the reported '
            . 'host: ' . join( ', ', @assignable ) );
};

subtest 'the users page is told, so it need not guess from the names' => sub {
    my $d   = fresh_site();
    my $gsf = "$d/lazysite/auth/groups-settings.json";
    chmod 0000, $gsf or plan skip_all => 'cannot chmod';
    my $out = api_call( $d, 'users-page' );
    chmod 0644, $gsf;
    require JSON::PP;
    my $p = eval { JSON::PP::decode_json($out) } || {};
    ok( $p->{ok}, 'the page payload is still served' ) or diag $out;
    ok( $p->{store_unreadable},
        'and it carries the flag, on the ONE call the Users page makes' )
        or diag( "users-page is the only call that page makes, so a flag on "
            . "group-settings-get alone would never reach it.\n$out" );
};

done_testing();

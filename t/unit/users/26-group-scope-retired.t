#!/usr/bin/perl
# SM279: a group's dav_scope is retired, and the retirement is enforced at the
# writer rather than left to a comment.
#
# SM155 put the domain binding on the group. SM165 moved confinement to the
# domain-owned model in 0.7.26 (docs/SECURITY.md records it as an accepted
# decision), and from that day resolve_user_scopes read
# Lazysite::Auth::DomainAccess and never looked at the group field again. The
# CLI verb, the per-user redirect and partner-create's --scope all kept
# accepting it. An operator got a stored value, a success message, and no
# confinement on any channel.
#
# The four things this pins:
#   1. setting a group dav_scope is REFUSED, and the refusal names the model
#      that does work (a refusal that does not say what to do instead just
#      moves the operator's problem);
#   2. CLEARING one is still allowed, so a stale value can be tidied away
#      without hand-editing the store;
#   3. partner-create --scope is refused UP FRONT, before an account exists, so
#      a partner is never half-provisioned by a flag that would do nothing;
#   4. lazysite-check REPORTS a stale value as a FAIL - the only part of this
#      with live exposure, since a value set between 0.7.26 and now means a
#      member somebody believes is restricted and is not.
#
# Negative verification: with tools/lazysite-users.pl and tools/lazysite-check.pl
# stashed to their pre-fix state, assertions 1, 3 and 4 fail - the set succeeds
# and stores the value, partner-create accepts --scope, and check says nothing.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IPC::Open3;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/sites/clienta" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmanager: enabled\n";
close $cf;

# List-form, not qx: an EMPTY argument is meaningful here (it is how a stale
# setting is cleared) and a shell-interpolated '' simply disappears.
sub users {
    my @args = @_;
    my ( $r, $w );
    my $pid = IPC::Open3::open3( $w, $r, undef,
        $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, @args );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    return $out // '';
}

sub group_record {
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {};
    local $/;
    my $gs = eval { decode_json(<$fh>) } || {};
    close $fh;
    return $gs->{ $_[0] } || {};
}

# --- 1. setting one is refused, and the refusal is useful -------------------
{
    users( 'group-set', 'clientb', 'ui', '1' );    # bring the group into being
    my $out = users( 'group-set', 'clientb', 'dav_scope', 'sites/clienta' );

    like( $out, qr/retired/i, 'setting a group dav_scope is refused' );
    like( $out, qr/allowed_groups/,
        'and the refusal names the model that DOES confine' )
        or diag $out;

    my $rec = group_record('clientb');
    ok( !exists $rec->{dav_scope},
        'and nothing was stored - a refused write must not leave the value behind' )
        or diag explain $rec;

    # home_domain travelled with it and goes the same way.
    like( users( 'group-set', 'clientb', 'home_domain', 'clienta.com' ),
        qr/retired/i, 'home_domain is retired on the same terms' );
}

# --- 2. clearing a stale value is still allowed -----------------------------
{
    # Plant one the way an operator's store would carry it - written before the
    # retirement, so the tool must be able to remove it.
    my $f = "$d/lazysite/auth/groups-settings.json";
    open my $in, '<', $f or die $!;
    local $/;
    my $gs = decode_json(<$in>);
    close $in;
    $gs->{clientb}{dav_scope} = '/sites/clienta';
    open my $o, '>', $f or die $!;
    print {$o} JSON::PP->new->canonical->encode($gs);
    close $o;

    my $out = users( 'group-set', 'clientb', 'dav_scope', '' );
    like( $out, qr/[Cc]leared/, 'an empty value clears a stale setting' ) or diag $out;
    ok( !exists group_record('clientb')->{dav_scope}, 'and it is gone from the store' );

    # Capabilities on the same group must survive the clear - this removes one
    # key, not the group's grants.
    ok( group_record('clientb')->{ui}, 'the group keeps its capabilities' );
}

# --- 3. partner-create --scope refuses before creating anything -------------
{
    users( 'add', 'boss', 'pw-boss-123456' );
    users( 'group-set', 'bosses', 'create_sub_users', '1' );
    users( 'group-add', 'boss',   'bosses' );
    my $out = users( 'partner-create', 'agent1', '--by', 'boss', '--scope', 'sites/clienta' );
    like( $out, qr/retired/i, 'partner-create --scope is refused' ) or diag $out;

    my $list = users('list');
    unlike( $list, qr/\bagent1\b/,
        'and NO partner was created - the refusal is before the account, not '
            . 'after it' )
        or diag $list;

    # Without the flag the same command still works, so the retirement removed a
    # dead option rather than the ability to provision a partner.
    users( 'partner-create', 'agent2', '--by', 'boss' );
    like( users('list'), qr/\bagent2\b/, 'a partner without --scope is still created' );
}

# --- 4. lazysite-check reports a stale value --------------------------------
{
    my $f = "$d/lazysite/auth/groups-settings.json";
    open my $in, '<', $f or die $!;
    local $/;
    my $gs = decode_json(<$in>);
    close $in;
    $gs->{clientb}{dav_scope} = '/sites/clienta';
    open my $o, '>', $f or die $!;
    print {$o} JSON::PP->new->canonical->encode($gs);
    close $o;

    my $out = qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1);
    like( $out, qr/clientb.*retired dav_scope/,
        'check names the group carrying a retired scope' )
        or diag $out;
    like( $out, qr/FAIL/, 'and reports it as a FAIL, not a passing note' );

    # --fix must NOT silently clear it. There is no repair here: the operator has
    # to decide how that group should really be confined, and a tool that tidied
    # the evidence away would remove the only sign that somebody was relying on
    # it.
    qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E --fix 2>&1);
    ok( exists group_record('clientb')->{dav_scope},
        '--fix leaves it alone - there is no repair, only a decision' );
}

done_testing();

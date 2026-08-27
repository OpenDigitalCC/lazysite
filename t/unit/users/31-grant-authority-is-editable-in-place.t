#!/usr/bin/perl
# SM643: setting a group's grant authority replaced the whole list.
#
# `group-set GROUP grantable a,b,c` is a REPLACE - anything not named is
# removed - so adding one capability meant reading the current set, retyping it
# in full and appending. A read-modify-write performed by hand, against a live
# access-control list, usually while something is already broken. Mistype one
# existing entry and that authority disappears, with no warning, because a
# replace cannot tell an intentional removal from a forgotten one.
#
# WHAT IS ASSERTED
#   add leaves every capability it was not given alone
#   remove leaves every capability it was not given alone
#   removing something absent is a no-op, not an error - so a script can
#     converge without first asking what the state is
#   add/remove with nothing named is REFUSED, and names the way to clear
#   the replace form still replaces - the intent it expresses is legitimate
#   both new verbs are operator-only, like the one they supplement
#   the audit says what CHANGED, not just the resulting list
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# Read the STORE, not the reply: a verb that answers correctly and writes
# something else would pass every assertion made against its own return value.
sub stored {
    my ( $d, $g ) = @_;
    my $f = "$d/lazysite/auth/groups-settings.json";
    return [] unless -f $f;
    open my $fh, '<', $f or return [];
    local $/;
    my $j = eval { decode_json(<$fh>) } // {};
    close $fh;
    return $j->{$g}{grantable} || [];
}

sub set {
    my ( $d, $key, $val ) = @_;
    return uapi( $d,
        { action => 'group-settings-set', group => 'ops', key => $key, value => $val } );
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
uapi( $d, { action => 'group-create', group => 'ops' } );

set( $d, 'grantable', 'manage_content,manage_nav' );
is_deeply( stored( $d, 'ops' ), [qw(manage_content manage_nav)],
    'the baseline list is stored (test not vacuous)' );

# --- add ------------------------------------------------------------------
my $r = set( $d, 'grantable-add', 'manage_themes' );
ok( $r->{ok}, 'grantable-add succeeds' );
is_deeply( stored( $d, 'ops' ),
    [qw(manage_content manage_nav manage_themes)],
    'add keeps every capability it was not given - the whole point' );
is_deeply( $r->{added}, ['manage_themes'], 'it reports what it added' );

# Adding one already held changes nothing and is not an error.
$r = set( $d, 'grantable-add', 'manage_nav' );
ok( $r->{ok}, 'adding one already held is not an error' );
is_deeply( stored( $d, 'ops' ),
    [qw(manage_content manage_nav manage_themes)], 'and changes nothing' );
is_deeply( $r->{added}, [], 'it reports nothing added' );

# --- remove ---------------------------------------------------------------
$r = set( $d, 'grantable-remove', 'manage_content' );
ok( $r->{ok}, 'grantable-remove succeeds' );
is_deeply( stored( $d, 'ops' ), [qw(manage_nav manage_themes)],
    'remove keeps every capability it was not given' );
is_deeply( $r->{removed}, ['manage_content'], 'it reports what it removed' );

# Removing something absent converges rather than failing - a script should not
# have to ask what the state is before asking for the state it wants.
$r = set( $d, 'grantable-remove', 'audit' );
ok( $r->{ok}, 'removing a capability that is not there is a no-op, not an error' );
is_deeply( stored( $d, 'ops' ), [qw(manage_nav manage_themes)], 'and changes nothing' );

# --- the empty value ------------------------------------------------------
# `grantable ''` clears deliberately. `grantable-add ''` is a mistake, and
# silently clearing on it would be the sharpest possible version of the defect
# this closes.
for my $verb (qw(grantable-add grantable-remove)) {
    my $res = set( $d, $verb, '' );
    ok( !$res->{ok}, "$verb with nothing named is refused" );
    like( $res->{error} // '', qr/at least one capability/,
        "$verb says what it needed" );
    like( $res->{error} // '', qr/grantable ''/,
        "$verb names the way to clear the list, rather than only refusing" );
    is_deeply( stored( $d, 'ops' ), [qw(manage_nav manage_themes)],
        "$verb changed nothing" );
}

# --- an unknown capability is still refused -------------------------------
$r = set( $d, 'grantable-add', 'not_a_capability' );
ok( !$r->{ok}, 'an unknown capability is refused on the new verbs too' );
is_deeply( stored( $d, 'ops' ), [qw(manage_nav manage_themes)],
    'and nothing is written' );

# --- the replace form is unchanged ----------------------------------------
$r = set( $d, 'grantable', 'audit' );
is_deeply( stored( $d, 'ops' ), ['audit'],
    'grantable still means "exactly these" - the intent add/remove cannot express' );
set( $d, 'grantable', '' );
is_deeply( stored( $d, 'ops' ), [], 'and an empty value still clears it' );

# --- operator-only, like the verb they supplement -------------------------
# Grant authority is conferred from above and never self-assumed. A delegate
# that could widen its own grantable set would have no ceiling at all, so the
# new verbs must be no easier to reach than the old one.
set( $d, 'grantable', 'manage_nav' );
for my $verb (qw(grantable grantable-add grantable-remove)) {
    my $res = uapi( $d, { action => 'group-settings-set', group => 'ops',
            key => $verb, value => 'audit', actor => 'delegate' } );
    ok( !$res->{ok}, "$verb is refused to a delegate" );
    is( $res->{kind}, 'forbidden', "$verb refuses as forbidden" );
}
is_deeply( stored( $d, 'ops' ), ['manage_nav'],
    'and a delegate changed nothing through any of them' );

# --- the trail says what changed ------------------------------------------
# An operator reading the audit should see that one capability was added,
# without diffing two full lists against each other.
my $src = do { open my $fh, '<', $tool or die $!; local $/; <$fh> };
like( $src, qr/\$delta = '\(no change\)' unless length \$delta;/,
    'a change of nothing says so rather than printing an empty delta' );
like( $src, qr/cli_audit\( 'user-group-settings-set', \$group,\s*\n\s*"\$key \$delta/,
    'the audit entry carries the delta, not only the resulting list' );

done_testing();

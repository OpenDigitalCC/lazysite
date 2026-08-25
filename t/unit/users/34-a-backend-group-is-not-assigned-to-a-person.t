#!/usr/bin/perl
# SM576 part 3: roles are composed from groups, and a group says which kind it
# is.
#
# The nesting closure is NOT what is under test here - it already exists, is
# already the enforcement path, and SM268 02-5/02-6 already pinned it. What is
# new is one flag: `assignable` marks a group as something to give a PERSON, and
# an unflagged group is a backend group that exists only to aggregate other
# groups and capabilities.
#
# So the assertions are the two halves of that sentence. A person cannot be put
# in a backend group; a GROUP still can, because aggregation is what it is for.
# And the composition it enables is asserted through effective_groups - the
# resolver the gates use - rather than through direct membership, which is
# exactly the reading that made SM573's seven-vs-seventeen invisible.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map { quotemeta } $^X, $utool, '--docroot', $d, @args;
    return scalar `$cmd 2>&1`;
}

sub write_groups_settings {
    my ( $d, $ref ) = @_;
    open my $fh, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print {$fh} encode_json($ref);
    close $fh;
}

sub read_groups_settings {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
    local $/;
    return decode_json(<$fh>);
}

sub fresh {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Test\n";
    close $cf;
    return $d;
}

# --- the estate under test ---------------------------------------------------
# Two backend groups carrying the capabilities, one assignable role, and the
# role placed INSIDE each backend group - which is the direction SM121's closure
# runs: a group listing another group among its members lends its capabilities
# to that group's members.
my $d = fresh();
write_groups_settings( $d, {
        'admins' => { label => 'Admins', manager => 1, ui => 1, manage_users => 1,
            assignable => JSON::PP::true() },
        'content-write' => { label => 'Content write', manage_content => 1 },
        'data-read'     => { label => 'Data read',     manage_data    => 1 },
        'site-editor'   => { label => 'Site editor',   assignable => JSON::PP::true() },
} );
uapi( $d, { action => 'add', username => 'alice', password => 'x' } );

# --- 1. a person cannot be given a backend group -----------------------------
my $refused = cli( $d, 'group-add', 'alice', 'content-write' );
like( $refused, qr/backend group/i,
    'adding a PERSON to an unflagged group is refused, and says why' )
    or diag($refused);
like( $refused, qr/site-editor|assignable/i,
    'and points at the fix rather than stopping at the refusal' )
    or diag($refused);

my %after = %{ ( uapi( $d, { action => 'groups' } ) || {} )->{groups} || {} };
ok( !grep( { $_ eq 'alice' } @{ $after{'content-write'} || [] } ),
    'and nothing was written - a refusal that half-applies is worse than none' );

# --- 2. a GROUP still can, because that is what a backend group is for --------
# Nesting has its own verb (group-nest), which is the point: putting a PERSON in
# a group and putting a GROUP in one are different acts, and only the first is
# what `assignable` governs.
my $nested = uapi( $d, { action => 'group-nest', sub => 'site-editor', parent => 'content-write' } );
ok( $nested->{ok}, 'a GROUP may still be nested into a backend group' )
    or diag( explain $nested );
ok( uapi( $d, { action => 'group-nest', sub => 'site-editor', parent => 'data-read' } )->{ok},
    'and into the second one' );

# --- 3. and the role is assignable -------------------------------------------
my $ok = cli( $d, 'group-add', 'alice', 'site-editor' );
unlike( $ok, qr/refus|cannot/i, 'a person joins the assignable role' ) or diag($ok);

# --- 4. the union arrives through the CLOSURE, not through membership --------
# The point of composition: alice is a direct member of ONE group and holds the
# capabilities of two she was never added to.
my $eff = uapi( $d, { action => 'settings-get', username => 'alice' } )->{settings} || {};
ok( $eff->{manage_content}, 'alice holds manage_content through the closure' )
    or diag( explain $eff );
ok( $eff->{manage_data}, 'and manage_data, from the other backend group' );

require Lazysite::Auth::Settings;
{
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
    my @groups = Lazysite::Auth::Settings::effective_groups('alice');
    @groups = sort @groups;
    is_deeply( \@groups, [qw(content-write data-read site-editor)],
        'effective_groups resolves the role to its backend groups' );
}

# --- 5. the flag is visible where roles are assigned -------------------------
my $view = uapi( $d, { action => 'group-settings-get' } )->{groups} || {};
ok( $view->{'site-editor'}{assignable},    'the Groups view marks the role assignable' );
ok( !$view->{'content-write'}{assignable}, 'and the backend group as not' );

my $listing = cli( $d, 'groups' );
like( $listing, qr/content-write.*backend/i, 'the CLI listing marks a backend group' )
    or diag($listing);

# --- 6. an operator can change its mind --------------------------------------
my $set = uapi( $d,
    { action => 'group-settings-set', group => 'content-write', key => 'assignable', value => 'on' } );
ok( $set->{ok}, 'assignable is a settable group setting' ) or diag( explain $set );
unlike( cli( $d, 'group-add', 'alice', 'content-write' ), qr/backend group/i,
    'and the refusal lifts' );

# --- 7. the upgrade: a store that predates the flag loses nothing ------------
# The reading that matters on the day this ships. Every group on every existing
# site is unflagged, and if unflagged simply meant "backend" then nobody could
# be added to any group anywhere.
my $old = fresh();
write_groups_settings( $old, {
        'admins'  => { label => 'Admins',  manager => 1, ui => 1, manage_users => 1 },
        'editors' => { label => 'Editors', manage_content => 1 },
} );
uapi( $old, { action => 'add', username => 'bob', password => 'x' } );
unlike( cli( $old, 'group-add', 'bob', 'editors' ), qr/backend group/i,
    'a group that predates the flag is still assignable' );

my $backfilled = read_groups_settings($old);
ok( $backfilled->{editors}{assignable},
    'and the store is backfilled once, so the flag stops being ambiguous' );
ok( $backfilled->{admins}{assignable}, 'every group, not just the one touched' );

done_testing();

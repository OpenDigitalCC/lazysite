#!/usr/bin/perl
# SM642: an account is shown by its login everywhere, and a group's display
# name could not be edited at all.
#
# Accounts had no display name: every surface showed the login, so an operator
# reading the Users page saw `sjm-claude-code` rather than a person. Groups DO
# have one - SM631 gave every seeded group a `label`, and the pages render it -
# and `group-settings-set` has accepted `label` since SM195. Nothing in the UI
# offered it. So an operator could read a display name they had no way to
# change, and a group they created themselves showed its bare name for ever.
#
# DISPLAY ONLY, and that is the constraint that keeps it small. The login is
# the identity: the audit trail's actor, the subject of a grant, the name a
# credential is minted against, the value the API takes and returns. A display
# name is a label rendered over the top at the point of DISPLAY and nowhere
# else - which is what lets a surface adopt it one at a time without any
# surface that has not adopted it being wrong, only plainer.
#
# WHAT IS ASSERTED
#   display_name is settable, one line, length-capped, empty clears
#   it is surfaced to the page that has to render it
#   NOTHING resolves an account by it - it is not an identity
#   two accounts may share one, because it is not an identity
#   the group label was already settable, and is now offered in the UI
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
sub settings {
    my ( $d, $u ) = @_;
    return ( uapi( $d, { action => 'settings-get', username => $u } )->{settings} ) || {};
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
uapi( $d, { action => 'add', username => 'sjm', password => 'pw' } );
uapi( $d, { action => 'add', username => 'other', password => 'pw' } );

# --- settable, and surfaced ------------------------------------------------
my $r = uapi( $d, { action => 'settings-set', username => 'sjm',
        key => 'display_name', value => 'Stuart Mackintosh' } );
ok( $r->{ok}, 'display_name is settable' ) or diag explain $r;
is( settings( $d, 'sjm' )->{display_name}, 'Stuart Mackintosh',
    'and comes back on the account settings the page reads' );

# --- one line, and bounded -------------------------------------------------
uapi( $d, { action => 'settings-set', username => 'sjm',
        key => 'display_name', value => "Two\nLines\tand   spaces" } );
my $flat = settings( $d, 'sjm' )->{display_name};
unlike( $flat, qr/[\r\n\t]/,
    'newlines and tabs are flattened - it is rendered into a row' );

uapi( $d, { action => 'settings-set', username => 'sjm',
        key => 'display_name', value => ( 'x' x 200 ) } );
cmp_ok( length( settings( $d, 'sjm' )->{display_name} ), '<=', 64,
    'and it is capped, so it cannot push the login out of view' );

# --- empty clears ----------------------------------------------------------
uapi( $d, { action => 'settings-set', username => 'sjm',
        key => 'display_name', value => '' } );
ok( !defined settings( $d, 'sjm' )->{display_name},
    'an empty value clears it - removing it is the same gesture as never '
        . 'setting one' );

# --- it is NOT an identity -------------------------------------------------
# The property the whole design rests on. If anything resolved an account by
# display name, "display only" would stop being true and the gradual rollout
# would stop being safe.
uapi( $d, { action => 'settings-set', username => 'sjm',
        key => 'display_name', value => 'Shared Name' } );
my $dup = uapi( $d, { action => 'settings-set', username => 'other',
        key => 'display_name', value => 'Shared Name' } );
ok( $dup->{ok}, 'two accounts may share a display name - it is not an identity' );

my $byname = uapi( $d, { action => 'settings-get', username => 'Shared Name' } );
ok( !$byname->{ok} || !( $byname->{settings} && %{ $byname->{settings} } ),
    'and no account resolves BY display name' );

# --- the group half was already settable, and is now offered ---------------
uapi( $d, { action => 'group-create', group => 'ops' } );
my $lbl = uapi( $d, { action => 'group-settings-set', group => 'ops',
        key => 'label', value => 'Operations' } );
ok( $lbl->{ok}, 'a group label is settable (it always was)' );

my $page = do {
    open my $fh, '<', "$root/starter/manager/groups.md" or die $!;
    local $/;
    <$fh>;
};
like( $page, qr/setLabel\(/, 'and the Groups page now offers an editor for it' );
like( $page, qr/Display name/, 'labelled as a display name' );

my $users = do {
    open my $fh, '<', "$root/starter/manager/users.md" or die $!;
    local $/;
    <$fh>;
};
like( $users, qr/saveDisplayName\(/, 'the Users page offers one too' );
like( $users, qr/mg-muted">\(' \+ ue \+ '\)/,
    'and the list shows the LOGIN beside it - never hidden from the person '
        . 'deciding who may do what' );

done_testing();

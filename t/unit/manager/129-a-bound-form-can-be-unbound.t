#!/usr/bin/perl
# SM632: bind_form has an inverse.
#
# It wrote lazysite/forms/<name>.conf and there was NO undo on any token
# surface: nothing in the action registry, and delete_file refuses the path
# because lazysite/ is internal - correctly. So a capability a token may hold
# created an object no capability a token may hold could destroy, and
# registrations accumulated with nothing able to prune them (form-list counts a
# bound form with no store as a real form).
#
# A field agent hit this on edge.explore during the capability-row campaign: it
# left zz_r12_formflow behind, checked before and after so the residue would be
# visible rather than silent, and had to ask the operator to rm the conf. Same
# create-without-delete asymmetry SM578 closed for site packages.
#
# WHAT IT WILL NOT DO is the part worth testing hardest. A form with STORED
# SUBMISSIONS is refused: those are personal data, and removing the registration
# would leave them on disk and out of every listing - present, unreachable, and
# invisible, which is worse than leaving the form alone.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

my $root = "$FindBin::Bin/../../..";
require Lazysite::Manager::Plugins;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/forms/submissions");
$Lazysite::Manager::Plugins::DOCROOT = $d;
{
    no warnings 'once';
    $Lazysite::Manager::DOCROOT = $d;
}

sub conf { my ($n) = @_; return "$d/lazysite/forms/$n.conf" }
sub register {
    my ( $n, $handler ) = @_;
    open my $fh, '>', conf($n) or die $!;
    print {$fh} "targets:\n  - handler: " . ( $handler // 'local-storage' ) . "\n";
    close $fh;
}
sub store_rows {
    my ( $n, @rows ) = @_;
    open my $fh, '>', "$d/lazysite/forms/submissions/$n.jsonl" or die $!;
    print {$fh} "$_\n" for @rows;
    close $fh;
}

# --- 1. an unknown form is not silently "deleted" ---------------------------
{
    my $r = Lazysite::Manager::Plugins::action_form_delete( 'nope', 'nope' );
    is( $r->{ok},   0,              'deleting a form that is not registered fails' );
    is( $r->{kind}, 'no_such_form', 'and says which kind of nothing it found' );
}

# --- 2. the confirmation names the form -------------------------------------
# A destructive verb taking only an id is one an agent fires by having the
# wrong id.
{
    register('zz_probe');
    my $r = Lazysite::Manager::Plugins::action_form_delete('zz_probe');
    is( $r->{ok},   0,         'no confirmation, no deletion' );
    is( $r->{kind}, 'confirm', 'and it asks for one' );
    like( $r->{error}, qr/naming it exactly/, 'by name, not by yes' );
    ok( -f conf('zz_probe'), 'the registration is still there' );

    my $w = Lazysite::Manager::Plugins::action_form_delete( 'zz_probe', 'zz_other' );
    is( $w->{ok}, 0, 'a confirmation naming a DIFFERENT form is refused' );
    ok( -f conf('zz_probe'), 'and nothing is removed' );
}

# --- 3. the happy path ------------------------------------------------------
{
    my $r = Lazysite::Manager::Plugins::action_form_delete( 'zz_probe', 'zz_probe' );
    is( $r->{ok}, 1, 'confirmed, the registration goes' ) or diag( explain $r );
    ok( !-f conf('zz_probe'), 'the conf is gone from disk' );
    like( $r->{removed}, qr{lazysite/forms/zz_probe\.conf},
        'and the reply names what it removed' );
}

# --- 4. STORED SUBMISSIONS BLOCK IT -----------------------------------------
# The assertion this whole action is shaped around.
{
    register('zz_withdata');
    store_rows( 'zz_withdata', '{"name":"a"}', '{"name":"b"}' );

    my $r = Lazysite::Manager::Plugins::action_form_delete( 'zz_withdata', 'zz_withdata' );
    is( $r->{ok},   0,                 'a form holding submissions is not deleted' );
    is( $r->{kind}, 'has_submissions', 'and says why' );
    is( $r->{rows}, 2,                 'naming how many are at stake' );
    like( $r->{error}, qr/on disk and out of every listing/,
        'and what the harm would be - orphaned personal data, not lost work' );
    like( $r->{error}, qr/manager/,
        'pointing at the interactive route, which is deliberate (SM214)' );
    ok( -f conf('zz_withdata'), 'the registration survives' );
    ok( -s "$d/lazysite/forms/submissions/zz_withdata.jsonl",
        'and so do the submissions' );
}

# --- 5. an EMPTY store is not a reason to refuse ----------------------------
# There is nothing to orphan. Refusing here would leave a form nothing can
# remove, which is the defect this action exists to close.
{
    register('zz_emptystore');
    open my $fh, '>', "$d/lazysite/forms/submissions/zz_emptystore.jsonl" or die $!;
    close $fh;
    my $r = Lazysite::Manager::Plugins::action_form_delete( 'zz_emptystore', 'zz_emptystore' );
    is( $r->{ok}, 1, 'an empty store does not block the delete' ) or diag( explain $r );
    ok( !-f conf('zz_emptystore'), 'the registration goes' );
}

# --- 6. the reserved configs are not forms ----------------------------------
# handlers.conf holds every delivery destination; smtp.conf holds credentials.
# Neither is a form and this must never be the route to them.
# THEY MUST EXIST for this to prove anything. The first version of this asserted
# against a fixture where neither file was present, so removing the reserved-name
# guard still failed with "no such form" and the test passed for the wrong
# reason - a sabotage showed it. Create them, then the refusal has to be the
# guard doing its job, and the survival check proves it.
for my $reserved (qw(handlers smtp)) {
    open my $fh, '>', conf($reserved) or die $!;
    print {$fh} "# reserved\n";
    close $fh;
}
for my $reserved (qw(handlers smtp)) {
    my $r = Lazysite::Manager::Plugins::action_form_delete( $reserved, $reserved );
    is( $r->{ok},   0,         "'$reserved' is refused - it is not a form" );
    is( $r->{kind}, 'invalid', 'as an invalid target, not a missing one' );
    ok( -f conf($reserved), "and $reserved.conf survives" );
}

# --- 7. a traversing name is refused ----------------------------------------
{
    my $r = Lazysite::Manager::Plugins::action_form_delete( '../lazysite.conf', '../lazysite.conf' );
    is( $r->{ok},   0,              'a path-shaped name is refused' );
    is( $r->{kind}, 'invalid-path', 'as a path problem, not a missing form' );
}

done_testing();

#!/usr/bin/perl
# N13-04: the audit trail can be switched off, and the switch is answerable.
#
# RULED 2026-09-10: the trail stays switchable - an instance that records nothing
# is a legitimate thing to run - but the switch-off is written to the trail,
# naming who, BEFORE it stops, and the switch-on as it resumes, so the gap has
# named edges. RULED 2026-09-11: it needs manage_config AND audit_switch, in a
# group of its own that no role draws on by default.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_config manage_content audit_switch);
my $s   = new_site( root => repo_root() );
$s->add_user('op');
sub hold { $s->grant( 'op', 'ops', [ 'ui', @_ ], \@ALL ) }

my $trail = $s->docroot . '/lazysite/logs/audit.log';
sub lines { open my $fh, '<', $trail or return (); my @l = <$fh>; close $fh; chomp @l; return @l }
sub switch { my ( $state, $reason ) = @_; return $s->call( 'op', 'audit-trail-set', body => { state => $state, reason => $reason } ) }
sub audited_act { return $s->call( 'op', 'save', body => { path => '/p.md', content => "---\ntitle: P\n---\n\nx\n" } ) }

# --- BOTH PERMISSIONS, by ruling --------------------------------------------
hold('manage_config', 'manage_content');
{
    my $r = switch('off');
    ok( !$r->{ok}, 'Site config alone cannot switch the trail off' );
    is( $r->{kind} // '', 'forbidden', '...refused as a matter of authority' );
}
hold('audit_switch', 'manage_content');
{
    my $r = switch('off');
    ok( !$r->{ok}, 'the switch permission alone cannot either - both, by ruling' );
    like( $r->{error} // '', qr/Site config/, '...and the refusal names what is missing' );
}

hold( 'manage_config', 'audit_switch', 'manage_content' );

# --- THE CANARY: the trail is recording, and this rig can see it -----------
audited_act();
my @before = lines();
ok( scalar @before, 'an ordinary act is recorded - the rig can see the trail at all' );

# --- OFF: the edge first, then silence ------------------------------------
{
    my $r = switch( 'off', 'maintenance window' );
    ok( $r->{ok}, 'with both, the trail switches off' ) or diag( $r->{error} // '' );
    my @l = lines();
    like( $l[-1] // '', qr/\|\s*op\s*\|\s*audit-trail-off\s*\|/,
        'the switch-off is the last thing recorded, and it names who' );
    like( $l[-1] // '', qr/maintenance window/, '...with the reason given' );
}
{
    my $n = () = lines();
    audited_act();
    is( scalar( () = lines() ), $n, 'while off, an ordinary act records NOTHING' );
}
{
    my $r = switch('off');
    ok( $r->{ok} && !$r->{changed}, 'switching off what is already off changes nothing' );
}

# --- ON: resumption, then the edge ----------------------------------------
{
    my $r = switch( 'on', 'done' );
    ok( $r->{ok}, 'the trail switches back on' ) or diag( $r->{error} // '' );
    my @l = lines();
    like( $l[-1] // '', qr/\|\s*op\s*\|\s*audit-trail-on\s*\|/,
        'the switch-on is recorded, naming who - the gap has two named edges' );
}
{
    my $n = () = lines();
    audited_act();
    cmp_ok( scalar( () = lines() ), '>', $n, 'and ordinary acts are recorded again' );
}

# --- OFF NEVER DESTROYS ----------------------------------------------------
{
    my @now = lines();
    is_deeply( [ @now[ 0 .. $#before ] ], \@before,
        'everything recorded before the switch-off is still there, unchanged' );
}

done_testing();

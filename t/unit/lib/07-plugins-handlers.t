#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Plugins action handlers.
# Verifies the conf mutations and round-trip fidelity, not just that the
# handlers ran, and pins the specific refusal reasons.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Plugins qw(
    action_plugin_enable action_plugin_disable action_handler_save
    action_handler_list action_handler_delete action_form_targets_save
    action_form_targets_read resolve_plugin_script);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/forms", "$d/lazysite/cache" );
$Lazysite::Manager::Plugins::DOCROOT = $d;
$Lazysite::Manager::Plugins::action  = 'test';
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;

sub slurp_conf { open my $f, '<', "$d/lazysite/lazysite.conf"; local $/; <$f> }
sub handler_by_id {
    my ($id) = @_;
    my $hl = action_handler_list();
    return undef unless $hl->{ok};
    return ( grep { ( $_->{id} // '' ) eq $id } @{ $hl->{handlers} || [] } )[0];
}

# --- plugin enable / disable mutate the conf correctly ---
ok( action_plugin_enable('plugins/log.pl')->{ok},   'enable a plugin' );
like( slurp_conf(), qr{plugins:\s*\n\s+- plugins/log\.pl}s, 'plugin added under a plugins: block' );
ok( action_plugin_enable('plugins/audit.pl')->{ok}, 'enable a second' );
like( slurp_conf(), qr{audit\.pl}, 'second plugin present' );
ok( action_plugin_disable('plugins/log.pl')->{ok},  'disable a plugin' );
unlike( slurp_conf(), qr{log\.pl},  'disabled plugin removed' );
like( slurp_conf(), qr{audit\.pl},  'the other plugin survives the disable' );
my $bad = action_plugin_enable('');
ok( !$bad->{ok}, 'empty script rejected' );
like( $bad->{error}, qr/no script/i, 'with a "No script" error' );

# --- handler config round-trips its fields ---
my $hs = action_handler_save(
    { id => 'email1', type => 'smtp', name => 'Email', to => 'ops@example.com' } );
ok( $hs->{ok}, 'handler saved' );
my $h = handler_by_id('email1');
ok( $h, 'saved handler is listed' );
is( $h->{type}, 'smtp',            'handler type round-trips' );
is( $h->{to},   'ops@example.com', 'handler to-address round-trips' );
ok( action_handler_delete('email1')->{ok}, 'handler deleted' );
ok( !handler_by_id('email1'), 'deleted handler no longer listed' );
my $hbad = action_handler_save( { id => '' } );
ok( !$hbad->{ok}, 'handler with no id rejected' );
like( $hbad->{error}, qr/handler id/i, 'with an "Invalid handler ID" error' );

# --- form targets: clean single-format round-trips ---
ok( action_form_targets_save( 'contact', [ { handler => 'email1' }, { handler => 'local-storage' } ] )->{ok},
    'handler-format targets saved' );
is_deeply( action_form_targets_read('contact')->{targets},
    [ { handler => 'email1' }, { handler => 'local-storage' } ],
    'all-handler targets round-trip exactly' );

ok( action_form_targets_save( 'legacy', [ { type => 'file', path => 'submissions' } ] )->{ok},
    'legacy type-format targets saved' );
is_deeply( action_form_targets_read('legacy')->{targets},
    [ { type => 'file', path => 'submissions' } ],
    'all-type targets round-trip exactly' );

# Known limitation (SM081): a form mixing handler: + type: drops the type targets
# on read (action_form_targets_read skips the legacy block if any handler
# exists). Pin the CURRENT behaviour so a fix is a deliberate change.
action_form_targets_save( 'mixed', [ { handler => 'email1' }, { type => 'file' } ] );
my $mixed = action_form_targets_read('mixed')->{targets};
is_deeply( $mixed, [ { handler => 'email1' } ],
    'mixed-format read currently drops the type target (SM081 - documented bug)' );

# --- resolve_plugin_script ---
open my $p, '>', "$d/../sample-plugin.pl" or die $!;
print {$p} "1;\n"; close $p;
is( resolve_plugin_script('sample-plugin.pl'), "$d/../sample-plugin.pl",
    'resolves a plugin script beside the docroot (candidate 1)' );
ok( !defined resolve_plugin_script('does-not-exist.pl'),
    'a missing script resolves to undef' );
unlink "$d/../sample-plugin.pl";

done_testing();

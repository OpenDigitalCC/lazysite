#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Plugins action handlers
# (previously reachable only via subprocess, so unmeasured).
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

# --- plugin enable / disable (edits the plugins list in lazysite.conf) ---
ok( action_plugin_enable('plugins/log.pl')->{ok},   'enable a plugin' );
like( slurp_conf(), qr{plugins:.*log\.pl}s,          'plugin added to conf' );
ok( action_plugin_enable('plugins/audit.pl')->{ok}, 'enable a second' );
ok( action_plugin_disable('plugins/log.pl')->{ok},  'disable a plugin' );
unlike( slurp_conf(), qr{log\.pl},                   'plugin removed from conf' );
ok( !action_plugin_enable('')->{ok},                'empty script rejected' );

# --- handler config CRUD ---
my $hs = action_handler_save(
    { id => 'email1', type => 'smtp', name => 'Email', to => 'x@example.com' } );
ok( $hs->{ok}, 'handler saved' );
my $hl = action_handler_list();
ok( $hl->{ok}, 'handler list ok' );
ok( ( grep { ( $_->{id} // '' ) eq 'email1' } @{ $hl->{handlers} || [] } ),
    'saved handler appears in the list' );
ok( action_handler_delete('email1')->{ok}, 'handler deleted' );
ok( !action_handler_save( { id => '' } )->{ok}, 'handler with no id rejected' );

# --- form targets ---
ok( action_form_targets_save( 'contact', [ { type => 'file' }, { handler => 'email1' } ] )->{ok},
    'form targets saved' );
my $fr = action_form_targets_read('contact');
ok( $fr->{ok}, 'form targets read back' );

# --- resolve_plugin_script (path resolution) ---
open my $p, '>', "$d/../sample-plugin.pl" or die $!;
print {$p} "1;\n";
close $p;
is( resolve_plugin_script('sample-plugin.pl'), "$d/../sample-plugin.pl",
    'resolves a plugin script beside the docroot' );
ok( !defined resolve_plugin_script('does-not-exist.pl'),
    'missing script resolves to undef' );
unlink "$d/../sample-plugin.pl";

done_testing();

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

# SM152: a real install layout - base holds plugins/, docroot is base/public_html
# - so the plugin registry (base/plugins/*.pl + core) resolves. enable/disable
# and resolve now go through that registry, not an arbitrary path.
my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/forms", "$d/lazysite/cache", "$base/plugins" );
for my $p (qw(log.pl audit.pl)) {
    open my $pf, '>', "$base/plugins/$p" or die $!;
    print {$pf} "print '{\"id\":\"$p\",\"actions\":[]}' if \"@ARGV\"=~/--describe/; exit 0;\n";
    close $pf;
}
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

# SM081 (fixed): a form mixing handler: + type: now round-trips BOTH targets in
# document order (the read used to drop the type targets if any handler existed).
action_form_targets_save( 'mixed', [ { handler => 'email1' }, { type => 'file' } ] );
is_deeply( action_form_targets_read('mixed')->{targets},
    [ { handler => 'email1' }, { type => 'file' } ],
    'SM081 fixed: mixed-format read preserves both targets in order' );

# DATA-LOSS GUARD: the manager "Edit targets" UI only knows HANDLER targets. When
# it re-saves a form that has a legacy inline target, it sends only the handlers -
# the inline target must NOT be erased (it was, before this fix).
{
    # A form authored (by hand / WebDAV) with a handler AND an inline target.
    open my $fc, '>', "$d/lazysite/forms/legacymix.conf" or die $!;
    print $fc "targets:\n  - handler: email1\n  - type: webhook\n    url: https://hook.example/x\n";
    close $fc;
    # The UI re-saves sending ONLY the handler set (its view of the world).
    ok( action_form_targets_save( 'legacymix', [ { handler => 'email1' } ] )->{ok},
        'save with only the handler succeeds' );
    is_deeply( action_form_targets_read('legacymix')->{targets},
        [ { handler => 'email1' }, { type => 'webhook', url => 'https://hook.example/x' } ],
        'the legacy inline target is PRESERVED (not erased by a handler-only UI save)' );

    # But a submission that DOES carry inline targets replaces wholesale (a future
    # UI that manages them) - no duplication of the preserved set.
    action_form_targets_save( 'legacymix',
        [ { handler => 'email1' }, { type => 'file', path => 'submissions' } ] );
    is_deeply( action_form_targets_read('legacymix')->{targets},
        [ { handler => 'email1' }, { type => 'file', path => 'submissions' } ],
        'a submission carrying inline targets replaces wholesale (no double-write)' );
}

# --- resolve_plugin_script (SM152: registry-only) ---
is( resolve_plugin_script('plugins/log.pl'), "$base/plugins/log.pl",
    'a registered plugin resolves to its canonical path' );
ok( !defined resolve_plugin_script('does-not-exist.pl'),
    'an unregistered name resolves to undef' );
# A script placed beside the docroot is NOT a registry key -> no longer resolves
# (this was the RCE: arbitrary path resolution). See 27-plugin-registry-rce.t.
open my $p, '>', "$base/sample-plugin.pl" or die $!;
print {$p} "1;\n"; close $p;
ok( !defined resolve_plugin_script('sample-plugin.pl'),
    'a script beside the install root is NOT resolvable (registry-only)' );
ok( !defined resolve_plugin_script('../sample-plugin.pl'),
    'a traversal path is NOT resolvable' );
unlink "$base/sample-plugin.pl";

done_testing();

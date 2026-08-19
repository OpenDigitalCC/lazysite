#!/usr/bin/perl
# SM409 / ADR 0009: a contract plugin that is not enabled executes NOTHING.
#
# What was true before: the plugins: list drove the Plugin Manager LISTING -
# its parse lived inline in action_plugin_list, whose only consumer was the
# display - and nothing on any execution path read it. action_plugin_action
# ran any registered plugin; an operator who "disabled" one had changed a page,
# not the site. The recurring defect class (a control reporting one state
# while doing another), applied to the plugin system itself.
#
# The ruling (release manager, 2026-08-19): plugins that declare the ADR 0009
# `contract` are gated and BORN DISABLED; legacy plugins are untouched until
# each one's migration SM replicates its current effective state. So the gate
# must discriminate, and this test drives BOTH kinds through the REAL registry
# against a REAL fixture tree - a contract plugin and a legacy plugin, actual
# executables answering --describe.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Plugins qw(
    action_plugin_action action_plugin_read action_plugin_save
    action_plugin_enable action_plugin_disable plugin_enabled);

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

# A minimal but REAL plugin: answers --describe, and its one action writes a
# witness file - so "executed" and "refused" are facts on disk, not guesses.
sub write_plugin {
    my ( $path, %o ) = @_;
    my $contract = $o{contract} ? '"contract": 1,' : '';
    spit( $path, <<PLUGIN );
#!/usr/bin/perl
use strict; use warnings;
if ( \@ARGV && \$ARGV[0] eq '--describe' ) {
    print '{"id":"$o{id}","name":"$o{id}",$contract'
        . '"actions":[{"id":"touch","label":"Touch","run":"action"}],'
        . '"config_file":"lazysite/$o{id}.conf","config_schema":[{"key":"note","label":"Note","type":"text"}]}';
    exit 0;
}
if ( \@ARGV >= 2 && \$ARGV[0] eq '--action' && \$ARGV[1] eq 'touch' ) {
    open my \$fh, '>', "$o{witness}" or die; print {\$fh} "ran\\n"; close \$fh;
    print '{"ok":1}';
    exit 0;
}
exit 1;
PLUGIN
    chmod 0755, $path or die $!;
}

sub fixture {
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/web";
    make_path( "$d/lazysite", "$base/plugins" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    write_plugin( "$base/plugins/contract-demo.pl",
        id => 'contract-demo', contract => 1, witness => "$base/contract-ran" );
    write_plugin( "$base/plugins/legacy-demo.pl",
        id => 'legacy-demo', contract => 0, witness => "$base/legacy-ran" );
    $Lazysite::Manager::Plugins::DOCROOT = $d;
    return ( $base, $d );
}

subtest 'a contract plugin is BORN DISABLED and executes nothing' => sub {
    my ( $base, $d ) = fixture();
    ok( !plugin_enabled('plugins/contract-demo.pl'), 'not in the list' );

    my $r = action_plugin_action( 'contract-demo', 'plugins/contract-demo.pl',
        'touch', {} );
    ok( !$r->{ok}, 'execution refused' );
    like( $r->{error}, qr/disabled.*Plugin Manager/s,
        'with the house sentence pointing at the enable surface' );
    ok( !-f "$base/contract-ran",
        'and the plugin really did not run - no witness file' );
};

subtest 'a LEGACY plugin is untouched by the gate' => sub {
    my ( $base, $d ) = fixture();
    ok( !plugin_enabled('plugins/legacy-demo.pl'),
        'also not in the list - same list state as the contract plugin' );

    my $r = action_plugin_action( 'legacy-demo', 'plugins/legacy-demo.pl',
        'touch', {} );
    ok( $r->{ok},              'runs exactly as it always has' ) or diag $r->{error};
    ok( -f "$base/legacy-ran", 'the witness file proves it ran' );
};

subtest 'enabling turns the contract plugin on; disabling turns it OFF' => sub {
    my ( $base, $d ) = fixture();

    my $en = action_plugin_enable('plugins/contract-demo.pl');
    ok( $en->{ok},                                  'enabled' ) or diag $en->{error};
    ok( plugin_enabled('plugins/contract-demo.pl'), 'the predicate agrees' );

    my $r = action_plugin_action( 'contract-demo', 'plugins/contract-demo.pl',
        'touch', {} );
    ok( $r->{ok} && -f "$base/contract-ran", 'and it executes' );

    unlink "$base/contract-ran";
    my $dis = action_plugin_disable('plugins/contract-demo.pl');
    ok( $dis->{ok}, 'disabled' );
    my $r2 = action_plugin_action( 'contract-demo', 'plugins/contract-demo.pl',
        'touch', {} );
    ok( !$r2->{ok},               'off means off again' );
    ok( !-f "$base/contract-ran", 'no witness - it truly did not run' );
};

subtest 'config stays reachable on a DISABLED contract plugin' => sub {
    # An operator must be able to configure a plugin before enabling it, and
    # the enable flow itself is a config surface - so read/save are not gated.
    my ( $base, $d ) = fixture();
    my $read = action_plugin_read( 'contract-demo', 'plugins/contract-demo.pl' );
    ok( $read->{ok}, 'config read works while disabled' ) or diag $read->{error};
    my $save = action_plugin_save( 'contract-demo', 'plugins/contract-demo.pl',
        { note => 'configured before first enable' } );
    ok( $save->{ok}, 'config save works while disabled' ) or diag $save->{error};
};

done_testing();

#!/usr/bin/perl
# SM759: the runtime and the start-page gate read the plugin's enabled state
# through the SAME WRITER the Plugin Manager uses - never a fixture's idea of
# what the conf holds.
#
# The field found it: Enable wrote `plugins/daemon.pl` into the conf, the
# listing read it back as enabled, and the runtime looked up 'daemon.pl' -
# a word the conf never holds - and reported "the plugin is disabled" five
# minutes after the sysop had switched it on. Every daemon test had written
# `- daemon.pl` by hand, so the fixture agreed with the reader and the two
# never met. This test enables through action_plugin_enable and asks the
# readers, which is the only join that proves the writer and the readers
# agree on the key.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";

use Lazysite::Manager::Plugins;
use Lazysite::Daemon::Supervisor;
use Lazysite::Manager::StartPage;

my $engine = "$FindBin::Bin/../../..";

# The registry scans "$DOCROOT/../plugins", so the site sits one level below
# a directory that carries the engine's real plugins.
my $base = tempdir( CLEANUP => 1 );
symlink( "$engine/plugins", "$base/plugins" ) or die "symlink: $!";
my $root = "$base/site";
make_path("$root/lazysite/auth");
open my $c, '>', "$root/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: t\n";
close $c;

$Lazysite::Manager::Plugins::DOCROOT = $root;
$Lazysite::Manager::Common::DOCROOT  = $root;
$Lazysite::Manager::StartPage::DOCROOT = $root;

# The on_enable hook runs the plugin as a subprocess; it needs the lib.
local $ENV{PERL5LIB} = join ':', "$engine/lib", ( $ENV{PERL5LIB} // () );

subtest 'before: the runtime reads disabled' => sub {
    is( Lazysite::Daemon::Supervisor::should_run($root), 0, 'not enabled yet' );
};

subtest 'enable through the manager: the runtime reads enabled' => sub {
    my $r = Lazysite::Manager::Plugins::action_plugin_enable('plugins/daemon.pl');
    ok( $r->{ok}, 'the manager enabled it' ) or diag explain $r;
    open my $fh, '<', "$root/lazysite/lazysite.conf" or die $!;
    my $conf = do { local $/; <$fh> };
    close $fh;
    like( $conf, qr/^\s+-\s+plugins\/daemon\.pl$/m, 'the conf holds the registry key' );

    is( Lazysite::Daemon::Supervisor::should_run($root), 1,
        'should_run reads the key the manager wrote' );
    my $st = Lazysite::Daemon::Supervisor::status($root);
    is( $st->{desired}, 'on', 'status: desired on' );
    unlike( $st->{summary}, qr/plugin is disabled/, 'the summary does not call an enabled plugin disabled' )
        or diag $st->{summary};

    # The hook's answer is what the toggle shows; it must agree.
    ok( ref $r->{hook} eq 'HASH', 'on_enable ran status' ) or diag explain $r;
    is( $r->{hook}{desired}, 'on', 'and the toggle line is about an ENABLED plugin' );
};

subtest 'disable through the manager: the runtime reads disabled' => sub {
    my $r = Lazysite::Manager::Plugins::action_plugin_disable('plugins/daemon.pl');
    ok( $r->{ok}, 'disabled' ) or diag explain $r;
    is( Lazysite::Daemon::Supervisor::should_run($root), 0, 'should_run follows' );
};

subtest 'the start-page gate reads the same key' => sub {
    my $caps = { ui => 1 };
    is( Lazysite::Manager::StartPage::_page_reachable( 'stats', $caps ), 0,
        'stats page unreachable while its plugin is off' );
    my $r = Lazysite::Manager::Plugins::action_plugin_enable('plugins/stats.pl');
    ok( $r->{ok}, 'stats plugin enabled through the manager' ) or diag explain $r;
    is( Lazysite::Manager::StartPage::_page_reachable( 'stats', $caps ), 1,
        'and now reachable - the gate read what the manager wrote' );
};

done_testing;

#!/usr/bin/perl
# F8.4 of the 0.13.1 daemon review: lazysite-common ships two systemd units and
# no maintainer script, so an upgrade that changed a unit was not seen by
# systemd until an operator ran daemon-reload by hand.
#
# The cause, measured in a minimal rig (debhelper 13.24, compat 13): both units
# are TEMPLATES, and dh_installsystemd generates no snippets - no postinst, no
# daemon-reload - for a package whose only units are templates. A plain unit in
# the same package gets enable/restart/reload snippets; a template alone gets
# nothing. So the package carries its own postinst and postrm, doing the one
# thing the snippet would have: telling systemd the unit files changed.
#
# This holds the scripts' contract: they exist for the package that ships the
# units, run daemon-reload guarded on a running systemd, keep the #DEBHELPER#
# marker so dh_installdeb can still append, never restart an instance (that is
# the operator's call), and are POSIX sh that shellcheck accepts.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

# SM757: the daemon's unit (and its timer) moved to installers/systemd so the
# tarball carries them; the deb installs them from there.
my @shipped = map { s{.*/}{}r } ( glob("$ROOT/debian/*.service"), glob("$ROOT/installers/systemd/*.service") );
my %units = map { $_ => 1 } grep { /\@\.service$/ } @shipped;
ok( $units{'lazysite@.service'} && $units{'lazysited@.service'}, 'the package ships two templated units' );
ok( !( grep { !/\@\.service$/ } @shipped ),
    'and no plain unit - which is exactly the case dh_installsystemd generates nothing for' );
like( do { local ( @ARGV, $/ ) = "$ROOT/debian/lazysite-common.install"; <> }, qr{^installers/systemd/lazysited\@\.(?:service|timer) usr/lib/systemd/system$}m,
    'the deb installs the daemon unit and timer from installers/systemd' );

for my $script (qw(postinst postrm)) {
    subtest "lazysite-common.$script" => sub {
        my $p = "$ROOT/debian/lazysite-common.$script";
        ok( -f $p, 'exists for the package that ships the units' ) or return;
        my $s = slurp($p);
        like( $s, qr/\A#!\/bin\/sh\n/, 'POSIX sh, not bash - maintainer scripts run before anything is guaranteed' );
        like( $s, qr/^set -e$/m, 'set -e' );
        like( $s, qr/\[ -d \/run\/systemd\/system \]/, 'guards on a running systemd (a container or chroot has none)' );
        like( $s, qr/systemctl --system daemon-reload/, 'runs daemon-reload' );
        like( $s, qr/daemon-reload[^\n]*\|\| true/, 'and never fails the package operation on it' );
        like( $s, qr/^#DEBHELPER#$/m,               'keeps the #DEBHELPER# marker' );
        unlike( $s, qr/systemctl\s+(?:restart|stop|start|try-restart)/, 'restarts nothing - which sites restart, and when, is the operator\'s' );
        my $case = $script eq 'postinst' ? 'configure' : 'remove|purge';
        like( $s, qr/^\s*\Q$case\E\)/m, "acts on $case" );
    };
}

subtest 'shellcheck accepts them' => sub {
    plan skip_all => 'shellcheck not installed' unless grep { -x "$_/shellcheck" } split /:/, $ENV{PATH};
    for my $script (qw(postinst postrm)) {
        my $out = `shellcheck -s sh \Q$ROOT/debian/lazysite-common.$script\E 2>&1`;
        is( $? >> 8, 0, "lazysite-common.$script: shellcheck clean" ) or diag $out;
    }
};

done_testing();

#!/usr/bin/perl
# SM757: the tarball flow's per-site deploy (root) provisions the persistent
# runtime on EVERY deploy and upgrade, automatically: the host conf naming the
# site's own engine tree, the unit and its timer installed from the stage, the
# timer enabled, a running runtime restarted so an upgrade takes effect.
#
# The script runs as root against a Hestia host, so what a unit test can hold
# is the CONTRACT between the three parties - what the script writes, what the
# unit reads, what the timer starts - and that the pieces ship in the tarball.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $deploy  = slurp("$ROOT/installers/hestia/lazysite-hestia-deploy.sh");
my $unit    = slurp("$ROOT/installers/systemd/lazysited\@.service");
my $timer   = slurp("$ROOT/installers/systemd/lazysited\@.timer");
my ($block) = $deploy =~ /(# SM757:.*?\nfi\n)/s;
ok( $block, 'the deploy carries the SM757 provisioning block' ) or done_testing, exit;

subtest 'what the deploy writes is what the unit reads' => sub {
    my %written  = map { $_ => 1 } $block =~ /echo "([A-Z][A-Z_]+)=/g;
    my %consumed = map { $_ => 1 } $unit  =~ /\$\{([A-Z][A-Z_]+)\}/g;
    for my $k ( sort keys %consumed ) {
        ok( $written{$k}, "unit variable \${$k} is written by the deploy" );
    }
    is_deeply( [ sort keys %written ], [qw(DOCROOT ENGINE USER)], 'and exactly those three' );
    like( $block, qr/echo "ENGINE=\$DOM"/, 'ENGINE is the domain root - the site\'s own tools\/ and lib\/, since a tarball host has no \/usr\/share\/lazysite' );
    like( $block, qr{DCONF="\$DAEMON_ETC/\$DOMAIN\.conf"}, 'the conf is named by domain, the unit instance' );
    like( $block, qr/mv -f "\$DTMP" "\$DCONF"/, 'written whole, then renamed into place' );
};

subtest 'the units are installed from the stage and refreshed when they change' => sub {
    like( $block, qr/for unit in lazysited\@\.service lazysited\@\.timer; do/, 'both units' );
    like( $block, qr{src="\$STAGE/installers/systemd/\$unit"}, 'from installers/systemd in the tarball' );
    like( $block, qr{dst=/etc/systemd/system/\$unit}, 'into /etc/systemd/system - the tarball flow has no package to own /usr/lib' );
    like( $block, qr/cmp -s "\$src" "\$dst"/, 'installed only when different' );
    like( $block, qr/if \[ "\$UNITS_CHANGED" = 1 \]; then systemctl daemon-reload; fi/, 'daemon-reload only when a unit changed' );
    ok( -f "$ROOT/installers/systemd/lazysited\@.timer", 'the timer ships' );
    like( $timer, qr/^OnUnitInactiveSec=300$/m, 'the timer retries a not-running service every five minutes' );
    like( $timer, qr/^Unit=lazysited\@%i\.service$/m, 'and starts the service, not itself' );
};

subtest 'the timer is enabled, a running runtime is restarted, nothing else is started' => sub {
    like( $block, qr/systemctl enable --now "lazysited\@\$DOMAIN\.timer"/, 'the TIMER is what is enabled' );
    unlike( $block, qr/systemctl enable --now "lazysited\@\$DOMAIN\.service"/, 'the service is not force-started - the plugin is the site\'s switch' );
    like( $block, qr/if systemctl is-active --quiet "lazysited\@\$DOMAIN\.service"; then\s*systemctl restart/s, 'a running runtime is restarted on the new release' );
    like( $block, qr/command -v systemctl .* \[ -d \/run\/systemd\/system \]/, 'guarded on a running systemd' );
    unlike( $block, qr/\$DOC\/[^\s"]*\s*(>|>>)/, 'nothing is written into the site tree' );
};

subtest 'the deb tool enables the same timer' => sub {
    my $tool = slurp("$ROOT/tools/lazysite-hestia-domain.pl");
    like( $tool, qr/enable_unit\(\s*'lazysited',\s*"\$domain\.timer"/, 'add --daemon enables the timer' );
    like( $tool, qr/"\$unit\\\@\$domain\.timer"/, 'remove disables it' );
};

done_testing();

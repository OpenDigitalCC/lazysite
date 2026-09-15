#!/usr/bin/perl
# SM666: `lazysite-hestia-domain add ... --daemon` is how the runtime reaches a
# real host. Until it existed the daemon had run only under prove, and the
# README told an operator to write a conf and enable a unit by hand - the
# self-sufficiency argument (SM286) cut against exactly that.
#
# What can be tested without root is the CONTRACT between the three parties:
# the tool that writes the conf, the unit that consumes it, and the package
# that must create the directory the tool writes into. The write itself runs
# as root, like --fcgi's, and is covered the same way: by the keys agreeing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT = repo_root();
my $TOOL = "$ROOT/tools/lazysite-hestia-domain.pl";
my $UNIT = "$ROOT/installers/systemd/lazysited\@.service"; # SM757: shipped in the tarball too

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub run_tool {
    my (@args) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for qw(
        LAZYSITE_HESTIA_HOME LAZYSITE_REGISTRY_DIR
        LAZYSITE_POOLS_DIR   LAZYSITE_DAEMON_DIR LAZYSITE_WEB_GROUP
    );
    my $cmd = join ' ', map { quotemeta } $^X, $TOOL, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

my $tool_src = slurp($TOOL);
my $unit_src = slurp($UNIT);

# SM893 CHANGED THIS CONTRACT, and the subtest changed with it rather than
# being loosened. The runtime used to be armed only on `--daemon`; the release
# manager ruled 2026-09-15 that every site is armed, because the Hestia deploy
# already did that for every site on every run and the two flows disagreed.
#
# What is still worth asserting is the part that has not changed: `--daemon` is
# STILL ACCEPTED, so runbooks and scripts that pass it do not start erroring,
# and the usage still says the plugin is the other switch - which is the one
# sentence an operator must not miss, now more than before, because an armed
# site that is doing nothing is the normal case rather than the unusual one.
subtest 'the flag is still accepted, and the usage explains the two switches' => sub {
    like( $tool_src, qr/'daemon'\s*=>\s*\\\$o\{daemon\}/,
        'GetOptions still accepts --daemon, so passing it is not an error' );

    my ( $rc, $out ) = run_tool('--help');
    is( $rc, 0, 'help exits 0' );
    like( $out, qr/lazysited\@DOMAIN/, 'usage names the unit it enables' );
    like( $out, qr/LAZYSITE_DAEMON_DIR/,
        'and the directory override the test rigs need' );

    like( $out, qr/ALWAYS writes/,
        'usage says the runtime conf is always written, not asked for' )
        or diag( 'If the usage still reads as opt-in, an operator will go on '
            . 'passing a flag that does nothing and assume its absence is why '
            . 'a site is not running the daemon.' );

    # Whitespace-tolerant: this sentence wraps, and where it wraps is not the
    # contract - that the sentence is THERE is.
    like( $out, qr/until\s+the\s+site's\s+sysop\s+also\s+enables\s+the\s+`daemon`\s+plugin/,
        'usage says the plugin is the other switch' );
    like( $tool_src, qr/two switches/i, 'and so does the POD' );
};

subtest 'the conf the tool writes is the conf the unit reads' => sub {
    # The daemon block builds its conf from [ KEY => value ] pairs, the same
    # writer the pool uses. Isolate that block so the pool's extra keys
    # (GROUP, WORKERS, MAX_REQUESTS) are not mistaken for the daemon's.
    # SM893: anchored on the conf path rather than on `if ( $o{daemon} )`,
    # which no longer exists - the block is now unconditional. The anchor that
    # survives a change of control flow is the thing the block is FOR.
    my ($block) = $tool_src =~ /(my \$conf = daemon_conf_path\(\$domain\);.*?\n    \})/s;
    ok( $block, 'found the block that writes the runtime conf' ) or return;

    my %emitted = map { $_ => 1 } $block =~ /\[\s*([A-Z][A-Z_]+)\s*=>/g;
    is_deeply( [ sort keys %emitted ], [qw(DOCROOT USER)],
        'the daemon conf carries exactly DOCROOT and USER' );

    my %consumed = map { $_ => 1 } $unit_src =~ /\$\{([A-Z][A-Z_]+)\}/g;
    for my $k ( sort keys %emitted ) {
        ok( $consumed{$k}, "emitted key $k= is consumed by lazysited\@.service" );
    }
    # SM757: a unit variable is either written by the tool or DEFAULTED in the
    # unit (Environment=). ENGINE is the second kind: the deb's engine lives at
    # /usr/share/lazysite, so the deb tool writes nothing and the default
    # applies; the tarball deploy writes ENGINE=<domain root> and
    # EnvironmentFile= overrides the default.
    my %defaulted = map { $_ => 1 } $unit_src =~ /^Environment=([A-Z][A-Z_]+)=/mg;
    for my $k ( sort keys %consumed ) {
        ok( $emitted{$k} || $defaulted{$k}, "unit variable \${$k} is written by the tool or defaulted in the unit" );
    }
    ok( $defaulted{ENGINE}, 'ENGINE is defaulted to the deb payload' );
    like( $unit_src, qr{^Environment=ENGINE=/usr/share/lazysite$}m, 'at /usr/share/lazysite' );

    like( $block, qr/daemon_conf_path\(\$domain\)/,
        'written at the daemon conf path' );
    like( $tool_src, qr{: '/etc/lazysite/daemon';}, 'which defaults under /etc/lazysite/daemon' );
    like( $unit_src, qr{^ConditionPathExists=/etc/lazysite/daemon/%i\.conf$}m,
        'the same path the unit conditions on' );
    like( $unit_src, qr{^EnvironmentFile=/etc/lazysite/daemon/%i\.conf$}m,
        'and reads its environment from' );

    like( $block, qr/enable_unit\(\s*'lazysited',\s*"\$domain\.timer"/,
        'and the block enables lazysited@DOMAIN.timer - the timer starts the service (SM757)' );
    ok( -f "$ROOT/installers/systemd/lazysited\@.timer", 'the timer unit ships beside the service' );
};

subtest 'the package creates the directory the tool writes into' => sub {
    # write_kv_file refuses when the directory is missing ("is lazysite-common
    # installed?"), so a package that ships the unit without the directory
    # ships a --daemon that fails on every fresh host.
    my $dirs = slurp("$ROOT/debian/lazysite-common.dirs");
    like( $dirs, qr{^etc/lazysite/daemon$}m,
        'lazysite-common.dirs declares etc/lazysite/daemon' );
    like( $dirs, qr{^etc/lazysite/pools$}m,
        '(beside the pool directory it mirrors)' );
};

subtest 'remove retires the runtime the way it retires the pool' => sub {
    my ($remove) = $tool_src =~ /(sub cmd_remove \{.*?\n\})/s;
    ok( $remove, 'found cmd_remove' ) or return;
    like( $remove, qr/daemon_conf_path\(\$domain\)/,
        'remove looks for the daemon conf' );
    like( $remove, qr/'lazysited'/, 'and disables the lazysited unit' );
    like( $remove, qr/pool_conf_path\(\$domain\)/,
        'while still retiring the pool' );
};

subtest 'the README tells the operator the provisioned route' => sub {
    my $readme = slurp("$ROOT/debian/lazysite-hestia.README.Debian");
    like( $readme, qr/lazysite-hestia-domain add <user> <domain> --fcgi --daemon/,
        'README gives the one-command onboarding with the runtime' );
    like( $readme, qr/TWO SWITCHES/, 'and still says both switches must be on' );
};

done_testing();

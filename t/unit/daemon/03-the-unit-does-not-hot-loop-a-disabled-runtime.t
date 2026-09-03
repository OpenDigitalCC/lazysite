#!/usr/bin/perl
# SM666 phase 1: the systemd unit, and the one line in it that must not drift.
#
# lazysited exits 0 when the daemon plugin is disabled - deliberately, because
# that is what "the process never starts" means. Under `Restart=always`, which
# is what the FastCGI pool unit correctly uses, systemd would restart it
# forever: a hot loop on every site with the unit enabled and the plugin off,
# which is the COMMON case on a host with many instances.
#
# So the unit must use Restart=on-failure, and the exit codes must mean what
# on-failure needs them to mean. Neither half is much use without the other,
# and neither is visible from reading one file, so both are asserted here.
#
# THIS IS A CHEAP TEST FOR AN EXPENSIVE MISTAKE. Nothing else would notice:
# the loop only appears on a real host, at scale, on the sites that have NOT
# turned the runtime on.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $unit = "$root/debian/lazysited\@.service";

plan skip_all => 'no packaging tree' unless -f $unit;

my $src = do {
    open my $fh, '<', $unit or die "$unit: $!";
    local $/;
    <$fh>;
};

subtest 'the unit restarts on failure, never always' => sub {
    like( $src, qr/^Restart=on-failure$/m,
        'Restart=on-failure - a disabled runtime exits 0 and must STAY stopped' );
    unlike( $src, qr/^Restart=always$/m,
        'not Restart=always, which would hot-loop every site with the plugin off' )
        or diag( 'The pool unit uses always and is right to; this one must not. '
            . 'A disabled runtime exits 0 on purpose, and always would restart '
            . 'it forever on the majority of instances.' );
};

subtest 'the unit is inert until an instance is configured' => sub {
    like( $src, qr{^ConditionPathExists=/etc/lazysite/daemon/%i\.conf$}m,
        'an uninstantiated unit does not run - the cost at rest is nothing' );
    like( $src, qr{^EnvironmentFile=/etc/lazysite/daemon/%i\.conf$}m,
        'and its identity comes from that file, not from the unit' );
};

subtest 'it does not run the site as root' => sub {
    like( $src, qr/--user \$\{USER\}/,
        'USER is passed through, so the runtime can drop to it' );
    like( $src, qr/^NoNewPrivileges=yes$/m, 'and privileges cannot be regained' );
};

subtest 'the exit codes are what on-failure needs them to be' => sub {
    # The unit half is only half the property. If a disabled runtime ever
    # exited non-zero, on-failure would restart it and we would be back to the
    # loop by a different route.
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/lazysite";
    open my $c, '>', "$dir/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: t\n";    # no plugins: list, so daemon is disabled
    close $c;

    my $tool = "$root/tools/lazysited.pl";
    system( $^X, $tool, '--docroot', $dir, '--user', scalar getpwuid($>) );
    my $rc = $? >> 8;

    is( $rc, 0,
        'a disabled runtime exits 0 - which under on-failure means stay stopped' );
    ok( !-d "$dir/lazysite/daemon",
        'and it left no state behind, so nothing began to start' );
};

done_testing();

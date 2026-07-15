#!/usr/bin/perl
# SEC-2026-07 (H-SSI / H-HTACCESS): the shipped Apache/Hestia vhost templates
# must not enable SSI #exec (Options +Includes without NOEXEC) or .htaccess
# override (AllowOverride All) on a writable docroot - either one turns an
# authored file into RCE as the web user. Pin the hardened form so a template
# edit can't silently reintroduce it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root      = repo_root();
my @templates = (
    glob("$root/installers/apache/vhost-*.conf.example"),
    glob("$root/installers/hestia/*.tpl"),
    glob("$root/installers/hestia/*.stpl"),
);
ok( scalar @templates >= 6, 'vhost templates present' );

for my $t (@templates) {
    open my $fh, '<', $t or do { fail("read $t"); next };
    my $src = do { local $/; <$fh> };
    close $fh;
    ( my $name = $t ) =~ s{.*/}{};
    unlike( $src, qr/\+Includes\b(?!NOEXEC)/,
        "$name: no bare +Includes (SSI #exec) - use +IncludesNOEXEC" );
    unlike( $src, qr/AllowOverride\s+All/,
        "$name: no AllowOverride All (.htaccess handler injection)" );
}

# SEC-2026-07 (L-SYSTEMD): the FastCGI pool unit must carry the sandbox
# directives so the long-running worker's blast radius stays small.
{
    my $unit = "$root/debian/lazysite\@.service";
    open my $fh, '<', $unit or do { fail("read $unit"); goto DONE };
    my $src = do { local $/; <$fh> };
    close $fh;
    for my $d (qw(NoNewPrivileges ProtectSystem PrivateTmp RestrictSUIDSGID)) {
        like( $src, qr/^\Q$d\E=/m, "lazysite\@.service sets $d" );
    }
}
DONE:

done_testing();

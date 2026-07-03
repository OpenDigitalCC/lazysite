#!/usr/bin/perl
# SM128: end-to-end enforcement of the bad-URL auto-blocker in the auth wrapper.
# A probe blocks the source IP (threshold 1 here for a fast test); a blocked IP is
# refused for any URL; a clean IP on a normal page passes through; disabling the
# blocker turns enforcement off.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(env_passthrough setup_minimal_site);

my $root    = "$FindBin::Bin/../..";
my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/lazysite/cache");
make_path("$docroot/lazysite/logs");

open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "bad_url_threshold: 1\nbad_url_window: 3600\n";   # block on the first probe
close $cf;

sub req {
    my ( $uri, $ip ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $docroot,
        REDIRECT_URL       => $uri,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => '',
        REMOTE_ADDR        => $ip,
        LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
    );
    return qx($^X \Q$root/lazysite-auth.pl\E 2>/dev/null);
}

like( req( '/wp-login.php', '10.0.0.1' ), qr/403 Forbidden/,
    'a probe blocks the source IP (403)' );
like( req( '/', '10.0.0.1' ), qr/403 Forbidden/,
    'the now-blocked IP is refused for a normal URL too' );
unlike( req( '/', '10.0.0.2' ), qr/403 Forbidden/,
    'a clean IP on a normal page is not blocked (passes through)' );

# The block was recorded in the audit log.
my $audit = '';
if ( open my $a, '<', "$docroot/lazysite/logs/audit.log" ) { local $/; $audit = <$a>; close $a; }
like( $audit, qr/ip-auto-blocked/, 'the auto-block is recorded in the audit log' );

# Disabling the blocker turns enforcement off for a fresh IP.
open my $cf2, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf2 "bad_url_block: disabled\n";
close $cf2;
unlike( req( '/wp-login.php', '10.0.0.3' ), qr/403 Forbidden/,
    'with the blocker disabled, a probe from a fresh IP is not blocked' );

done_testing();

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

# SM1455: Apache sets REDIRECT_URL only on an internal redirect (an ErrorDocument,
# say); on the rewrite [PT] and FallbackResource routes it is unset and the path is
# REQUEST_URI, with its query. So a request sends REQUEST_URI, as Apache does, and
# `redirect => 1` sends REDIRECT_URL (and no REQUEST_URI) as the internal redirect would.
# The routes themselves, behind real Apache, are t/integration/732.
sub req {
    my ( $uri, $ip, %o ) = @_;
    my ( $path, $q ) = split /\?/, $uri, 2;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $docroot,
        ( $o{redirect} ? ( REDIRECT_URL => $path ) : ( REQUEST_URI => $uri ) ),
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => $q // '',
        REMOTE_ADDR        => $ip,
        LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
    );
    return qx($^X \Q$root/lazysite-auth.pl\E 2>/dev/null);
}

like( req( '/wp-login.php?x=1', '10.0.0.1' ), qr/403 Forbidden/,
    'a probe blocks the source IP (403), read from REQUEST_URI less its query' );
like( req( '/', '10.0.0.1' ), qr/403 Forbidden/,
    'the now-blocked IP is refused for a normal URL too' );
unlike( req( '/', '10.0.0.2' ), qr/403 Forbidden/,
    'a clean IP on a normal page is not blocked (passes through)' );

# An internal redirect sets REDIRECT_URL, and that still wins.
like( req( '/wp-login.php', '10.0.0.4', redirect => 1 ), qr/403 Forbidden/,
    'a probe path in REDIRECT_URL (an internal redirect) blocks too' );

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

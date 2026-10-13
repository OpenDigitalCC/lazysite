#!/usr/bin/perl
# SM1069: a `.url` page under a READ rule is answered as a gated .md page is -
# no-store, private, and never read from or written to the shared cache.
#
# The .url branch called output_page with no protected flag and process_url
# read and wrote its render cache whoever asked. The gate ran first, so a
# reader outside the list was still refused; but the listed reader's answer was
# cacheable by any HTTP cache, and the render landed beside its source - in the
# document root for a source that lives there, where a front end serves it to
# anyone. Found while building SM1068.
#
# No network: the remote address is loopback, which the SSRF guard refuses
# before connecting, so a fetch always fails here and a body can only come from
# the render cache.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site site_tempdir run_processor);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub cache_control { my ($r) = @_; my ($cc) = $r =~ /^Cache-Control:\s*([^\r\n]*)/mi; return $cc // '' }

my @ALICE = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );

sub site {
    my ($rules) = @_;
    my $d = site_tempdir();
    setup_auth_site($d);
    mkdir "$d/sec";
    put( "$d/sec/remote.url",          "http://127.0.0.1:9/page\n" );
    put( "$d/lazysite/auth/acls.json", $rules );
    return $d;
}

subtest 'under a READ rule: no-store, and the render cache is neither read nor written' => sub {
    my $d = site('{"sec":{"read":["alice"]}}');
    # A render left in the cache slot, fresh - what an earlier fetch would leave.
    put( "$d/sec/remote.html", "<html><body>CACHED-REMOTE-1069</body></html>\n" );
    my $r = run_processor( $d, '/sec/remote', @ALICE );
    like( cache_control($r), qr/no-store, private/, 'the listed reader is answered no-store, private' );
    unlike( $r, qr/CACHED-REMOTE-1069/, 'and not from the shared render cache' );

    unlink "$d/sec/remote.html";
    run_processor( $d, '/sec/remote', @ALICE );
    ok( !-f "$d/sec/remote.html", 'and a render is not written beside the source' );

    my $anon = run_processor( $d, '/sec/remote' );
    like( $anon, qr/^Status: 30[23]/m, 'anonymous is still sent to log in' );
};

subtest 'THE CONTROL: under a write-only rule the cache still serves it' => sub {
    my $d = site('{"/":{"owner":"root","write":["@admins"]}}');
    put( "$d/sec/remote.html", "<html><body>CACHED-REMOTE-1069</body></html>\n" );
    my $r = run_processor( $d, '/sec/remote' );
    like( $r, qr/CACHED-REMOTE-1069/, 'a fresh render is served from the cache' );
    unlike( cache_control($r), qr/no-store/, 'cacheable' );
};

done_testing();

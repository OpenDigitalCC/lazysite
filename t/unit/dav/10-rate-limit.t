#!/usr/bin/perl
# SM071 Phase 3 (P3.6): DAV per-token volume throttle and the Retry-After
# retry contract (429 throttle, 423 locked).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site);

my $s    = setup_dav_site();   # user 'deploy', webdav on
my $doc  = $s->{docroot};
my $auth = $s->{auth};

# burst 2, no refill -> deterministic exhaustion on the 3rd write.
my %rate = ( LAZYSITE_RATE_BURST => 2, LAZYSITE_RATE_REFILL => 0 );

sub put {
    my ($name) = @_;
    return run_dav( $doc, 'PUT', "/content/$name",
        HTTP_AUTHORIZATION => $auth, body => 'x', %rate );
}

my $c1 = put('a.txt')->{code};
my $c2 = put('b.txt')->{code};
ok( ( $c1 == 201 || $c1 == 204 ), "write 1 ok ($c1)" );
ok( ( $c2 == 201 || $c2 == 204 ), "write 2 ok ($c2)" );

my $r3 = put('c.txt');
is( $r3->{code}, 429, 'write 3 throttled (429)' );
ok( $r3->{headers}{'retry-after'}, '429 carries Retry-After' );

# Reads do not consume the bucket - still served after write exhaustion.
my $rd = run_dav( $doc, 'PROPFIND', '/content',
    HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0', %rate );
is( $rd->{code}, 207, 'reads are not throttled' );

# --- 423 (locked) also carries Retry-After ----------------------------
unlink "$doc/lazysite/auth/.token-rate.json";   # reset bucket for this case
make_path("$doc/lazysite/manager/locks");
open my $lf, '>', "$doc/lazysite/manager/locks/content:locked.txt.lock" or die $!;
print $lf encode_json({ user => 'other', at => time(), origin => 'dav', timeout => 300 });
close $lf;
my $lk = run_dav( $doc, 'PUT', '/content/locked.txt',
    HTTP_AUTHORIZATION => $auth, body => 'x' );   # default burst, not throttled
is( $lk->{code}, 423, 'write to a locked path returns 423' );
ok( $lk->{headers}{'retry-after'}, '423 carries Retry-After' );

done_testing();

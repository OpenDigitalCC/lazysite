#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): "A FORM POSTED DURING MAINTENANCE IS REFUSED WITH
# THE MAINTENANCE MESSAGE, NOT STORED." And the data endpoint, the other door a
# page's own script writes through, answers like the machine doors do.
#
# The form handler runs direct, outside the auth wrapper (SM402), so it asks for the
# one identity it can verify: the HMAC-checked session cookie. A verified account
# holding `maintenance_access` posts as it always did; anyone else is refused
# before the rate limiter (a refusal does not spend a quota), before the uploads
# and before any delivery. The refusal rides the same closed table of sentences as
# every other (t/lint/156 holds the processor's copy to the handler's), so the
# no-JavaScript redirect carries a code, never the words.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = site_tempdir( plugins => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/lazysite/forms" );
sub conf {
    my ($extra) = @_;
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n$extra";
    close $cf;
}
conf("maintenance: on\n");
open my $hcf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hcf} "handlers:\n  - id: store\n    type: file\n    name: Store\n";
close $hcf;
open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$ff} "spam_dwell: off\ntargets:\n  - handler: store\n";
close $ff;
for my $f ( [ "$docroot/lazysite/auth/.secret", 'a' x 64 ], [ "$docroot/lazysite/forms/.secret", 'b' x 64 ] ) {
    open my $sf, '>', $f->[0] or die $!;
    print {$sf} $f->[1];
    close $sf;
}
for my $u (qw(plainmember opmember)) {
    my $made = qx($^X \Q$root/tools/lazysite-users.pl\E --docroot \Q$docroot\E add $u pw123456789-long-enough 2>&1);
    is( $?, 0, "account $u made" ) or diag($made);
}
grant_caps( $docroot, 'opmember', 'maintenance_access' );

sub cookie { my $pay = "$_[0]:" . time . ':'; return "lazysite_auth=$pay:" . hmac_sha256_hex( $pay, 'a' x 64 ) }
sub stored {
    open my $fh, "<", "$docroot/lazysite/forms/submissions/contact.jsonl" or return 0;
    my @l = <$fh>;
    return scalar @l;
}

sub submit {
    my (%extra) = @_;
    my $ts      = time - 10;
    my $tk      = hmac_sha256_hex( $ts, 'b' x 64 );
    my $page    = delete $extra{_page};
    my $body = "_form=contact&name=x&_hp=&_ts=$ts&_tk=$tk" . ( defined $page ? "&_page=$page" : '' );
    my $bf = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        HTTP_HOST      => 'site.test',
        HTTP_ACCEPT    => ( defined $page ? 'text/html' : 'application/json' ),
        %extra,
    );
    my $out = qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
    return $out;
}
sub json_of { my ($o) = @_; my ($jb) = $o =~ /\r?\n\r?\n(.*)/s; return eval { decode_json( $jb // $o ) } // {} }

subtest 'an anonymous post is refused with the maintenance message and stored nowhere' => sub {
    my $r = json_of( submit() );
    is( $r->{ok}, 0, 'refused' );
    like( $r->{error} // '', qr/in maintenance.*not sent and nothing was stored/i, '...with the maintenance message' );
    is( stored(), 0, '...and nothing was stored' );
};

subtest 'the no-JavaScript post lands back on its page with a code, not words' => sub {
    my $o = submit( _page => '/contact' );
    like( $o, qr{^Status: 303}m, 'a redirect back' );
    like( $o, qr{^Location: /contact\?form=contact&outcome=maintenance\s*$}m, '...carrying the code' );
    is( stored(), 0, '...and nothing was stored' );
};

subtest 'a signed-in account without the capability is refused' => sub {
    my $r = json_of( submit( HTTP_COOKIE => cookie('plainmember') ) );
    is( $r->{ok}, 0, 'refused' );
    like( $r->{error} // '', qr/in maintenance/i, '...as in maintenance' );
    is( stored(), 0, '...and nothing was stored' );
};

subtest 'a forged cookie is nobody' => sub {
    my $pay = 'opmember:' . time . ':';
    my $r   = json_of( submit( HTTP_COOKIE => "lazysite_auth=$pay:" . ( 'f' x 64 ) ) );
    is( $r->{ok}, 0, 'refused: a bad signature does not hold the capability' );
    is( stored(), 0, '...and nothing was stored' );
};

subtest 'an account that holds the capability posts as it always did' => sub {
    my $r = json_of( submit( HTTP_COOKIE => cookie('opmember') ) );
    is( $r->{ok}, 1, 'accepted' ) or diag( $r->{error} // '' );
    is( stored(), 1, '...and stored' );
};

subtest 'off: everyone posts' => sub {
    conf("maintenance: off\n");
    my $r = json_of( submit() );
    is( $r->{ok}, 1, 'an anonymous post is accepted' ) or diag( $r->{error} // '' );
    is( stored(), 2, '...and stored' );
};

subtest 'per domain' => sub {
    conf("alias_hosts: a.example, b.example\nalias.a.example.maintenance: on\n");
    my $before = stored();
    is( json_of( submit( HTTP_HOST => 'a.example' ) )->{ok}, 0, 'refused on the domain in maintenance' );
    is( stored(), $before,                                      '...and not stored' );
    is( json_of( submit( HTTP_HOST => 'b.example' ) )->{ok}, 1, 'accepted on its sibling' );
    is( json_of( submit( HTTP_HOST => 'a.example', HTTP_COOKIE => cookie('opmember') ) )->{ok}, 1, 'accepted from the holder on the domain' );
};

# --- the data endpoint ---------------------------------------------------------
subtest 'the data endpoint answers 503 to an account without the capability' => sub {
    conf("maintenance: on\n");
    my $data = sub {
        my (%extra) = @_;
        local %ENV = ( env_passthrough(),
            DOCUMENT_ROOT  => $docroot,
            REQUEST_METHOD => 'GET',
            QUERY_STRING   => 'csrf=1',
            REMOTE_ADDR    => '203.0.113.9',
            HTTP_HOST      => 'site.test',
            %extra,
        );
        my $out    = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
        my ($code) = $out =~ /^Status:\s*(\d+)/m;
        my ($ra)   = $out =~ /^Retry-After:\s*(\d+)/mi;
        return ( $code // 0, $ra, json_of($out) );
    };
    my ( $code, $ra, $j ) = $data->();
    is( $code, 503, 'an anonymous caller: 503' );
    ok( $ra, '...with Retry-After' );
    is( $j->{kind}, 'maintenance', '...kind maintenance' );

    ( $code, $ra, $j ) = $data->( HTTP_COOKIE => cookie('plainmember') );
    is( $code, 503, 'a signed-in account without the capability: 503' );

    ( $code, $ra, $j ) = $data->( HTTP_COOKIE => cookie('opmember') );
    is( $code, 200, 'the holder is answered' );
    ok( $j->{ok} && length( $j->{token} // '' ), '...with a token as always' );

    conf("maintenance: off\n");
    ( $code, $ra, $j ) = $data->( HTTP_COOKIE => cookie('plainmember') );
    is( $code, 200, 'off: the account without the capability is answered' );
};

done_testing;

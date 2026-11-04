#!/usr/bin/perl
# SM1309 (ruling 46, T-02): over WebDAV, a MOVE carries the moved path's rules
# to the destination (Acl::rekey_path), so it is held to the rule that will
# enclose them there, as a rule written there is. Without that, a member writes
# a rule admitting a non-member where nothing encloses it and moves the page
# inside the protected area, past the check set_permissions makes.
#
# With the fix reverted, the wide rule's MOVE answers 201 and the rule lands
# inside the area. The narrow rule's MOVE is the control.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);
use Lazysite::Private ();

sub dest { "http://host/dav$_[0]" }

sub acls {
    my ($s) = @_;
    open my $f, '<', "$s->{docroot}/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = <$f>;
    close $f;
    return decode_json( $j || '{}' );
}

sub set_acls {
    my ( $s, $h ) = @_;
    open my $f, '>', "$s->{docroot}/lazysite/auth/acls.json" or die $!;
    print $f encode_json($h);
    close $f;
}

my $s = setup_dav_site();
# The area's rule gates it, so its folder is in the private store (SM286).
make_path( Lazysite::Private::private_path( $s->{docroot}, 'content/area' ) );
for my $p (qw(/content/wide.md /content/narrow.md)) {
    is( run_dav( $s->{docroot}, 'PUT', $p, body => "P\n", HTTP_AUTHORIZATION => $s->{auth} )->{code},
        201, "$p is written" );
}
set_acls( $s, {
    'content/area'       => { owner => 'boss', read => [ 'deploy', 'boss' ] },
    'content/wide.md'    => { owner => 'deploy', read => [ 'deploy', 'outsider' ] },
    'content/narrow.md'  => { owner => 'deploy', read => ['deploy'] },
} );

subtest 'a rule admitting a non-member is not moved inside the area' => sub {
    my $r = run_dav( $s->{docroot}, 'MOVE', '/content/wide.md',
        HTTP_DESTINATION => dest('/content/area/wide.md'), HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'refused' ) or diag explain $r;
    like( $r->{body} // '', qr{the rule on 'content/area'}, 'naming the rule that would enclose it' );
    ok( acls($s)->{'content/wide.md'}, 'the rule stays where it was' );
    ok( !acls($s)->{'content/area/wide.md'}, 'and none landed inside the area' );
};

subtest 'a rule the area already admits moves (control)' => sub {
    my $r = run_dav( $s->{docroot}, 'MOVE', '/content/narrow.md',
        HTTP_DESTINATION => dest('/content/area/narrow.md'), HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 201, 'moved' ) or diag explain $r;
    ok( acls($s)->{'content/area/narrow.md'}, 'with its rule' );
};

done_testing;

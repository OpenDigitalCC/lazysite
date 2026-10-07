#!/usr/bin/perl
# SM960: a custom auth header name is honoured only from a trusted proxy.
#
# auth_header_user (and _name, _email, _groups) rename the identity headers for a
# proxy - the docs' example is Remote-User. The trust gate stripped only the fixed
# X-Remote-* names, so with a custom name configured and no auth_proxy_trusted, a
# visitor sending `Remote-User: alice` passed a page gate - and behind the built-in
# auth wrapper too, which vouches for X-Remote-* alone.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site run_processor site_tempdir);

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    setup_auth_site($d);
    my $conf = "$d/lazysite/lazysite.conf";
    open my $in, '<', $conf or die $!;
    my $t = do { local $/; <$in> };
    close $in;
    $t =~ s/^auth_proxy_trusted:.*\n//mg;
    $t .= "auth_header_user: Remote-User\nauth_header_groups: Remote-Groups\n";
    $t .= "auth_proxy_trusted: true\n" if $o{proxy};
    open my $out, '>', $conf or die $!;
    print {$out} $t;
    close $out;
    return $d;
}

my %spoof = ( HTTP_REMOTE_USER => 'alice', HTTP_REMOTE_GROUPS => 'admins' );

subtest 'no trusted proxy: a visitor\'s Remote-User does not open a gate' => sub {
    my $out = run_processor( site(), '/protected', %spoof, LAZYSITE_AUTH_TRUSTED => undef );
    like( $out, qr/Status: 302/, 'redirected to sign in, not served' )
        or diag( substr( $out, 0, 300 ) );
};

subtest 'behind the auth wrapper: the wrapper vouches for X-Remote-* only' => sub {
    my $out = run_processor( site(), '/admins-only', %spoof, LAZYSITE_AUTH_TRUSTED => 1 );
    unlike( $out, qr/Status: 200/, 'a custom header the visitor sent is not an identity' )
        or diag( substr( $out, 0, 300 ) );
};

subtest 'a trusted proxy may supply it' => sub {
    my $out = run_processor( site( proxy => 1 ), '/admins-only', %spoof );
    like( $out, qr/Status: 200/, 'with auth_proxy_trusted: true the custom header is honoured' )
        or diag( substr( $out, 0, 300 ) );
};

done_testing();

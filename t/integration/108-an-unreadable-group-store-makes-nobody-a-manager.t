#!/usr/bin/perl
# SM906 T3 follow-up: the render path's copy of "does any group grant manager
# access?" fails closed.
#
# lazysite-processor.pl keeps a module-free copy (ADR 0001). It answered 0 -
# "unsecured site, every signed-in user is a manager" - when groups-settings.json
# existed but could not be opened, or did not decode. So a permissions slip or a
# truncated write turned every signed-in account into an operator on the manager
# pages. SM906 T3 fixed the API's copy; this is the processor's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor site_tempdir);

sub site {
    my ($settings) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/layouts/default", "$d/lazysite/auth" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c "site_name: T\nlayout: default\nmanager: enabled\nauth_proxy_trusted: true\n";
    close $c;
    open my $l, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
    print $l '<html><body>[% content %]</body></html>';
    close $l;
    open my $gs, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print $gs $settings;
    close $gs;
    return $d;
}
my $GOOD  = '{"admins":{"label":"Admins","ui":1},"mcp":{"label":"MCP","mcp":1}}';
my %botty = ( HTTP_X_REMOTE_USER => 'botty', HTTP_X_REMOTE_GROUPS => 'mcp' );

subtest 'the control: a readable store keeps a non-manager out' => sub {
    like( run_processor( site($GOOD), '/manager/', %botty ), qr/Status: 403/, '403' );
};

SKIP: {
    skip 'running as root: chmod 000 does not refuse root', 1 if $> == 0;
    subtest 'an unreadable store keeps a non-manager out' => sub {
        my $d = site($GOOD);
        chmod 0, "$d/lazysite/auth/groups-settings.json";
        my $out = run_processor( $d, '/manager/', %botty );
        chmod 0644, "$d/lazysite/auth/groups-settings.json";
        like( $out, qr/Status: 403/, 'still 403 - not "unsecured, so everybody is a manager"' )
            or diag( substr( $out, 0, 300 ) );
    };
}

subtest 'a store that does not decode keeps a non-manager out' => sub {
    my $out = run_processor( site('{"admins":{"label":"Admins","ui":1'), '/manager/', %botty );
    like( $out, qr/Status: 403/, 'a truncated store is not an unsecured site' )
        or diag( substr( $out, 0, 300 ) );
};

done_testing();

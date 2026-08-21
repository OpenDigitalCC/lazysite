#!/usr/bin/perl
# SM436: a domain registered under a name no request can carry serves the
# WRONG SITE, silently, for as long as nobody follows a link.
#
# The incident: a domain registered as `dhcf` with site_url
# https://dhcf.sites.lazysite.io. The processor matches the FULL Host header
# with eq, so `dhcf` never matched, no alias overlay applied, and every
# request fell through to the primary - serving a different organisation's
# site under that name.
#
# What made it expensive is that every diagnostic agreed the config was fine:
# domain-preview renders correctly because it feeds the STORED key back as the
# Host, domains-list shows a complete record, and domain-check blamed DNS
# because it faithfully resolved the literal string. Only following a real
# request showed it.
#
# Both halves of the answer were already in the row - the host, and the
# hostname inside its own site_url. Comparing them costs one regex.
#
# REGISTRATION IS THE ONLY MOMENT: `host` is not in @DOMAIN_KEYS, so
# domain_set cannot correct it, and there is no rename verb. A value that
# cannot be edited afterwards has exactly one chance to be right.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Common  ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: Primary\nsite_url: \${REQUEST_SCHEME}://\${SERVER_NAME}\n";
    close $c;
    $Lazysite::Manager::Domains::DOCROOT = $d;
    $Lazysite::Manager::Common::DOCROOT  = $d;
    return $d;
}

subtest 'a single-label host is refused' => sub {
    fixture();
    my $r = Lazysite::Manager::Domains::domain_add( 'dhcf',
        site_url => 'https://dhcf.sites.lazysite.io', content_root => 'sites/dhcf' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    like( $r->{error}, qr/at least one dot/, 'saying why' );
    like( $r->{error}, qr/dhcf\.example\.com/, 'and showing the shape wanted' )
        or diag( 'A refusal an operator cannot act on just moves the problem.' );
};

subtest 'a host disagreeing with its own site_url is refused' => sub {
    fixture();
    my $r = Lazysite::Manager::Domains::domain_add( 'dhcf.example.com',
        site_url => 'https://other.example.com' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/other\.example\.com/, 'naming the host in the URL' );
    like( $r->{error}, qr/never matches|default site/, 'and the consequence' );
};

subtest 'a correct registration is accepted' => sub {
    # Without this the checks could refuse everything and still pass above.
    my $d = fixture();
    my $r = Lazysite::Manager::Domains::domain_add( 'dhcf.sites.lazysite.io',
        site_url => 'https://dhcf.sites.lazysite.io', content_root => 'sites/dhcf' );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    ok( -d "$d/sites/dhcf", 'and the content root is provisioned' );
};

subtest 'a placeholder site_url names no host and cannot disagree' => sub {
    fixture();
    my $r = Lazysite::Manager::Domains::domain_add( 'x.example.com',
        site_url => '${REQUEST_SCHEME}://${SERVER_NAME}' );
    ok( $r->{ok}, 'the full-placeholder form is accepted' ) or diag explain $r;

    # THE FORM THAT ACTUALLY EXERCISES THE GUARD. The line above does not:
    # it does not begin http(s)://, so the host-extracting regex fails and the
    # check returns undef whether the ${ guard is there or not. Removing the
    # guard passed that assertion cleanly. THIS one begins with a real scheme,
    # so without the guard '${SERVER_NAME}' is extracted as a hostname and
    # compared, and a legitimate registration is refused.
    fixture();
    my $r2 = Lazysite::Manager::Domains::domain_add( 'w.example.com',
        site_url => 'https://${SERVER_NAME}' );
    ok( $r2->{ok}, 'and so is a scheme-plus-placeholder site_url' )
        or diag explain $r2;
};

subtest 'no site_url at all is still fine' => sub {
    fixture();
    my $r = Lazysite::Manager::Domains::domain_add('y.example.com');
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
};

subtest 'domain_set refuses a site_url that would disagree' => sub {
    fixture();
    Lazysite::Manager::Domains::domain_add( 'z.example.com',
        site_url => 'https://z.example.com' );
    my $r = Lazysite::Manager::Domains::domain_set( 'z.example.com',
        'site_url', 'https://somewhere-else.example.com' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    like( $r->{error}, qr/somewhere-else/, 'naming the mismatch' );
};

subtest 'but domain_set does NOT apply the dot check to an existing row' => sub {
    # An already-registered dotless host cannot be corrected - host is not
    # settable and there is no rename - so answering a site_url edit with
    # "register the full name" would misdirect. Removal is the only route,
    # and domain_remove must keep working on exactly these rows.
    my $d = fixture();
    open my $c, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "alias_hosts: legacy\nalias.legacy.site_url: https://legacy.example.com\n";
    close $c;

    my $r = Lazysite::Manager::Domains::domain_set( 'legacy', 'site_url',
        'https://legacy.example.com' );
    unlike( ( $r->{error} // '' ), qr/at least one dot/,
        'the registration message is not shown for an edit' );

    my $rm = Lazysite::Manager::Domains::domain_remove('legacy');
    ok( $rm->{ok}, 'and a bad row can still be REMOVED' )
        or diag( 'Tightening the shared _valid_host would have stranded every '
            . 'existing bad row, unremovable by the verb that removes them.' );
};

done_testing();

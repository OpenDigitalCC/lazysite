#!/usr/bin/perl
# SM070: COPY and MOVE.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

sub dest { "http://host/dav$_[0]" }

# --- COPY duplicates ---------------------------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/src.md', body => "data", HTTP_AUTHORIZATION => $a );

    my $r = run_dav( $s->{docroot}, 'COPY', '/content/src.md',
        HTTP_DESTINATION => dest('/content/dup.md'), HTTP_AUTHORIZATION => $a );
    is( $r->{code}, 201, 'COPY to new dest => 201' );
    ok( -f "$s->{docroot}/content/src.md", 'source remains' );
    ok( -f "$s->{docroot}/content/dup.md", 'copy created' );
}

# --- MOVE renames ------------------------------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/m.md', body => "data", HTTP_AUTHORIZATION => $a );

    my $r = run_dav( $s->{docroot}, 'MOVE', '/content/m.md',
        HTTP_DESTINATION => dest('/content/moved.md'), HTTP_AUTHORIZATION => $a );
    is( $r->{code}, 201, 'MOVE to new dest => 201' );
    ok( !-e "$s->{docroot}/content/m.md", 'source gone after MOVE' );
    ok( -f "$s->{docroot}/content/moved.md", 'destination present after MOVE' );
}

# --- Overwrite: F protects an existing destination --------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/s.md', body => "a", HTTP_AUTHORIZATION => $a );
    run_dav( $s->{docroot}, 'PUT', '/content/exists.md', body => "b", HTTP_AUTHORIZATION => $a );

    my $r = run_dav( $s->{docroot}, 'COPY', '/content/s.md',
        HTTP_DESTINATION => dest('/content/exists.md'),
        HTTP_OVERWRITE   => 'F', HTTP_AUTHORIZATION => $a );
    is( $r->{code}, 412, 'COPY with Overwrite:F onto existing => 412' );
}

# --- Destination host/prefix validation -------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/s.md', body => "a", HTTP_AUTHORIZATION => $a );

    # Destination outside the /dav mount is rejected.
    my $bad = run_dav( $s->{docroot}, 'COPY', '/content/s.md',
        HTTP_DESTINATION => 'http://host/elsewhere/x.md', HTTP_AUTHORIZATION => $a );
    is( $bad->{code}, 400, 'destination outside /dav mount => 400' );
}

# --- Destination scope enforcement ------------------------------------
{
    my $s = setup_dav_site( scope => '/content' );
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/s.md', body => "a", HTTP_AUTHORIZATION => $a );

    my $r = run_dav( $s->{docroot}, 'MOVE', '/content/s.md',
        HTTP_DESTINATION => dest('/outside.md'), HTTP_AUTHORIZATION => $a );
    is( $r->{code}, 403, 'MOVE to a destination outside scope => 403' );
}

# --- COPY invalidates destination cache -------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/s.md', body => "a", HTTP_AUTHORIZATION => $a );
    open my $cf, '>', "$s->{docroot}/content/dest.html"; print $cf "<html>"; close $cf;
    run_dav( $s->{docroot}, 'COPY', '/content/s.md',
        HTTP_DESTINATION => dest('/content/dest.md'), HTTP_AUTHORIZATION => $a );
    ok( !-e "$s->{docroot}/content/dest.html", 'COPY drops stale dest cache' );
}

done_testing();

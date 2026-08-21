#!/usr/bin/perl
# SM443: saving a domain's nav must never silently write the SHARED nav.
#
# The incident, on a live instance: an operator set the xisl domain's
# nav_file, confirmed it with nav-read (inherited: 0), called nav-save naming
# that host, got ok - and the NEIGHBOURING site's navigation was replaced. The
# neighbour was a site handed to another party that morning.
#
# The host had travelled in the QUERY string while nav-save read it from the
# BODY, so $host arrived empty and _nav_conf_path('') resolved to the shared
# lazysite/nav.conf. The audit trail did not catch it and instead corroborated
# the mistake: _audit_implicit_target reads the query host, so the log recorded
# "nav (xisl...)" for a write that went to the primary's file.
#
# Two halves, both asserted here. The plumbing (host is read from either
# place) and - the one that matters - that an absent or unusable host does NOT
# mean "the shared file". A refusal would have turned the incident into a
# message.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Nav     ();
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Themes  ();

my $BASE_MARKER = "Home | /\n";

sub fixture {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    # The save clears the render cache via Themes::action_cache_invalidate,
    # which walks the docroot - so the fixture needs the dirs it expects, or
    # File::Find dies on an invalid top directory and the subtest reports
    # "no tests run" rather than anything about nav.
    make_path( "$d/lazysite", "$d/lazysite/cache", "$d/content" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} $conf;
    close $c;
    open my $n, '>', "$d/lazysite/nav.conf" or die $!;
    print {$n} $BASE_MARKER;
    close $n;
    $Lazysite::Manager::Nav::DOCROOT       = $d;
    $Lazysite::Manager::Nav::LAZYSITE_DIR  = "$d/lazysite";
    $Lazysite::Manager::Domains::DOCROOT   = $d;
    $Lazysite::Manager::Themes::DOCROOT      = $d;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    return $d;
}

sub base_nav { open my $f, '<', "$_[0]/lazysite/nav.conf" or die $!; local $/; <$f> }

my $CONF = <<'CONF';
site_name: Primary
alias_hosts: own.example, shares.example
alias.own.example.nav_file: lazysite/nav-own.conf
alias.own.example.content_root: sites/own
alias.shares.example.content_root: sites/shares
CONF

my @ITEMS = ( { label => 'Replaced', url => '/replaced' } );

subtest 'a domain with its OWN nav file writes that file' => sub {
    my $d = fixture($CONF);
    my $r = Lazysite::Manager::Nav::action_nav_save( \@ITEMS, 'own.example' );
    ok( $r->{ok}, 'the save succeeds' ) or diag explain $r;
    ok( -f "$d/lazysite/nav-own.conf", 'its own file is written' );
    is( base_nav($d), $BASE_MARKER, 'and the SHARED nav is untouched' )
        or diag( 'This is the incident: a per-domain save reaching the '
            . "primary's file and every domain inheriting it." );
};

subtest 'a domain that INHERITS is refused, not silently shared' => sub {
    my $d = fixture($CONF);
    my $r = Lazysite::Manager::Nav::action_nav_save( \@ITEMS, 'shares.example' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind}, 'inherits-nav', 'and says why' );
    like( $r->{error}, qr/nav_file/, 'pointing at the fix' );
    is( base_nav($d), $BASE_MARKER, 'the shared nav is untouched' )
        or diag( 'Saving a domain that inherits would rewrite the primary '
            . 'and every other inheriting domain - never what the caller meant.' );
};

subtest 'an UNREGISTERED host is refused, not treated as the primary' => sub {
    # The incident shape: a host that does not resolve must not fall through
    # to the shared file.
    my $d = fixture($CONF);
    my $r = Lazysite::Manager::Nav::action_nav_save( \@ITEMS, 'typo.example' );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'unknown-domain', 'named as an unknown domain' );
    is( base_nav($d), $BASE_MARKER, 'the shared nav is untouched' );
};

subtest 'NO host still edits the primary - deliberately' => sub {
    # The legitimate case must keep working, or the refusal has just moved the
    # damage to whoever edits the primary's nav.
    my $d = fixture($CONF);
    my $r = Lazysite::Manager::Nav::action_nav_save( \@ITEMS, undef );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    isnt( base_nav($d), $BASE_MARKER, 'and the shared nav IS written' );

    my $d2 = fixture($CONF);
    my $r2 = Lazysite::Manager::Nav::action_nav_save( \@ITEMS, '(default)' );
    ok( $r2->{ok}, '(default) means the primary too' );
    isnt( base_nav($d2), $BASE_MARKER, 'and writes it' );
};

subtest 'the dispatcher reads host from the QUERY as well as the body' => sub {
    # The plumbing half. nav-read declares host in the query; nav-save
    # declared it only in the body, so passing it consistently lost it.
    my $api = "$FindBin::Bin/../../../lazysite-manager-api.pl";
    plan skip_all => 'api missing' unless -f $api;
    open my $fh, '<', $api or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    like( $src, qr/action_nav_save\(\s*\$req->\{items\}[^;]*\$params\{host\}/s,
        'nav-save takes host from $params as well as the body' )
        or diag( 'Declared query_or_body but still read only from the body '
            . 'would leave the trap exactly where it was.' );

    my $acts = "$FindBin::Bin/../../../lib/Lazysite/ControlApi/Actions.pm";
    open my $af, '<', $acts or die $!;
    my $asrc = do { local $/; <$af> };
    close $af;
    like( $asrc, qr/'nav-save'.*?name => 'host', in => 'query_or_body'/s,
        'and the declaration says so' );
};

done_testing();

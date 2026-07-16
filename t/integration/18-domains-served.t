#!/usr/bin/perl
# SM154 (P2) end-to-end: a domain registered through the engine
# (Lazysite::Manager::Domains, i.e. the manager domain-add action / the CLI) is
# actually SERVED by the SM151 processor under its Host header - proving the
# admin plane and the serving plane agree. The engine only writes the lazysite
# side (conf + content root); the Host routing is SM151's, unchanged.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                 qw(run_processor);
use Lazysite::Manager::Domains qw(domain_add domain_add_alias domain_remove);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Agency\n";
close $cf;

# Primary content (the default host).
open my $ph, '>', "$docroot/index.md" or die $!;
print $ph "---\ntitle: Agency Home\n---\n\nAGENCY-PRIMARY\n";
close $ph;

# Register a client domain via the engine, seeded.
$Lazysite::Manager::Domains::DOCROOT = $docroot;
my $r = domain_add( 'clienta.com',
    content_root => 'sites/clienta', site_name => 'Client A', seed => 1 );
ok( $r->{ok}, 'engine registered clienta.com' ) or diag explain $r;

# Give the client domain a distinctive index page.
open my $ch, '>', "$docroot/sites/clienta/index.md" or die $!;
print $ch "---\ntitle: Client A Home\n---\n\nCLIENT-A-CONTENT\n";
close $ch;

# --- the registered domain serves ITS content root under its Host -----------
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clienta.com' );
    like( $out, qr/CLIENT-A-CONTENT/, 'clienta.com serves its own content root' );
    unlike( $out, qr/AGENCY-PRIMARY/, 'clienta.com does NOT serve the primary content' );
}

# --- the primary host still serves the docroot root -------------------------
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'agency.example' );
    like( $out, qr/AGENCY-PRIMARY/, 'the default host serves the primary content' );
    unlike( $out, qr/CLIENT-A-CONTENT/, 'the default host does not serve a client subtree' );
}

# --- SM155: an alias host serves the canonical domain's content -------------
{
    my $al = domain_add_alias( 'www.clienta.com', 'clienta.com' );
    ok( $al->{ok}, 'engine added www.clienta.com as an alias of clienta.com' )
        or diag explain $al;
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'www.clienta.com' );
    like( $out, qr/CLIENT-A-CONTENT/, 'the alias host serves the canonical content' );
    unlike( $out, qr/AGENCY-PRIMARY/, 'the alias does not serve the primary content' );
    domain_remove('www.clienta.com');
}

# --- after removal, the host no longer routes to the client root ------------
{
    my $rm = domain_remove('clienta.com');
    ok( $rm->{ok}, 'engine removed clienta.com' );
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clienta.com' );
    unlike( $out, qr/CLIENT-A-CONTENT/, 'an unregistered host no longer serves the client root' );
}

done_testing();

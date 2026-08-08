#!/usr/bin/perl
# SM257: a tool whose whole purpose is verification must not report success
# without verifying.
#
# domain_preview exists so an operator or agent can check a domain BEFORE DNS or
# TLS point at it. It used to shell the processor with 2>/dev/null, never look at
# the exit status, and return ok:1 with whatever came back - so a dead processor,
# a response with no headers, an empty render and a good render were one answer.
# An agent confirming its own work was told "fine" in every case, and the
# operator found out when the DNS landed.
#
# The three failure modes are distinct faults with distinct fixes, so each is
# tested separately and must be distinguishable in the result.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/site";
make_path( "$base/cgi-bin", "$d/lazysite", "$d/sites/clienta" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\nalias_hosts: shop.clienta.com\n"
    . "alias.shop.clienta.com.content_root: sites/clienta\n";
close $cf;

$Lazysite::Manager::Domains::DOCROOT = $d;

# Install a stand-in processor, so each case can supply one that fails in
# exactly one way. NB: processor_path() takes only the DIRECTORY from
# LAZYSITE_PROCESSOR and always appends lazysite-processor.pl, so the stand-in
# has to carry that exact name - pointing the variable at a differently-named
# script silently gets you the real path instead.
sub with_processor {
    my ( $body, $code ) = @_;
    my $p = "$base/cgi-bin/lazysite-processor.pl";
    open my $fh, '>', $p or die $!;
    print {$fh} "#!/usr/bin/perl\nuse strict; use warnings;\n$body\n";
    close $fh;
    chmod 0755, $p;
    local $ENV{LAZYSITE_PROCESSOR} = $p;
    return $code->();
}

# --- a processor that dies ---------------------------------------------------
{
    my $r = with_processor(
        'print STDERR "template parse error at line 12\n"; exit 2;',
        sub { Lazysite::Manager::Domains::domain_preview('shop.clienta.com') } );
    ok( !$r->{ok}, 'a processor that exits non-zero is a FAILED preview' );
    is( $r->{kind}, 'render-failed', 'reported as render-failed' );
    like( $r->{error}, qr/exit 2/, 'the exit status is named' );
    like( $r->{error}, qr/template parse error/,
        'and its stderr is carried through - the diagnostic used to be discarded '
            . 'by 2>/dev/null, which is what made this unfixable from the outside' );
}

# --- a processor that emits no CGI headers -----------------------------------
{
    my $r = with_processor(
        'print "just some text with no header block";',
        sub { Lazysite::Manager::Domains::domain_preview('shop.clienta.com') } );
    ok( !$r->{ok}, 'a response with no CGI header block is a failure' );
    is( $r->{kind}, 'no-cgi-headers', 'distinct from a render that failed' );
    like( $r->{error}, qr/just some text/,
        'the unexpected output is shown, since that is the clue to the cause' );
}

# --- a processor that returns headers and nothing else -----------------------
{
    my $r = with_processor(
        'print "Content-Type: text/html\r\n\r\n";',
        sub { Lazysite::Manager::Domains::domain_preview('shop.clienta.com') } );
    ok( !$r->{ok}, 'headers with an empty body is a failure, not a blank page' );
    is( $r->{kind}, 'empty-render', 'distinct from both other faults' );
    like( $r->{error}, qr/content_root/,
        'and points at the likely cause rather than only stating the symptom' );
}

# --- a processor that renders --------------------------------------------------
{
    my $r = with_processor(
        'print "Content-Type: text/html\r\n\r\n<html><body>Client A</body></html>";',
        sub { Lazysite::Manager::Domains::domain_preview('shop.clienta.com') } );
    ok( $r->{ok}, 'a real render succeeds' ) or diag( $r->{error} // '' );
    is( $r->{host}, 'shop.clienta.com', 'and names the host' );
    like( $r->{html}, qr/Client A/, 'and carries the body' );
    unlike( $r->{html}, qr/Content-Type/, 'with the CGI headers stripped' );
}

# --- the refusals that came BEFORE the render are unchanged ------------------
# These already worked; pinned so the new failure branches cannot swallow them.
{
    my $bad = Lazysite::Manager::Domains::domain_preview('not a host');
    ok( !$bad->{ok}, 'an invalid host is still refused' );
    like( $bad->{error}, qr/Invalid domain host/, 'with the original message' );

    my $unreg = Lazysite::Manager::Domains::domain_preview('nope.example');
    ok( !$unreg->{ok}, 'an unregistered host is still refused' );
    like( $unreg->{error}, qr/Not a registered domain/, 'with the original message' );
}

done_testing();

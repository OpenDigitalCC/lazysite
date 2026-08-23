#!/usr/bin/perl
# GS11 (SM492): the BUILD names an unclosed component fence.
#
# Before: an unbalanced `::: hero` was left in the page as text, silently.
# The page showed ':::hero' and the build log showed nothing. Now the build
# logs a WARN naming the component and the body line, so an operator reading
# the error log finds the cause beside the symptom. run_processor discards
# stderr, so this test runs the processor itself and keeps it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(processor_path run_processor);

my $docroot = tempdir( CLEANUP => 1 );
my $cdir    = "$docroot/lazysite/layouts/nova/components";
make_path($cdir);
open my $lf, '>', "$docroot/lazysite/layouts/nova/layout.tt" or die $!;
print {$lf} "<!DOCTYPE html><html><body><main>[% content %]</main></body></html>\n";
close $lf;
open my $hf, '>', "$cdir/hero.tt" or die $!;
print {$hf} qq{<section class="hero">[% content %]</section>\n};
close $hf;
open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$conf} "site_name: Test\nlayout: nova\n";
close $conf;
open my $pf, '>', "$docroot/open.md" or die $!;
print {$pf} "---\ntitle: Open\n---\nIntro.\n\n::: hero\n# Big\n\nnever closed\n";
close $pf;

sub build_with_stderr {
    my ($uri) = @_;
    my $err = "$docroot/stderr.txt";
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $docroot;
    $ENV{REDIRECT_URL}   = $uri;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{QUERY_STRING}   = '';
    my $proc = processor_path();
    my $out  = qx($^X \Q$proc\E 2>\Q$err\E);
    open my $eh, '<', $err or die $!;
    my $e = do { local $/; <$eh> };
    close $eh;
    return ( $out, $e );
}

my ( $html, $stderr ) = build_with_stderr('/open');
like( $html, qr{::: hero}, 'the symptom: the unbalanced fence is left on the page as text' );
like( $stderr, qr{WARN.*component fence never closed}, 'the cause: the build logs a WARN' )
    or diag("stderr was:\n$stderr");
like( $stderr, qr{component=hero}, 'naming the component' );
like( $stderr, qr{body_line=3},    'and the body line it was opened on' );
unlike( $stderr, qr{render failed}, 'and does not pretend it tried to render it' );

done_testing;

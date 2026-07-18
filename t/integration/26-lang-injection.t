#!/usr/bin/perl
# SEC / SM179 (F6.10): a page's front-matter `lang:` is content-partner
# controllable and lands in <html lang="..."> and the Content-Language header.
# It MUST be sanitised to a bare language tag so a content-only write cannot
# inject markup (stored XSS) or a response-header line (CRLF injection).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

sub site {
    my ($lang) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c "site_name: T\n";
    close $c;
    open my $p, '>', "$d/index.md" or die $!;
    print $p "---\ntitle: Home\nlang: $lang\n---\n\nhi\n";
    close $p;
    return $d;
}

# --- stored XSS attempt via the front-matter lang -----------------------------
my $out = run_processor( site(q{en"><script>alert(document.domain)</script>}), '/' );
unlike( $out, qr/<script>alert/,
    'a malicious front-matter lang does NOT inject a live <script> element' );
unlike( $out, qr/lang="en">/,
    'the injected "> does not break out of the lang attribute' );
like( $out, qr/<html lang="[A-Za-z-]+">/,
    'the rendered lang is a bare tag (letters + hyphen only)' );

# --- CRLF / header-injection attempt ------------------------------------------
# A CR/LF in the lang must not add a Content-Language header line or any header.
$out = run_processor( site("en\r\nX-Injected: 1"), '/' );
unlike( $out, qr/X-Injected/, 'a CRLF in lang cannot inject a response header' );
my ($cl) = $out =~ /^(Content-Language:[^\r\n]*)/m;
like( $cl // '', qr/^Content-Language:\s*[A-Za-z-]+\s*$/,
    'Content-Language is a single clean line (no CRLF-smuggled content)' );

# --- a legitimate tag with a region still works -------------------------------
$out = run_processor( site('pt-BR'), '/' );
like( $out, qr/<html lang="pt-BR">/, 'a legitimate BCP-47 tag (pt-BR) is preserved' );

done_testing;

#!/usr/bin/perl
# SM179 P1: language awareness. A site declares its language with `lang:` (base
# conf or a per-host alias override); a page may override it in front matter. The
# rendered <html lang> and the Content-Language header reflect it; default is en.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

sub site {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c ( $o{conf} // "site_name: T\n" );
    close $c;
    open my $p, '>', "$d/index.md" or die $!;
    print $p ( $o{page} // "---\ntitle: Home\n---\n\nHello.\n" );
    close $p;
    return $d;
}

# --- default: en --------------------------------------------------------------
my $out = run_processor( site(), '/' );
like( $out, qr/<html lang="en">/,        'no lang set => <html lang="en">' );
like( $out, qr/Content-Language:\s*en/i, 'no lang set => Content-Language: en' );

# --- base conf lang: de -------------------------------------------------------
$out = run_processor( site( conf => "site_name: T\nlang: de\n" ), '/' );
like( $out, qr/<html lang="de">/,        'base lang: de => <html lang="de">' );
like( $out, qr/Content-Language:\s*de/i, 'base lang: de => Content-Language: de' );

# --- a page overrides the site language in front matter -----------------------
$out = run_processor(
    site( conf => "site_name: T\nlang: de\n",
        page => "---\ntitle: Home\nlang: fr\n---\n\nBonjour.\n" ),
    '/' );
like( $out, qr/<html lang="fr">/, 'page front-matter lang overrides the site lang' );

# --- a per-host alias sets its own language -----------------------------------
my $d = site( conf =>
        "site_name: T\nlang: en\nalias_hosts: de.example\nalias.de.example.lang: de\n" );
$out = run_processor( $d, '/', HTTP_HOST => 'de.example' );
like( $out, qr/<html lang="de">/, 'a per-host alias lang override applies' );
# the primary host is unaffected.
$out = run_processor( $d, '/', HTTP_HOST => 'primary.example' );
like( $out, qr/<html lang="en">/, 'the primary host keeps the base language' );

done_testing;

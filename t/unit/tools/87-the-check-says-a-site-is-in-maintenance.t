#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): `lazysite check` WARNS WHILE A SITE IS IN
# MAINTENANCE, so it is not forgotten - naming where (the whole instance, or which
# domains) and when it is expected back - and names a value the engine would read
# as off, and a maintenance page that would send visitors to a 404.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $tool" unless -f $tool;

sub site {
    my ( $conf, %o ) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/templates/system");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n$conf";
    close $fh;
    unless ( $o{no_page} ) {
        open my $p, '>', "$d/lazysite/templates/system/maintenance.md" or die $!;
        print {$p} "---\ntitle: M\n---\nIn maintenance.\n";
        close $p;
    }
    for my $f ( @{ $o{files} || [] } ) {
        open my $o, '>', "$d/$f" or die $!;
        print {$o} "x\n";
        close $o;
    }
    return $d;
}
sub run {
    my ($d) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

unlike( run( site('') ),                   qr/IN MAINTENANCE/, 'no key: nothing said' );
unlike( run( site("maintenance: off\n") ), qr/IN MAINTENANCE/, 'off: nothing said' );

my $inst = run( site("maintenance: on\n") );
like( $inst, qr/\[ warn \].*the site is IN MAINTENANCE for the whole instance/, 'on: warned, naming the instance' );
like( $inst, qr/switch it off on the Config page/, '...with what to do about it' );
unlike( $inst, qr/expected back/, '...and no time when none is set' );

my $until = run( site("maintenance: on\nmaintenance_until: 2026-11-01 18:30\n") );
like( $until, qr/expected back 2026-11-01 18:30 UTC/, 'the time it is expected back is named' );

my $dom = run( site("alias_hosts: a.example, b.example\nalias.a.example.maintenance: on\n") );
like( $dom, qr/IN MAINTENANCE for domain a\.example\b/, 'one domain: it is named' );
unlike( $dom, qr/domain b\.example|whole instance/, '...and its sibling and the instance are not' );

my $both = run( site("maintenance: on\nalias_hosts: a.example\nalias.a.example.maintenance: on\n") );
like( $both, qr/for the whole instance/, 'the instance switch covers the domain' );
unlike( $both, qr/domain a\.example/, '...so the domain is not listed beside it' );

my $odd = run( site("maintenance: yes please\n") );
like( $odd, qr/maintenance value the engine reads as OFF: maintenance/, 'a value the engine reads as off is named' );
unlike( $odd, qr/IN MAINTENANCE/, '...and the site is not claimed to be closed' );
my $oddd = run( site("alias_hosts: a.example\nalias.a.example.maintenance: sure\n") );
like( $oddd, qr/OFF: alias\.a\.example\.maintenance/, 'a domain\'s odd value is named too' );

my $nopage = run( site("maintenance: on\nmaintenance_page: /closed\n") );
like( $nopage, qr{maintenance page \(/closed\) does not resolve}, 'a page that is not there is named' );
unlike( run( site( "maintenance: on\nmaintenance_page: /closed\n", files => ['closed.md'] ) ), qr/does not resolve/, '...and a page that is there is not' );
unlike( run( site("maintenance: on\nmaintenance_page: https://status.example.com/down\n") ), qr/does not resolve/, 'an address elsewhere needs no local page' );
like( run( site( "maintenance: on\n", no_page => 1 ) ), qr{maintenance page \(/maintenance\) does not resolve}, 'the shipped default missing is named' );

done_testing();

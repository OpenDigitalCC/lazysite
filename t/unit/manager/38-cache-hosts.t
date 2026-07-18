#!/usr/bin/perl
# Per-alias-host page caches live in lazysite/cache/hosts/<host>/<page>.html, not
# beside the .md, so the docroot-only cache list never saw them - and a Files
# delete of them is (correctly) blocked as a reserved /lazysite/ path. action_cache_list
# now enumerates them (tagged with host), and action_cache_invalidate can clear a
# single host's copy surgically (so one language sub-site's cache drops without
# touching its siblings).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

# A language set: primary (en) + fr/th alias sub-domains, each its own root.
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $c <<'CONF';
site_name: T
content_root: sites/en
alias_hosts: fr.example, th.example
alias.fr.example.content_root: sites/fr
alias.th.example.content_root: sites/th
CONF
close $c;

# A primary mirror (beside its .md) and per-host caches under cache/hosts/.
make_path( "$docroot/sites/en", "$docroot/sites/fr", "$docroot/sites/th",
    "$docroot/lazysite/cache/hosts/fr.example",
    "$docroot/lazysite/cache/hosts/th.example" );
open my $m, '>', "$docroot/sites/en/index.md" or die $!; print $m "x"; close $m;
open my $h, '>', "$docroot/index.html"        or die $!; print $h "<p>en</p>"; close $h;
open my $s, '>', "$docroot/index.md"          or die $!; print $s "src"; close $s;
open my $fr, '>', "$docroot/lazysite/cache/hosts/fr.example/compare.html" or die $!;
print $fr "<p>fr</p>"; close $fr;
open my $th, '>', "$docroot/lazysite/cache/hosts/th.example/compare.html" or die $!;
print $th "<p>th</p>"; close $th;

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# --- the list now includes the per-host caches, tagged with host --------------
my $r = main::action_cache_list();
ok( $r->{ok}, 'cache-list ok' );
my %by_host;
for my $e ( @{ $r->{cached} } ) {
    push @{ $by_host{ $e->{host} // '(primary)' } }, $e->{path};
}
ok( ( grep { $_ eq '/index.html' } @{ $by_host{'(primary)'} } ), 'primary mirror listed' );
is_deeply( $by_host{'fr.example'}, ['/compare.html'], 'fr host cache listed with its host tag' );
is_deeply( $by_host{'th.example'}, ['/compare.html'], 'th host cache listed with its host tag' );

# --- per-host invalidate clears ONLY that host's copy -------------------------
my $inv = main::action_cache_invalidate( '/compare', 'fr.example' );
ok( $inv->{ok} && $inv->{cleared} == 1, 'per-host invalidate removed one file' );
ok( !-f "$docroot/lazysite/cache/hosts/fr.example/compare.html", 'fr copy gone' );
ok( -f "$docroot/lazysite/cache/hosts/th.example/compare.html",
    'th copy untouched - sibling languages are not collaterally cleared' );

# --- clear-all still wipes the whole host tree --------------------------------
main::action_cache_invalidate('*');
ok( !-d "$docroot/lazysite/cache/hosts/th.example"
        || !-f "$docroot/lazysite/cache/hosts/th.example/compare.html",
    'clear-all removes the remaining host caches' );

done_testing;

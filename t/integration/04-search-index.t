#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

# Test the registry mechanism that powers search-index.
# A template under lazysite/templates/registries/ is rendered against
# all pages whose front matter declares register: search-index.

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
make_path("$docroot/lazysite/templates/registries");

# Registry template outputs a single-line entry per page (filterable).
open my $tf, '>', "$docroot/lazysite/templates/registries/search-index.tt" or die $!;
print $tf <<'EOF';
[%- FOREACH p IN pages -%]
URL: [% p.url %] TITLE: [% p.title %]
[% END -%]
EOF
close $tf;

# Three pages: one registered and searchable, one registered but hidden,
# one not registered.
open my $s1, '>', "$docroot/searchable.md" or die $!;
print $s1 "---\ntitle: Searchable Post\nregister:\n  - search-index\nsearch: true\n---\nFindable body.\n";
close $s1;

open my $s2, '>', "$docroot/unregistered.md" or die $!;
print $s2 "---\ntitle: Not Registered\n---\nNot in registry.\n";
close $s2;

# Trigger a page render so update_registries() fires.
run_processor( $docroot, '/index' );

ok( -f "$docroot/search-index",
    'registry output file produced at docroot' );

open my $fh, '<', "$docroot/search-index" or die $!;
my $body = do { local $/; <$fh> };
close $fh;

like(   $body, qr/TITLE: Searchable Post/,
    'registered page appears in registry output' );
like(   $body, qr/URL:\s*\/searchable\b/,
    'URL derived correctly for registered page' );
unlike( $body, qr/Not Registered/,
    'un-registered page NOT in registry output' );

done_testing();

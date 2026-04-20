#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

# Create include target BEFORE loading processor.
open my $fh, '>', "$docroot/partial.md" or die $!;
print $fh "---\ntitle: Partial\n---\nPartial content.\n";
close $fh;

load_processor($docroot);

# --- absolute path include strips front matter and renders body ---
{
    my $meta = {};
    my $out  = main::convert_fenced_include(
        "::: include\n/partial.md\n:::\n",
        "$docroot/index.md",
        $meta,
    );
    like(   $out, qr/Partial content/, 'absolute include brings in body' );
    unlike( $out, qr/title: Partial/,   'front matter stripped' );
}

# --- missing file produces include-error span ---
{
    my $out = main::convert_fenced_include(
        "::: include\n/nonexistent.md\n:::\n",
        "$docroot/index.md",
        {},
    );
    like( $out, qr/class="include-error"/, 'missing file → include-error' );
}

# --- path traversal blocked ---
{
    my $out = main::convert_fenced_include(
        "::: include\n/../../../etc/passwd\n:::\n",
        "$docroot/index.md",
        {},
    );
    unlike( $out, qr/root:/,                'traversal not resolved' );
    like(   $out, qr/class="include-error"/, 'traversal → include-error span' );
}

# --- TT variable in path is deferred to second pass ---
{
    my $out = main::convert_fenced_include(
        "::: include\n[% feature.path %]\n:::\n",
        "$docroot/index.md",
        {},
    );
    like( $out, qr/\[% feature\.path %\]/, 'TT variable path preserved' );
    like( $out, qr/:::/,                    'fence preserved for second pass' );
}

# --- ttl modifier sets meta ttl ---
{
    my $meta = {};
    main::convert_fenced_include(
        "::: include ttl=300\n/partial.md\n:::\n",
        "$docroot/index.md",
        $meta,
    );
    is( $meta->{ttl}, 300, 'ttl=300 modifier sets meta ttl' );
}

# --- ttl modifier does not override front matter ttl ---
{
    my $meta = { ttl => 600 };
    main::convert_fenced_include(
        "::: include ttl=300\n/partial.md\n:::\n",
        "$docroot/index.md",
        $meta,
    );
    is( $meta->{ttl}, 600, 'existing ttl in meta not overridden' );
}

done_testing();

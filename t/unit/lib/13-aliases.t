#!/usr/bin/perl
# SM134: page alias redirects - the map maintenance (Lazysite::Aliases).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Aliases qw(index_page deindex_page lookup canonical_url_for);

# --- canonical URL derivation ---
is( canonical_url_for('foo/bar.md'),   '/foo/bar', 'nested page -> /foo/bar' );
is( canonical_url_for('foo/index.md'), '/foo',     'index -> its directory' );
is( canonical_url_for('index.md'),     '/',        'root index -> /' );
is( canonical_url_for('/a/b.md'),      '/a/b',     'leading slash tolerated' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");

# --- index + lookup (block list form) ---
my $body = "---\ntitle: Pricing\naliases:\n  - /old-pricing\n  - /plans\n---\n\nbody\n";
is( index_page( $d, 'pricing.md', $body ), 2, 'two aliases indexed' );
is( lookup( $d, '/old-pricing' ), '/pricing', 'alias resolves to canonical' );
is( lookup( $d, '/plans' ),       '/pricing', 'second alias resolves' );
is( lookup( $d, '/pricing' ),     undef,      'the canonical itself is not an alias' );
is( lookup( $d, '/nope' ),        undef,      'unknown path is not an alias' );

# --- inline list form ---
index_page( $d, 'about.md', "---\naliases: [/company, /who-we-are]\n---\nx" );
is( lookup( $d, '/company' ),    '/about', 'inline-form alias resolves' );
is( lookup( $d, '/who-we-are' ), '/about', 'inline-form second alias resolves' );

# --- trailing-slash normalisation on lookup ---
is( lookup( $d, '/plans/' ), '/pricing', 'trailing slash tolerated on lookup' );

# --- re-save with fewer aliases clears the removed one ---
index_page( $d, 'pricing.md', "---\naliases:\n  - /plans\n---\ny" );
is( lookup( $d, '/old-pricing' ), undef,      're-saving without an alias clears it' );
is( lookup( $d, '/plans' ),       '/pricing', 'kept alias still resolves' );

# --- a page cannot alias itself ---
index_page( $d, 'self.md', "---\naliases:\n  - /self\n---\nz" );
is( lookup( $d, '/self' ), undef, 'a self-referential alias is ignored' );

# --- external / unsafe targets are rejected at parse ---
index_page( $d, 'bad.md', "---\naliases:\n  - https://evil.com\n  - //evil.com\n  - /ok\n  - /a/../b\n---\nq" );
is( lookup( $d, '/ok' ), '/bad', 'a site-local alias is kept' );
ok( !defined lookup( $d, 'https://evil.com' ), 'an absolute external URL is not indexed' );

# --- collision: last writer wins, keeps a single mapping ---
index_page( $d, 'one.md', "---\naliases:\n  - /shared\n---\n1" );
index_page( $d, 'two.md', "---\naliases:\n  - /shared\n---\n2" );
is( lookup( $d, '/shared' ), '/two', 'a contested alias resolves to the last writer' );

# --- delete removes a page's aliases ---
deindex_page( $d, 'pricing.md' );
is( lookup( $d, '/plans' ), undef, 'deleting a page clears its aliases' );

done_testing();

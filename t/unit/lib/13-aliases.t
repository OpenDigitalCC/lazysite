#!/usr/bin/perl
# SM134: page alias redirects - the map maintenance (Lazysite::Aliases).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Aliases
    qw(index_page deindex_page lookup canonical_url_for list_aliases
       reindex_move reindex_copy alias_map_path);

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

# === SM134 follow-ups ========================================================

# --- aliases_temp: 302 entries, stored as { target, code } -------------------
sub read_map {
    open my $mf, '<', alias_map_path($d) or return {};
    my $raw = do { local $/; <$mf> };
    close $mf;
    return JSON::PP::decode_json($raw);
}

is( index_page( $d, 'sale.md', "---\naliases_temp:\n  - /offer\n---\nx" ),
    1, 'a temporary alias is indexed' );
is( lookup( $d, '/offer' ), '/sale', 'lookup still returns the target string for a 302 entry' );
is_deeply( read_map()->{'/offer'}, { target => '/sale', code => 302 },
    'a 302 entry is stored as { target, code }' );

# inline form works for aliases_temp too
index_page( $d, 'promo.md', "---\naliases_temp: [/deal]\n---\nx" );
is( lookup( $d, '/deal' ), '/promo', 'inline-form temporary alias resolves' );

# --- mixed 301 + 302 on one page ---------------------------------------------
is( index_page( $d, 'mix.md', "---\naliases:\n  - /perm\naliases_temp:\n  - /temp\n---\nx" ),
    2, 'mixed page indexes both kinds' );
is( read_map()->{'/perm'}, '/mix', 'the permanent entry keeps the plain-string 301 shape' );
is_deeply( read_map()->{'/temp'}, { target => '/mix', code => 302 },
    'the temporary entry carries code 302' );

# the same path under both keys: aliases_temp wins (documented tie-break)
index_page( $d, 'both.md', "---\naliases:\n  - /twice\naliases_temp:\n  - /twice\n---\nx" );
is_deeply( read_map()->{'/twice'}, { target => '/both', code => 302 },
    'a path listed under both keys resolves as temporary (302)' );

# --- re-save clears BOTH shapes (deindex sees hash entries) ------------------
index_page( $d, 'mix.md', "---\ntitle: no more aliases\n---\ny" );
is( lookup( $d, '/perm' ), undef, 're-save cleared the 301 entry' );
is( lookup( $d, '/temp' ), undef, 're-save cleared the 302 entry' );

# --- backward compat: an old-format (plain string) map entry stays 301 -------
{
    open my $mf, '>', alias_map_path($d) or die $!;
    print $mf '{"/legacy":"/pricing","/tmp-alias":{"target":"/pricing","code":302}}';
    close $mf;
    is( lookup( $d, '/legacy' ),    '/pricing', 'an old-format entry still resolves' );
    is( lookup( $d, '/tmp-alias' ), '/pricing', 'a new-format entry resolves the same way' );
    is_deeply( list_aliases($d),
        [ { alias => '/legacy',    target => '/pricing', code => 301 },
          { alias => '/tmp-alias', target => '/pricing', code => 302 } ],
        'list_aliases: sorted rows with normalised codes' );
}

# --- reindex_move: a rename re-keys the entries without a save ---------------
{
    my $md = tempdir( CLEANUP => 1 );
    make_path("$md/lazysite");
    open my $pf, '>', "$md/old.md" or die $!;
    print $pf "---\naliases:\n  - /was\naliases_temp:\n  - /shortly\n---\nx";
    close $pf;
    index_page( $md, 'old.md', "---\naliases:\n  - /was\naliases_temp:\n  - /shortly\n---\nx" );
    is( lookup( $md, '/was' ), '/old', 'alias points at the original location' );

    rename "$md/old.md", "$md/new.md" or die $!;
    reindex_move( $md, 'old.md', 'new.md' );
    is( lookup( $md, '/was' ),      '/new', 'reindex_move re-targets the 301 alias' );
    is( lookup( $md, '/shortly' ),  '/new', 'reindex_move re-targets the 302 alias' );

    # a whole-directory move re-keys every page beneath it
    make_path("$md/docs");
    open my $df, '>', "$md/docs/a.md" or die $!;
    print $df "---\naliases:\n  - /a-old\n---\nx";
    close $df;
    index_page( $md, 'docs/a.md', "---\naliases:\n  - /a-old\n---\nx" );
    rename "$md/docs", "$md/guides" or die $!;
    reindex_move( $md, 'docs', 'guides' );
    is( lookup( $md, '/a-old' ), '/guides/a', 'directory move re-keys pages beneath it' );

    # a .md renamed away from .md loses its aliases
    rename "$md/new.md", "$md/new.txt" or die $!;
    reindex_move( $md, 'new.md', 'new.txt' );
    is( lookup( $md, '/was' ), undef, 'renaming away from .md drops the aliases' );
}

# --- reindex_copy: the duplicate is indexed (last writer wins) ---------------
{
    my $cd = tempdir( CLEANUP => 1 );
    make_path("$cd/lazysite");
    my $body = "---\naliases:\n  - /moved\n---\nx";
    open my $sf, '>', "$cd/src.md" or die $!;
    print $sf $body;
    close $sf;
    index_page( $cd, 'src.md', $body );
    open my $cf2, '>', "$cd/dup.md" or die $!;
    print $cf2 $body;
    close $cf2;
    reindex_copy( $cd, 'dup.md' );
    is( lookup( $cd, '/moved' ), '/dup', 'reindex_copy indexes the duplicate (last writer wins)' );
}

done_testing();

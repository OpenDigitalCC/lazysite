#!/usr/bin/perl
# SM447 / DP-1 + DP-2: the minimal end-to-end the release manager named for
# edge - LOAD data through a channel, READ it on a rendered page.
#
# WHY THIS TEST IS THE ONE THAT MATTERS. Everything else in t/unit/data proves
# a layer in isolation, and every layer passing is compatible with the feature
# not working: the store could be written by one docroot and read from another,
# the page variable could resolve to the right rows and render nothing, the
# processor could fail to load the modules at all. Only a write on one side and
# a visitor's HTML on the other settles it.
#
# TWO CHANNELS, ONE STORE, is half the point. The row goes in over the control
# API - an operator or an agent with a token - and comes out through the
# processor, which is a different process holding a handle that CANNOT write.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/layouts/t" );

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
# SM469: a contract plugin is born DISABLED. Enabling it is part of setting
# the site up, exactly as an operator would.
print {$cf} "site_name: Shop\nsite_url: http://localhost\nlayout: t\n"
    . "plugins:\n  - plugins/data.pl\n";
close $cf;

open my $lt, '>', "$docroot/lazysite/layouts/t/layout.tt" or die $!;
print {$lt} '<html><body>[% content %]'
    . '[% FOREACH p IN products %]<li>[% p.name %] @ [% p.price %]</li>[% END %]'
    . '</body></html>';
close $lt;

open my $df, '>', "$docroot/lazysite/db/tables/products.yaml" or die $!;
print {$df} <<'YAML';
title: Products
key: code
fields:
  code:
    type: text
    required: true
  name:
    type: text
  price:
    type: decimal
    digits: 8
    places: 2
YAML
close $df;

# The page. `db:` resolves to the rows; the layout renders them.
open my $pg, '>', "$docroot/index.md" or die $!;
print {$pg} <<'MD';
---
title: Our products
tt_page_var:
  products: db:products sort=name asc limit=10
---

Everything we sell.
MD
close $pg;

open my $nf, '>', "$docroot/404.md" or die $!;
print {$nf} "---\ntitle: NF\n---\nNot found\n";
close $nf;

sub cgi_env {
    return (
        env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'shopkeeper',
        LAZYSITE_AUTH_TRUSTED => 1,
    );
}

sub api_get {
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $_[0] );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}
my $TOKEN = api_get('action=csrf-token')->{token};

sub api_post {
    my ( $qs, $payload ) = @_;
    my $body = encode_json( $payload || {} );
    my $tmp  = "$docroot/.post-body";
    open my $bf, '>', $tmp or die $!;
    print {$bf} $body;
    close $bf;
    local %ENV = (
        cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length($body),
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$tmp\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

# A VISITOR. No user, no trusted header - the anonymous public read path, in
# its own process, holding a read-only handle.
sub visit {
    my ($uri) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REDIRECT_URL   => $uri,
        REQUEST_METHOD => 'GET',
        QUERY_STRING   => '',
    );
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{LAZYSITE_AUTH_TRUSTED};
    return qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
}

subtest 'the page renders before there is any data' => sub {
    my $html = visit('/');
    like( $html, qr/Everything we sell/, 'the page itself renders' )
        or diag( 'A table with no rows must not take the page down.' );
    unlike( $html, qr/<li>/, 'with no rows' );
};

subtest 'LOAD: a row goes in over the control API' => sub {
    ok( api_post('action=data-migrate&table=products')->{ok}, 'schema applied' );
    ok( api_post( 'action=data-row-save&table=products',
            { row => { code => 'W1', name => 'Widget', price => '9.99' } } )->{ok},
        'a row is saved' );
    ok( api_post( 'action=data-row-save&table=products',
            { row => { code => 'A1', name => 'Anvil', price => '120.00' } } )->{ok},
        'and another' );
};

subtest 'READ: a visitor sees it on the page' => sub {
    my $html = visit('/');
    like( $html, qr/<li>Widget \@ 9\.99<\/li>/, 'the row is rendered' )
        or diag( "the page was:\n$html" );
    like( $html, qr/<li>Anvil \@ 120\.00<\/li>/, 'and the second' )
        or diag( 'The money kept its trailing zeros, which is the decimal '
            . 'type doing its job all the way to the browser.' );

    # sort=name asc - Anvil before Widget. Ordering is part of the binding, and
    # a listing in arbitrary order is a listing an author cannot design around.
    like( $html, qr/Anvil.*Widget/s, 'in the declared order' );
};

subtest 'a change is visible on the NEXT request, not the next cache expiry' => sub {
    ok( api_post( 'action=data-row-save&table=products&key=W1',
            { row => { price => '11.50' } } )->{ok}, 'the price changes' );
    my $html = visit('/');
    like( $html, qr/Widget \@ 11\.50/, 'and the visitor sees the new price' )
        or diag( 'A page bound to a table has no file whose mtime proves it '
            . 'current - the store is written through WAL, so a row can '
            . 'change without the database file timestamp moving. That is why '
            . 'the binding marks the page live rather than cacheable.' );
};

subtest 'the page is recorded as LIVE, so it is never served stale' => sub {
    # ASSERTED ON THE DEPENDENCY RECORD, because that is where the guarantee
    # actually lives. Trying to provoke a stale render proves nothing here -
    # a fixture that never fills the cache passes whether the flag is set or
    # not, and that is exactly what my first version of this subtest did.
    #
    # A page bound to a table has no file whose mtime proves it current: the
    # store is written through WAL, so a row can change without the database
    # file's timestamp moving. The processor records such a page as LIVE - a
    # leading `!` in its dependency record - which is the flag that stops the
    # cache claiming a freshness it cannot establish.
    visit('/');
    my @deps = glob "$docroot/lazysite/cache/ct/*";
    ok( scalar @deps, 'a dependency record was written for the page' )
        or diag( 'Without one the page declares no sources at all, and the '
            . 'cache has nothing to reason about.' );

    my $live = 0;
    for my $f (@deps) {
        open my $fh, '<', $f or next;
        my $first = <$fh>;
        close $fh;
        $live = 1 if defined $first && $first =~ /\A!/;
    }
    ok( $live, 'and it is marked live' )
        or diag( 'A cacheable page bound to a live table would serve last '
            . "week's price list while reporting itself fresh." );
};

subtest 'a page naming a table that does not exist still renders' => sub {
    open my $p2, '>', "$docroot/broken.md" or die $!;
    print {$p2} "---\ntitle: Broken\ntt_page_var:\n  products: db:nosuchtable\n---\n\nStill here.\n";
    close $p2;
    my $html = visit('/broken');
    like( $html, qr/Still here/, 'the page renders' )
        or diag( 'A mis-typed table name must not take a page down - the '
            . 'author needs the page in order to fix it.' );
    unlike( $html, qr/<li>/, 'with no rows' );
};

done_testing();

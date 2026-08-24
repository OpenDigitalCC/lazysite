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
# NO lazysite/db AT ALL. The descriptor is declared through the API below,
# which is how a site with no shell access declares one - and hand-writing it
# here is what hid SM470: the fixture modelled an operator with a shell, who is
# nobody this feature is for.
make_path("$docroot/lazysite/layouts/t");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
# SM469: a contract plugin is born DISABLED. Enabling it is part of setting
# the site up, exactly as an operator would.
print {$cf} "site_name: Shop\nsite_url: http://localhost\nlayout: t\n"
    . "plugins:\n  - plugins/data.pl\n";
close $cf;

open my $lt, '>', "$docroot/lazysite/layouts/t/layout.tt" or die $!;
print {$lt} '<html><body>[% content %]'
    . '[% FOREACH p IN products %]<li>[% p.name %] @ [% p.price %]</li>[% END %]'
    . '[% IF products_total %]<p>TOT=[% products_total %]</p>[% END %]'
    . '[% IF many %]<p>MANY=[% many.size %]/[% many_total %]</p>[% END %]'
    . '</body></html>';
close $lt;


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

subtest 'SM470: a table is DECLARED through the API, with no file access' => sub {
    my $yaml = <<'YAML';
title: Products
key: code
indexes:
  - [name]
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
    my $r = api_post( 'action=data-table-save', { table => 'products',
            descriptor => $yaml } );
    ok( $r->{ok}, 'the descriptor saves' ) or diag( $r->{error} // '' );
    ok( $r->{migrate_required},
        'and says the stored table still needs migrating' )
        or diag( 'Writing a descriptor and changing the stored table are two '
            . 'decisions; the second can be refused in part.' );
    ok( -f "$docroot/lazysite/db/tables/products.yaml",
        'the file is created, directory and all' );

    my $bad = api_post( 'action=data-table-save',
        { table => 'broken', descriptor => "fields:\n  x:\n    type: nosuch\n" } );
    ok( !$bad->{ok}, 'a descriptor that does not load is REFUSED' )
        or diag( 'Storing it would move the failure to first use, when the '
            . 'author has moved on and it surfaces as "the table does not '
            . 'work".' );
    like( $bad->{error}, qr/unknown type/, 'with the loader\'s own reason' );
    ok( !-f "$docroot/lazysite/db/tables/broken.yaml", 'and nothing is written' );

    my $escape = api_post( 'action=data-table-save',
        { table => '../../etc/passwd', descriptor => "fields:\n  a:\n    type: text\n" } );
    ok( !$escape->{ok}, 'and the name cannot climb out of the directory' );

    # TWO THINGS THIS FILE CANNOT PROVE, recorded rather than left to look
    # covered:
    #
    # Removing the explicit name check in action_data_table_save does NOT fail
    # this test, because load_descriptor refuses the same names through
    # _bad_ident. The explicit check is defence in depth and a better message,
    # not the only guard - and a sabotage of it passing is the correct result,
    # not a hole.
    #
    # Removing the CHECKED write (print and close, before the rename) also does
    # not fail here: provoking a torn write needs a real failed write, which is
    # what SM404's own test does with `ulimit -f`. The shape is copied from the
    # writer SM404 fixed; what is asserted below is the reachable half, that an
    # unwritable directory is reported rather than silently succeeding.
    my $dir  = "$docroot/lazysite/db/tables";
    my $mode = ( stat $dir )[2] & 07777;
SKIP: {
        skip 'running as root - directory modes do not bind', 1 if $> == 0;
        chmod 0500, $dir or skip 'cannot chmod', 1;
        my $ro = api_post( 'action=data-table-save',
            { table => 'nowrite', descriptor => "fields:\n  a:\n    type: text\n" } );
        ok( !$ro->{ok}, 'an unwritable directory is reported, not swallowed' );
        chmod $mode, $dir;
    }
};

subtest 'the page renders before there is any data' => sub {
    my $html = visit('/');
    like( $html, qr/Everything we sell/, 'the page itself renders' )
        or diag('A table with no rows must not take the page down.');
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

subtest 'SM476: until it is published, a visitor sees nothing' => sub {
    # The descriptor above declares no `public:`, so it defaults closed - and
    # this is the step an author meets first, before they have read anything
    # about publication. It has to be visible in the journey rather than
    # arranged away by a fixture, because "I loaded the rows and the page is
    # empty" is the exact moment somebody needs to be told why.
    my $html = visit('/');
    unlike( $html, qr/Widget/, 'the rows are not on the page' )
        or diag( 'A table defaults to closed. If this renders, the default '
            . 'has been reversed and every table declared before that change '
            . 'is now exposed.' );

    # AND THE OPERATOR CAN STILL SEE THEM. The rows went in fine; it is
    # publication that is missing, not data - so the surface that says so must
    # keep working, or the diagnosis is impossible.
    my $rows = api_post('action=data-rows&table=products');
    ok( $rows->{ok}, 'but the API still reads them' );
    is( scalar @{ $rows->{rows} // [] }, 2, 'both of them' );
};

subtest 'PUBLISH: the operator says the table may be seen' => sub {
    my $yaml = <<'YAML';
public: true
title: Products
key: code
indexes:
  - [name]
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
    my $r = api_post( 'action=data-table-save',
        { table => 'products', descriptor => $yaml } );
    ok( $r->{ok}, 'the descriptor is re-saved with public: true' )
        or diag( $r->{error} // '' );
    ok( !$r->{migrate_required},
        'and publishing is not a schema change - no migration needed' )
        or diag( 'Publication is about who may read the rows, not about what '
            . 'shape they are. Needing a migration to publish would put a '
            . 'destructive-change confirmation in front of a privacy setting.' );
};

subtest 'READ: a visitor sees it on the page' => sub {
    my $html = visit('/');
    like( $html, qr/<li>Widget \@ 9\.99<\/li>/, 'the row is rendered' )
        or diag("the page was:\n$html");
    like( $html, qr/<li>Anvil \@ 120\.00<\/li>/, 'and the second' )
        or diag( 'The money kept its trailing zeros, which is the decimal '
            . 'type doing its job all the way to the browser.' );

    # sort=name asc - Anvil before Widget. Ordering is part of the binding, and
    # a listing in arbitrary order is a listing an author cannot design around.
    like( $html, qr/Anvil.*Widget/s, 'in the declared order' );
};

subtest 'a changed row reaches the page' => sub {
    ok( api_post( 'action=data-row-save&table=products&key=W1',
            { row => { price => '11.50' } } )->{ok}, 'the price changes' );
    my $html = visit('/');
    like( $html, qr/Widget \@ 11\.50/, 'and the visitor sees the new price' );

    # THIS SAYS LESS THAN ITS OLD NAME CLAIMED. It used to be called "visible
    # on the NEXT request, not the next cache expiry", which was true only
    # because every db: binding forced the page live. Under DP-2 the default is
    # snapshot, so WHEN a change becomes visible is the page's ttl - and this
    # fixture never fills the cache, so it could not tell the difference
    # either way. What it still proves is that the read is not stuck on a
    # stale descriptor or a cached statement.
};

subtest 'DP-2: the mode decides whether the page is live' => sub {
    # ASSERTED ON THE DEPENDENCY RECORD, because that is where the guarantee
    # lives. Provoking a stale render proves nothing here - a fixture that
    # never fills the cache passes whether the flag is set or not, which is
    # what an earlier version of this subtest did.
    #
    # SNAPSHOT IS THE DEFAULT NOW, and that is the correction DP-2 makes. Every
    # db: binding used to force the page live, which made a price list on a
    # home page cost a database read per visitor - a performance cliff nobody
    # opted into and nobody could see. An author who needs per-request
    # freshness asks for it.
    sub live_flag {
        my @deps = glob "$docroot/lazysite/cache/ct/*";
        return ( undef, 0 ) unless @deps;
        my $live = 0;
        for my $f (@deps) {
            open my $fh, '<', $f or next;
            my $first = <$fh>;
            close $fh;
            $live = 1 if defined $first && $first =~ /\A!/;
        }
        return ( scalar @deps, $live );
    }

    unlink glob "$docroot/lazysite/cache/ct/*";
    visit('/');
    my ( undef, $live ) = live_flag();
    ok( !$live, 'a snapshot binding does NOT force the page live' )
        or diag( 'Snapshot means resolved at render and cached with the page, '
            . 'refreshed by the page ttl like any other content.' );

    # AND IT REGISTERS NO DEPENDENCY EITHER, which is worth stating rather than
    # discovering. There is nothing for a snapshot to depend ON: the store is
    # written through WAL, so a row can change without the database file's
    # timestamp moving, and a dependency that cannot detect a change is worse
    # than none - it would report freshness it never established. Snapshot's
    # freshness is the page's ttl, exactly as the brief specifies, and the docs
    # say so where an author chooses a mode.

    # mode=live is the opt-in, and it must still work: a stock level or a queue
    # length is exactly the case where a cached page would be wrong.
    open my $p3, '>', "$docroot/index.md" or die $!;
    print {$p3} "---\ntitle: Home\ntt_page_var:\n"
        . "  products: db:products(order=name,limit=10,mode=live)\n---\n\nHi\n";
    close $p3;
    unlink glob "$docroot/lazysite/cache/ct/*";
    visit('/');
    my ( $n2, $live2 ) = live_flag();
    ok( $n2,    'the live page records dependencies too' );
    ok( $live2, 'and mode=live DOES mark it live' )
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

subtest 'SM511: the page can say the whole count' => sub {
    my $html = visit('/');
    like( $html, qr/TOT=2/,
        'products_total reaches the template beside the (possibly capped) list' )
        or diag($html);
};

subtest 'SM511: an over-cap limit renders rows, not zero' => sub {
    open my $cp, '>', "$docroot/caps.md" or die $!;
    print {$cp} <<'MD';
---
title: Caps
tt_page_var:
  many: db:products(limit=501)
---

Capped ask.
MD
    close $cp;
    my $html = visit('/caps');
    like( $html, qr{MANY=2/2}, 'the clamp serves the rows it can' )
        or diag( $html
            . 'This used to be a parse refusal that reached the page as an '
            . 'empty list - a blank gallery with nothing to explain it.' );
};

done_testing();

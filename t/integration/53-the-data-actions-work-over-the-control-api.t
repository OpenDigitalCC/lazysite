#!/usr/bin/perl
# SM447: the data actions, driven through the CGI as a caller drives them.
#
# WHY AN INTEGRATION TEST AND NOT MORE UNIT TESTS. The modules underneath are
# covered; what is NOT covered by any of them is the wiring, and the wiring is
# five separate registries that must agree: %KNOWN_ACTION, the dispatch chain,
# %COOKIE_CAP, the token %need map, and %MUTATING. A lint proves each list is
# consistent with the others. Only a request proves the whole thing answers.
#
# THE WRITERS MUST REFUSE A GET. They are capability-gated, and the cookie
# path's CSRF gate is method-keyed - it covers POST - so a state-changing
# action reachable by GET is CSRF-able from an operator's browser. That is the
# 0.8.1 site-backup-* gap class, and t/lint/14 pins the list; this asserts the
# behaviour the list is supposed to produce.
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
make_path("$docroot/lazysite/db/tables");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
# SM469: a contract plugin is born DISABLED, so enabling it is part of
# setting a site up - and the refusal when it is off is asserted below.
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;

open my $df, '>', "$docroot/lazysite/db/tables/products.yaml" or die $!;
print {$df} <<'YAML';
title: Products
key: code
fields:
  code:
    type: text
    required: true
    max: 20
  name:
    type: text
  price:
    type: decimal
    digits: 8
    places: 2
YAML
close $df;

sub cgi_env {
    return (
        env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'testmgr',
        LAZYSITE_AUTH_TRUSTED => 1,
    );
}

sub raw_get {
    my ($qs) = @_;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    return qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
}

sub csrf_token {
    my $out = raw_get('action=csrf-token');
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out)->{token};
}
my $TOKEN = csrf_token();

sub api_get {
    my $out = raw_get( $_[0] );
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

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

subtest 'SM469: with the plugin DISABLED, every action refuses' => sub {
    # ADR 0009's first clause: a disabled plugin executes nothing and says so.
    # The gate covered plugin SCRIPT execution, and these actions dispatch
    # straight into the manager module - so disabling the plugin changed
    # nothing about them. A plugin owning control-API actions is a new shape,
    # and before this one there was no such path for the gate to miss.
    #
    # READS ARE REFUSED TOO. A read is execution: it opens the store and runs a
    # query. "Disabled but still answering" is the state SM409 exists to
    # remove.
    my $conf = "$docroot/lazysite/lazysite.conf";
    open my $off, '>', $conf or die $!;
    print {$off} "site_name: T\n";    # no plugins: list - disabled
    close $off;

    for my $a (qw(data-tables data-table data-rows)) {
        my $d = api_get("action=$a&table=products");
        ok( !$d->{ok}, "$a refuses while disabled" );
        like( $d->{error}, qr/disabled/, 'and says so' );
    }
    my $m = api_post('action=data-migrate&table=products');
    ok( !$m->{ok}, 'data-migrate refuses while disabled' );
    like( $m->{error}, qr/Plugin Manager/,
        'and names where to turn it on' )
        or diag( 'A refusal that does not say how to proceed leaves the '
            . 'operator with nowhere to go.' );

    open my $on, '>', $conf or die $!;
    print {$on} "site_name: T\nplugins:\n  - plugins/data.pl\n";
    close $on;
    ok( api_get('action=data-tables')->{ok}, 'and answers again once enabled' );
};

subtest 'the declared tables are listed, with their titles' => sub {
    my $d = api_get('action=data-tables');
    ok( $d->{ok}, 'data-tables answers' ) or diag( $d->{error} );
    is( scalar @{ $d->{tables} }, 1, 'one table' );
    is( $d->{tables}[0]{table}, 'products', 'named' );
    is( $d->{tables}[0]{title}, 'Products',  'and titled from the descriptor' );
};

subtest 'the shape is readable before anything is stored' => sub {
    my $d = api_get('action=data-table&table=products');
    ok( $d->{ok}, 'data-table answers' ) or diag( $d->{error} );
    is( $d->{key}, 'code', 'the key is reported' );
    ok( $d->{fields}{price}, 'and the fields' );
    is( $d->{fields}{price}{type}, 'decimal', 'with their declared types' );

    my $rows = api_get('action=data-rows&table=products');
    ok( $rows->{ok}, 'reading before migrating is not an error' );
    ok( $rows->{pending_schema}, 'and says the schema has not been applied' )
        or diag( 'An empty list without a reason is what SM460 was.' );
};

subtest 'migrate, then write and read a row' => sub {
    my $m = api_post('action=data-migrate&table=products');
    ok( $m->{ok}, 'data-migrate answers' ) or diag( $m->{error} );
    ok( scalar @{ $m->{applied} }, 'and reports what it did' );

    my $s = api_post( 'action=data-row-save&table=products',
        { row => { code => 'A1', name => q{Bob's "widget"}, price => '9.99' } } );
    ok( $s->{ok}, 'a row saves' ) or diag( $s->{error} );

    my $rows = api_get('action=data-rows&table=products');
    is( scalar @{ $rows->{rows} }, 1, 'and reads back' );
    is( $rows->{rows}[0]{name}, q{Bob's "widget"}, 'with the awkward text intact' );
    is( $rows->{rows}[0]{price}, '9.99', 'and the money as a canonical string' );

    my $u = api_post( 'action=data-row-save&table=products&key=A1',
        { row => { name => 'renamed' } } );
    ok( $u->{ok}, 'and updates by key' ) or diag( $u->{error} );

    my $d = api_post('action=data-row-delete&table=products&key=A1');
    ok( $d->{ok}, 'and deletes' ) or diag( $d->{error} );
};

subtest 'a bad value is refused by the API, not stored' => sub {
    my $s = api_post( 'action=data-row-save&table=products',
        { row => { code => 'B1', price => '1.234' } } );
    ok( !$s->{ok}, 'too many decimal places is refused at the surface too' )
        or diag( 'The surface must not be a way around the value layer.' );
    like( $s->{error}, qr/decimal place/, 'and says why' );
};

subtest 'a field called `table` or `key` does not collide with the action' => sub {
    # THIS IS WHY THE ROW IS NESTED under `row` rather than flattened into the
    # request. A descriptor may legitimately declare a field called `table` or
    # `key` - a parts list with a `key` column, a seating plan with a `table`
    # column - and a flattened request would have the site's own data overwrite
    # the action's own parameters. Silently: the save would target whatever
    # table the row happened to name.
    open my $fh, '>', "$docroot/lazysite/db/tables/seating.yaml" or die $!;
    print {$fh} <<'YAML';
key: ref
fields:
  ref:
    type: text
    required: true
  table:
    type: text
  key:
    type: text
YAML
    close $fh;

    ok( api_post('action=data-migrate&table=seating')->{ok}, 'the table migrates' );
    my $s = api_post( 'action=data-row-save&table=seating',
        { row => { ref => 'R1', table => 'products', key => 'A1' } } );
    ok( $s->{ok}, 'a row whose fields are named `table` and `key` saves' )
        or diag( $s->{error} );

    my $rows = api_get('action=data-rows&table=seating');
    is( scalar @{ $rows->{rows} }, 1, 'into the table the ACTION named' )
        or diag( 'If the row had been flattened, `table => products` would '
            . 'have redirected the save.' );
    is( $rows->{rows}[0]{table}, 'products', 'with its own `table` value intact' );
    is( $rows->{rows}[0]{key},   'A1',       'and its own `key` value' );

    my $p = api_get('action=data-rows&table=products');
    is( scalar @{ $p->{rows} }, 0, 'and nothing landed in the other table' );
};

subtest 'the WRITERS refuse a GET' => sub {
    # Capability-gated and state-changing: reachable by GET means CSRF-able
    # from an operator's browser, because the CSRF gate is method-keyed.
    # THE REFUSAL IS A JSON ok:false WITH HTTP 200, not a 4xx, and asserting
    # the status code was my own error: the whole API answers 200 and reports
    # in the body. A test that checked for a 4xx would have failed against a
    # correct implementation and passed against nothing at all.
    for my $a (qw(data-migrate data-row-save data-row-delete)) {
        my $d = api_get("action=$a&table=products");
        ok( !$d->{ok}, "$a refuses a GET" )
            or diag( "GET $a was not refused - this is the 0.8.1 "
                . 'site-backup-* gap class.' );
        like( $d->{error}, qr/must be sent as POST/, 'and says why' );
    }
};

subtest 'and the READS are readable by GET' => sub {
    # The other half: enrolling a read in the reviewed allowlist has to mean
    # it actually works that way, or the allowlist is describing something
    # else.
    for my $a (qw(data-tables data-table data-rows)) {
        my $d = api_get("action=$a&table=products");
        ok( $d->{ok}, "$a answers a GET" )
            or diag( $d->{error} // '' );
    }
};

done_testing();

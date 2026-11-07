#!/usr/bin/perl
# SM1355 (ruling 156): THE CONTROL API AND MANAGER DOORS OF A SWITCH, A WIZARD AND
# THE ROW HISTORY.
#
# A switch, an undo and a wizard's row are row writes: a write_data account
# reaches them where the table's writable_by names its group, and is refused
# where it does not, as for data-row-save. Every row change through the manager
# (a person) or the control API (a token) is recorded, naming who and the door;
# a required wizard question cannot be skipped; a deleted row's undo puts it
# back with its authors.
#
# With the change reverted the actions are unknown, no change is recorded, and
# each subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nmanager_groups: admins\nextensions:\n  - extensions/data.pl\n" );
my $d = $s->docroot;

make_path("$d/lazysite/db/tables");
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
put( 'lazysite/db/tables/stock.yaml', <<'YAML' );
title: Stock
key: sku
timestamps: true
availability: on_sale
writable_by: [shop, admins]
fields:
  sku:
    type: text
    required: true
  name:
    type: text
    required: true
  on_sale:
    type: boolean
    default: false
YAML
put( 'lazysite/db/tables/ledger.yaml', <<'YAML' );
title: Ledger
key: ref
availability: open
writable_by: [accounts, admins]
fields:
  ref:
    type: text
    required: true
  open:
    type: boolean
YAML
make_path("$d/lazysite/db/wizards");
put( 'lazysite/db/wizards/item.yaml', <<'YAML' );
title: Add an item
table: stock
steps:
  - field: sku
    ask: Its code
    type: text
    required: true
  - field: name
    ask: What is it called?
    type: text
    required: true
  - field: on_sale
    ask: On sale now?
    type: yesno
YAML

my @ALL = qw(ui api manage_data write_data);
$s->add_user('boss');
$s->grant( 'boss', 'admins', [qw(ui manage_users manage_data)], \@ALL );
$s->add_user('clerk');
$s->grant( 'clerk', 'shop', [qw(api write_data)], \@ALL );
my $tok = do {
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => 'clerk' } ), stderr => 'inherit' )->{out};
    ( eval { decode_json($out) } || {} )->{token};
};
ok( $tok, 'the write_data client has a token' );

sub api {
    my ( $qs, $body ) = @_;
    my $json = encode_json( $body // {} );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{QUERY_STRING}       = $qs;
    $ENV{CONTENT_LENGTH}     = length $json;
    $ENV{CONTENT_TYPE}       = 'application/json';
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . MIME::Base64::encode_base64( "clerk:$tok", '' );
    my $out = run_child( [ $^X, $mapi ], stdin => $json, stderr => 'inherit' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub boss { my ( $action, %o ) = @_; return $s->call( 'boss', $action, %o ) }

for my $t (qw(stock ledger)) {
    my $m = boss( 'data-migrate', query => "action=data-migrate&table=$t", body => {} );
    ok( $m->{ok}, "$t migrated" ) or diag explain $m;
}

subtest 'a person\'s row save and switch are recorded, naming the manager' => sub {
    my $w = boss( 'data-row-save', query => 'action=data-row-save',
        body => { table => 'stock', row => { sku => 'A1', name => 'Apples' } } );
    ok( $w->{ok} && $w->{change}, 'saved, as a recorded change' ) or diag explain $w;
    my $sw = boss( 'data-row-switch', query => 'action=data-row-switch',
        body => { table => 'stock', key => 'A1', available => JSON::PP::true } );
    ok( $sw->{ok} && $sw->{undo}, 'switched, offering its undo' ) or diag explain $sw;
    my $h = boss( 'data-row-changes', query => 'action=data-row-changes&table=stock' );
    is_deeply( [ map {"$_->{op}/$_->{source}/$_->{actor}"} @{ $h->{changes} || [] } ],
        [ 'switch/manager/boss', 'insert/manager/boss' ], 'the history names what, the door and who' )
        or diag explain $h;
};

subtest 'a write_data token switches where writable_by names its group, and only there' => sub {
    my $sw = api( 'action=data-row-switch', { table => 'stock', key => 'A1', available => JSON::PP::false } );
    ok( $sw->{ok}, 'switched off by the shop\'s token' ) or diag explain $sw;
    my $h = boss( 'data-row-changes', query => 'action=data-row-changes&table=stock&limit=1' );
    is( $h->{changes}[0]{source}, 'api', 'recorded as from the control API' );
    is( $h->{changes}[0]{actor}, 'clerk', '...by the token\'s account' );
    boss( 'data-row-save', query => 'action=data-row-save', body => { table => 'ledger', row => { ref => 'L1' } } );
    my $no = api( 'action=data-row-switch', { table => 'ledger', key => 'L1', available => JSON::PP::true } );
    ok( !$no->{ok}, 'refused on a table that names another group' );
    like( $no->{error} // '', qr/writable by: accounts, admins/, '...naming the rule' );
    my $undo = api( 'action=data-row-undo', { table => 'ledger', change => 1 } );
    ok( !$undo->{ok}, 'and its undo is refused the same way' );
};

subtest 'a wizard over the control API: one question at a time, required ones asked' => sub {
    my $q = api( 'action=data-wizard-run', { wizard => 'item', answers => { sku => 'B2' } } );
    is( $q->{question}{field}, 'name', 'the next question' ) or diag explain $q;
    my $skip = api( 'action=data-wizard-run', { wizard => 'item', answers => { sku => 'B2', name => undef }, save => JSON::PP::true } );
    is( $skip->{kind}, 'required', 'a required question cannot be skipped' ) or diag explain $skip;
    my $w = api( 'action=data-wizard-run',
        { wizard => 'item', answers => { sku => 'B2', name => 'Bread', on_sale => undef }, save => JSON::PP::true } );
    ok( $w->{saved}, 'an optional one can, and the row is saved' ) or diag explain $w;
    my $h = boss( 'data-row-changes', query => 'action=data-row-changes&table=stock&key=B2' );
    is( $h->{changes}[0]{source}, 'wizard:item', 'recorded as the wizard\'s' ) or diag explain $h;
};

subtest 'a deleted row\'s undo puts it back with its authors' => sub {
    my $del = boss( 'data-row-delete', query => 'action=data-row-delete', body => { table => 'stock', key => 'B2' } );
    ok( $del->{ok} && $del->{change}, 'deleted, as a recorded change' ) or diag explain $del;
    my $u = boss( 'data-row-undo', query => 'action=data-row-undo', body => { table => 'stock', change => $del->{change} } );
    ok( $u->{ok}, 'undone' ) or diag explain $u;
    is( $u->{row}{created_by}, 'clerk', 'the row keeps the account that created it' );
    is( $u->{row}{name}, 'Bread', '...and its values' );
};

subtest 'the history is manage_data\'s, and a wizard is defined only by it' => sub {
    my $h = api( 'action=data-row-changes&table=stock', {} );
    ok( !$h->{ok}, 'a write_data token is not shown the history' );
    my $save = api( 'action=data-wizard-save', { wizard => 'other', definition => "table: stock\nsteps: []\n" } );
    ok( !$save->{ok}, 'nor may it define a wizard' );
    my $bad = boss( 'data-wizard-save', query => 'action=data-wizard-save',
        body => { wizard => 'nameless', definition => "table: stock\nsteps:\n  - field: sku\n    ask: Code\n    type: text\n    required: true\n" } );
    ok( !$bad->{ok}, 'a wizard that does not ask a required field is refused' );
    is( $bad->{rule}, 'required_unasked', '...by rule' ) or diag explain $bad;
};

done_testing();

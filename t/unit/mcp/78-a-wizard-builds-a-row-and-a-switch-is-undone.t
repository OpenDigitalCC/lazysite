#!/usr/bin/perl
# SM1355 (ruling 156): WIZARDS THAT BUILD ROWS, AND AVAILABILITY SWITCHES, OVER MCP.
#
# A table declares an availability field; a wizard asks one question per step
# and builds one row (a required question cannot be skipped, a step may depend
# on an earlier answer); switch_row is immediate and one recorded change, and
# undo_row_change puts the row back (refused once the row moved on, and once
# done); every row change is listed with who and where from; a page shows the
# switched-on rows through db:<table>(available).
#
# With the change reverted the tools do not exist, `availability` is no
# descriptor key, (available) is a filter on a field nobody declared, and every
# subtest below fails.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_child site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

my $mcp = "$FindBin::Bin/../../../lazysite-mcp.pl";
my $d   = site_tempdir();
make_path("$d/lazysite/auth");
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "mcp_enabled: true\nextensions:\n  - extensions/data.pl\n";
    close $cf;
}

my $stub = "$d/users-stub.pl";
{
    open my $sf, '>', $stub or die $!;
    print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %caps = $u =~ /owner/ ? (manage_data => 1, manage_content => 1) : (manage_content => 1);
$caps{mcp} = 1;
print encode_json({ ok => 1, settings => \%caps });
STUB
    close $sf;
    chmod 0755, $stub;
}

sub call {
    my ( $tool, $args, $auth ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $auth // 'Bearer owner:lzs_tok';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $r && $r->{result} ? $r->{result}{structuredContent}
        : { ok => 0, error => ( $r && $r->{error} ? $r->{error}{message} : 'no answer' ) };
}

my $MENU = <<'YAML';
title: Menu
key: slug
public: true
availability: today
fields:
  slug:
    type: text
    required: true
  name:
    type: text
    required: true
  price:
    type: decimal
    digits: 6
    places: 2
  course:
    type: enum
    values: [starter, main, dessert]
  allergens:
    type: text
  spicy:
    type: boolean
  heat:
    type: text
  today:
    type: boolean
    default: false
YAML

my $WIZARD = <<'YAML';
title: Add a dish
table: menu
steps:
  - field: slug
    ask: A short name for the address
    type: text
    required: true
  - field: name
    ask: What is the dish called?
    type: text
    required: true
    help: As it should appear on the menu.
  - field: price
    ask: How much is it?
    type: price
    required: true
  - field: course
    ask: Which course?
    type: choice
  - field: allergens
    ask: Which allergens does it contain?
    type: choices
    options: [gluten, nuts, dairy]
  - field: spicy
    ask: Is it spicy?
    type: yesno
  - field: heat
    ask: How hot?
    type: choice
    options: [mild, medium, hot]
    when: { field: spicy, is: true }
YAML

subtest 'a table declares its availability field, and a wrong one is refused' => sub {
    my $bad = call( 'save_data_table', { table => 'menu', descriptor => $MENU =~ s/availability: today/availability: name/r } );
    ok( !$bad->{ok}, 'availability naming a text field is refused' );
    like( $bad->{error} // '', qr/not a boolean field/, '...saying why' );
    my $none = call( 'save_data_table', { table => 'menu', descriptor => $MENU =~ s/availability: today/availability: tday/r } );
    like( $none->{error} // '', qr/not a declared field/, 'a field it does not declare is refused' );
    ok( call( 'save_data_table', { table => 'menu', descriptor => $MENU } )->{ok}, 'declared' );
    ok( call( 'migrate_data_table', { table => 'menu' } )->{ok}, 'migrated' );
    is( call( 'describe_data_table', { table => 'menu' } )->{availability}, 'today', 'describe names it' );
};

subtest 'a wizard is checked against its table before it is stored' => sub {
    my $skip = call( 'save_wizard', { wizard => 'dish', definition => $WIZARD =~ s/(  - field: name\n.*?\n.*?\n)    required: true\n/$1/sr } );
    ok( !$skip->{ok}, 'an optional step for a field the table requires is refused' );
    is( $skip->{rule}, 'required', '...by rule' ) or diag explain $skip;
    my $unasked = call( 'save_wizard', { wizard => 'dish', definition => $WIZARD =~ s/  - field: price\n(?:    .*\n)+//r } );
    ok( $unasked->{ok}, 'price is optional in the table, so leaving it out is allowed' ) or diag explain $unasked;
    my $type = call( 'save_wizard', { wizard => 'dish', definition => $WIZARD =~ s/ask: Is it spicy\?\n    type: yesno/ask: Is it spicy?\n    type: price/r } );
    like( $type->{error} // '', qr/cannot write 'spicy'/, 'a type the field cannot hold is refused' );
    my $when = call( 'save_wizard', { wizard => 'dish', definition => $WIZARD =~ s/when: \{ field: spicy/when: { field: heat/r } );
    like( $when->{error} // '', qr/no earlier step asks/, 'a `when` on a later step is refused' );
    my $ok = call( 'save_wizard', { wizard => 'dish', definition => $WIZARD } );
    ok( $ok->{ok}, 'the wizard is stored' ) or diag explain $ok;
    my $l = call( 'list_wizards', {} );
    is_deeply( [ map { $_->{name} } @{ $l->{wizards} || [] } ], ['dish'], 'and listed' ) or diag explain $l;
};

my $row_change;
subtest 'run_wizard asks one question at a time, and a required one cannot be skipped' => sub {
    my $q = call( 'run_wizard', { wizard => 'dish' } );
    ok( $q->{ok} && !$q->{complete}, 'the first question' ) or diag explain $q;
    is( $q->{question}{field}, 'slug', '...is the first step' );
    my $no = call( 'run_wizard', { wizard => 'dish', answers => { slug => 'soup', name => '' } } );
    ok( !$no->{ok}, 'a required step answered empty is refused' );
    is( $no->{kind}, 'required', '...as required' );
    is( $no->{question}{field}, 'name', '...and asked again' );
    my $saved = call( 'run_wizard', { wizard => 'dish', save => JSON::PP::true,
            answers => { slug => 'soup', name => 'Soup', price => '£4.50' } } );
    ok( !$saved->{saved}, 'a save before the last question writes nothing' ) or diag explain $saved;
    is( $saved->{question}{field}, 'course', '...and asks the next' );
    is_deeply( $saved->{question}{options}, [qw(starter main dessert)], 'a choice offers the enum values' );
    my $a = { slug => 'soup', name => 'Soup', price => '£4.50', course => 'starter',
        allergens => [qw(dairy gluten)], spicy => JSON::PP::false };
    my $done = call( 'run_wizard', { wizard => 'dish', answers => $a } );
    ok( $done->{complete}, 'heat is not asked of a dish that is not spicy' ) or diag explain $done;
    is( $done->{row}{allergens}, 'gluten,dairy', 'choices are stored in their listed order' );
    is( $done->{row}{price}, '4.50', 'the price is the amount' );
    my $w = call( 'run_wizard', { wizard => 'dish', answers => $a, save => JSON::PP::true } );
    ok( $w->{saved}, 'saved' ) or diag explain $w;
    ok( $w->{change}, '...as a recorded change' );
    $row_change = $w->{change};
    my $spicy = call( 'run_wizard', { wizard => 'dish',
            answers => { slug => 'chilli', name => 'Chilli', price => '6', course => 'main', allergens => [], spicy => JSON::PP::true } } );
    is( $spicy->{question}{field}, 'heat', 'a spicy dish is asked how hot' ) or diag explain $spicy;
    ok( call( 'run_wizard', { wizard => 'dish', save => JSON::PP::true,
                answers => { slug => 'chilli', name => 'Chilli', price => '6', course => 'main', allergens => [],
                    spicy => JSON::PP::true, heat => 'hot' } } )->{saved}, 'and saved' );
};

subtest 'a wizard edits a row, offering what it holds' => sub {
    my $q = call( 'run_wizard', { wizard => 'dish', key => 'soup' } );
    is( $q->{question}{field}, 'name', 'the key is not asked again' ) or diag explain $q;
    is( $q->{question}{current}, 'Soup', 'the current value is offered' );
    my $w = call( 'run_wizard', { wizard => 'dish', key => 'soup', save => JSON::PP::true,
            answers => { name => 'Tomato soup', price => '4.75', course => 'starter', allergens => [], spicy => JSON::PP::false } } );
    ok( $w->{saved}, 'edited' ) or diag explain $w;
    my $rows = call( 'read_data_rows', { table => 'menu' } );
    my ($soup) = grep { $_->{slug} eq 'soup' } @{ $rows->{rows} || [] };
    is( $soup->{name}, 'Tomato soup', 'the row carries the edit' );
};

my $switch;
subtest 'switch_row is immediate, one recorded change, and undoable' => sub {
    my $s = call( 'switch_row', { table => 'menu', key => 'soup', available => JSON::PP::true } );
    ok( $s->{ok}, 'switched on' ) or diag explain $s;
    ok( $s->{change} && $s->{undo}, 'naming its change and its undo' );
    $switch = $s->{change};
    my $again = call( 'switch_row', { table => 'menu', key => 'soup', available => JSON::PP::true } );
    ok( $again->{unchanged}, 'switching it on again writes nothing' );
    my $hist = call( 'list_row_changes', { table => 'menu', key => 'soup' } );
    my @ops = map { "$_->{op}/$_->{source}" } @{ $hist->{changes} || [] };
    is_deeply( \@ops, [ 'switch/mcp', 'update/wizard:dish', 'insert/wizard:dish' ],
        'the row\'s changes, newest first, with where each came from' ) or diag explain $hist;
    is( $hist->{changes}[0]{actor}, 'owner', '...and who' );
};

subtest 'a page shows the available rows through its binding' => sub {
    make_path("$d/content");
    open my $pf, '>', "$d/today.md" or die $!;
    print {$pf} "---\ntitle: Today\ntt_page_var:\n  dishes: db:menu(available,order=name)\n  all: db:menu(order=name)\n---\n\n"
        . "[% FOREACH x IN dishes %]ON:[% x.name %];[% END %]\n\n"
        . "[% FOREACH x IN all %][% IF x.today %]LIVE:[% ELSE %]OFF:[% END %][% x.name %];[% END %]\n";
    close $pf;
    my $p = call( 'preview_page', { path => '/today.md' } );
    ok( $p->{ok}, 'rendered' ) or diag explain $p;
    like( $p->{html} // '', qr/ON:Tomato soup;/, 'the switched-on dish is shown' );
    unlike( $p->{html} // '', qr/ON:Chilli/, 'the other is hidden' );
    like( $p->{html} // '', qr/OFF:Chilli;/, 'or marked, where the layout lists every row' );
};

subtest 'undo_row_change puts the row back, and is refused once the row moved on' => sub {
    my $stale = call( 'undo_row_change', { table => 'menu', change => $row_change } );
    ok( !$stale->{ok}, 'undoing the wizard\'s insert after later changes is refused' );
    is( $stale->{kind}, 'stale-change', '...as stale' ) or diag explain $stale;
    my $u = call( 'undo_row_change', { table => 'menu', change => $switch } );
    ok( $u->{ok}, 'the switch is undone' ) or diag explain $u;
    ok( !$u->{row}{today}, 'the dish is unavailable again' );
    my $twice = call( 'undo_row_change', { table => 'menu', change => $switch } );
    is( $twice->{kind}, 'already-undone', 'a second undo is refused' ) or diag explain $twice;
    my $hist = call( 'list_row_changes', { table => 'menu', key => 'soup', limit => 1 } );
    is( $hist->{changes}[0]{op}, 'undo', 'the undo is itself recorded' );
    is( $hist->{changes}[0]{undoes}, $switch, '...naming the change it undid' );
};

subtest 'a delete is recorded, and its undo puts the row back' => sub {
    my $del = call( 'delete_data_row', { table => 'menu', key => 'chilli' } );
    ok( $del->{ok} && $del->{change}, 'deleted, as a recorded change' ) or diag explain $del;
    my $u = call( 'undo_row_change', { table => 'menu', change => $del->{change} } );
    ok( $u->{ok}, 'undone' ) or diag explain $u;
    is( $u->{row}{heat}, 'hot', 'the row is back as it was' );
};

subtest 'a table with no availability field has no switch' => sub {
    ok( call( 'save_data_table', { table => 'notes', descriptor => "key: id\nfields:\n  body:\n    type: text\n  done:\n    type: boolean\n" } )->{ok},
        'a table without one' );
    call( 'migrate_data_table', { table => 'notes' } );
    my $s = call( 'switch_row', { table => 'notes', key => '1', available => JSON::PP::true } );
    is( $s->{kind}, 'no_availability', 'switch_row is refused by name' ) or diag explain $s;
};

subtest 'the tools are manage_data\'s' => sub {
    my $r = call( 'switch_row', { table => 'menu', key => 'soup', available => JSON::PP::true }, 'Bearer editor:lzs_tok' );
    ok( !$r->{ok}, 'a manage_content account is refused' );
};

done_testing();

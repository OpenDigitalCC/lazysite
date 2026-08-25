#!/usr/bin/perl
# SM447: the data tools over MCP.
#
# AN AGENT POPULATING A TABLE IS THE PRIMARY USE of the data plugin, which is
# why these exist rather than leaving agents to drive the control API. The gap
# was recorded in t/lint/23 as a schedule rather than a decision, and this
# closes it.
#
# WHAT THIS ASSERTS THAT THE PARITY LINT CANNOT. t/lint/23 pins the pairing -
# each action has a tool - by reading both files. It cannot tell whether the
# tool WORKS, whether the capability gate admits the right callers, or whether
# the refusals an agent depends on survive the trip. Those need calls.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IPC::Open2;
use JSON::PP;
use FindBin;

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

my $mcp = "$FindBin::Bin/../../../lazysite-mcp.pl";
plan skip_all => 'mcp entry point missing' unless -f $mcp;

my $d = tempdir( CLEANUP => 1 );
# SM470: no lazysite/db. The table is declared through save_data_table below,
# which is the only way an agent can declare one - hand-writing the descriptor
# is what hid the fact that no channel could.
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
# SM469: a contract plugin is born disabled, so an operator enables it - the
# fixture does what an operator would.
print {$cf} "mcp_enabled: true\nplugins:\n  - plugins/data.pl\n";
close $cf;


# Caps by username, as the other MCP tests do.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
my $u = $r->{username} // '';
my %caps = $u =~ /shop/ ? (manage_data => 1) : (manage_content => 1);
$caps{mcp} = 1;
print encode_json({ ok => 1, settings => \%caps });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ( $payload, %extra ) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = $extra{auth} if defined $extra{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}

my $SHOP  = 'Bearer shopkeeper:lzs_tok';    # manage_data
my $OTHER = 'Bearer editor:lzs_tok';        # manage_content, no manage_data

sub call {
    my ( $tool, $args, $auth ) = @_;
    my $r = mcp(
        { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} }
        },
        auth => $auth // $SHOP
    );
    return $r->{result}{structuredContent};
}

subtest 'the tools are advertised to a holder of the capability' => sub {
    my $r = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/list' },
        auth => $SHOP );
    my %have = map { $_->{name} => 1 } @{ $r->{result}{tools} || [] };
    ok( $have{$_}, "$_ is offered" )
        for qw(list_data_tables describe_data_table read_data_rows
        migrate_data_table save_data_row delete_data_row
        plan_data_migration read_data_table_source);
};

subtest 'and NOT to an account without it' => sub {
    my $r = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/list' },
        auth => $OTHER );
    my %have = map { $_->{name} => 1 } @{ $r->{result}{tools} || [] };
    ok( !$have{save_data_row}, 'a manage_content account is not offered the writer' )
        or diag( 'An agent shown a tool it cannot use will call it and read '
            . 'the refusal as a fault.' );
    ok( !$have{list_data_tables}, 'nor the reader' );
};

subtest 'declare, migrate, write, read - the agent path end to end' => sub {
    my $decl = call( 'save_data_table', { table => 'products', descriptor => <<'YAML' } );
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
    ok( $decl->{ok}, 'save_data_table declares the table' )
        or diag( $decl->{error} // '' );

    my $t = call('list_data_tables');
    ok( $t->{ok}, 'list_data_tables answers' ) or diag( $t->{error} // '' );
    is( $t->{tables}[0]{table}, 'products', 'the declared table is there' );

    my $shape = call( 'describe_data_table', { table => 'products' } );
    is( $shape->{key},                 'code',    'its key is reported' );
    is( $shape->{fields}{price}{type}, 'decimal', 'and its field types' );

    my $pending = call( 'read_data_rows', { table => 'products' } );
    ok( $pending->{ok} && $pending->{pending_schema},
        'reading before migrating says pending_schema, rather than looking empty' );

    ok( call( 'migrate_data_table', { table => 'products' } )->{ok}, 'migrate' );
    ok( call( 'save_data_row',
            { table => 'products',
                row => { code => 'W1', name => 'Widget', price => '120.00' } }
    )->{ok}, 'save a row' );

    my $rows = call( 'read_data_rows', { table => 'products' } );
    is( scalar @{ $rows->{rows} }, 1, 'one row' );
    is( $rows->{rows}[0]{price}, '120.00',
        'and the money keeps its trailing zeros all the way through MCP' )
        or diag( 'This is the value that caught sqlite_see_if_its_a_number; '
            . 'it is here so a second surface cannot lose it separately.' );
};

# SM566: the SAFETY step before a migration, and the descriptor as text. The
# API had both (data-migrate-plan, data-table-source) and MCP had neither, so
# an agent could migrate a table without previewing what the migration would
# refuse, and could not read-modify-write a descriptor as it was written.
subtest 'SM566: an agent can preview a migration and read the descriptor as text' => sub {
    my $src = call( 'read_data_table_source', { table => 'products' } );
    ok( $src->{ok}, 'read_data_table_source answers' ) or diag( $src->{error} // '' );
    like( $src->{descriptor}, qr/^key: code$/m, 'the descriptor comes back as the text that was written' );

    # Change price to an integer: a TYPE change, which migrate refuses.
    ( my $changed = $src->{descriptor} ) =~ s/type: decimal\n\s+digits: 8\n\s+places: 2/type: integer/;
    ok( call( 'save_data_table', { table => 'products', descriptor => $changed } )->{ok},
        'the changed descriptor is accepted' );

    my $plan = call( 'plan_data_migration', { table => 'products' } );
    ok( $plan->{ok}, 'plan_data_migration answers' ) or diag( $plan->{error} // '' );
    ok( ( grep { $_->{field} eq 'price' } @{ $plan->{blocked} || [] } ),
        'the plan names the blocked change (price) before anything is applied' )
        or diag( explain $plan );

    # Nothing was applied: the stored column is still the decimal one.
    my $rows = call( 'read_data_rows', { table => 'products' } );
    is( $rows->{rows}[0]{price}, '120.00', 'the plan changed nothing in the store' );

    my $missing = call( 'plan_data_migration', { table => 'nope' } );
    ok( !$missing->{ok}, 'a plan for an undeclared table is refused' );
    my $denied = call( 'read_data_table_source', { table => 'products' }, $OTHER );
    ok( !( $denied && $denied->{ok} ), 'the source read needs manage_data, as the API twin does' );

    # Put the descriptor back as it was, so the subtests below see the table
    # they declared.
    ok( call( 'save_data_table', { table => 'products', descriptor => $src->{descriptor} } )->{ok},
        'the original descriptor round-trips back through save_data_table' );
};

subtest 'the refusals an agent depends on survive the trip' => sub {
    my $bad = call( 'save_data_row',
        { table => 'products', row => { code => 'X1', price => '1.234' } } );
    ok( !$bad->{ok}, 'too many decimal places is refused' );
    like( $bad->{error}, qr/decimal place/, 'with a reason an agent can act on' );

    my $unknown = call( 'save_data_row',
        { table => 'products', row => { code => 'X2', colour => 'red' } } );
    ok( !$unknown->{ok}, 'an unknown field is refused, not dropped' )
        or diag('Dropping it makes a typo look like a successful write.');

    # A `row` that is not an object is refused for THAT reason, not left to
    # fail later as a missing required field. The message is the thing an
    # agent acts on: "row must be an object" tells it to fix the call, while
    # "code is required" sends it looking at the data.
    my $notobj = call( 'save_data_row',
        { table => 'products', row => 'code=X3' } );
    ok( !$notobj->{ok}, 'a row that is not an object is refused' );
    like( $notobj->{error}, qr/must be an object/,
        'naming the shape, not a field that happens to be missing' );

    my $miss = call( 'delete_data_row', { table => 'products', key => 'NOPE' } );
    ok( !$miss->{ok}, 'deleting a row that is not there is refused' );

    my $nosuch = call( 'read_data_rows', { table => 'nosuchtable' } );
    ok( !$nosuch->{ok}, 'and an undeclared table is an error, not an empty list' );
};

subtest 'SM469: a disabled plugin refuses over MCP too' => sub {
    # ADR 0009 says MCP tools backed by a plugin refuse the same way. They do
    # here because the gate lives in the module all three surfaces call, rather
    # than in each surface - which is the reason for that arrangement.
    open my $off, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$off} "mcp_enabled: true\n";    # no plugins: list
    close $off;

    my $r = call('list_data_tables');
    ok( !$r->{ok}, 'a read refuses while the plugin is disabled' );
    like( $r->{error}, qr/disabled/, 'and says so' );

    open my $on, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$on} "mcp_enabled: true\nplugins:\n  - plugins/data.pl\n";
    close $on;
    ok( call('list_data_tables')->{ok}, 'and answers again once enabled' );
};

done_testing();

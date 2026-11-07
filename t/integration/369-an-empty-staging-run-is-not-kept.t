#!/usr/bin/perl
# SM1410: A STAGING RUN THAT STAGES NO ACCOUNT IS NOT KEPT, AND A KEPT ONE
# SAYS HOW TO DISCARD IT.
#
# AccountImport::stage wrote a staging record even when no row was stageable -
# `staged: 0`, every row under `invalid` - and answered ok with its id, and the
# reply named no way to discard it (0.16.7 edge, T-107: stage_accounts with
# one invalid row). The API has accounts-import-remove. Now a run with no
# stageable row writes nothing and is refused, still listing each invalid row
# and saying nothing was staged; a kept run's reply names accounts-import-remove
# with its id. Over MCP (stage_accounts) and the control API
# (accounts-import-stage) alike, which share the module.
#
# With the change reverted: the empty run is answered ok and a file is written,
# and the kept run's note names no remove action.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'mcp missing' unless -f "$root/lazysite-mcp.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp manage_users);
my %CAPS = ( op => [qw(ui manage_users)], mcs => [qw(mcp manage_users)] );
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->users( 'group-set', 'g-op', 'manager', 'on' );    # SM991: the operator

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $tok = uapi( { action => 'token', username => 'mcs' } )->{token} // '';

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer mcs:$tok";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}
sub api_stage { return $s->call( 'op', 'accounts-import-stage', body => $_[0] ) }

sub staged {
    opendir my $dh, "$d/lazysite/auth/import" or return ();
    return grep { /\.json\z/ } readdir $dh;
}

my %BAD = ( accounts => [ { username => 'bad name!' }, { username => 'ok1', email => 'not-an-address' } ] );

for my $door ( [ 'MCP', sub { mcp( 'stage_accounts', $_[0] ) } ], [ 'control API', \&api_stage ] ) {
    my ( $name, $stage ) = @$door;
    subtest "$name: a run with no stageable row is not written" => sub {
        my $r = $stage->( \%BAD );
        ok( !$r->{ok}, 'refused: nothing was staged' ) or diag explain $r;
        is( $r->{staged}, 0, '...staged: 0' );
        is( scalar @{ $r->{invalid} || [] }, 2, '...and each invalid row is still listed' );
        like( $r->{invalid}[0]{error} // '', qr/username/, '...with its reason' );
        like( $r->{error} // '', qr/Nothing was staged/, 'it says nothing was staged' );
        ok( !defined $r->{id}, 'no staging id is answered' );
        is( scalar( my @f = staged() ), 0, 'and no staging record is written' );
    };

    subtest "$name: a kept run names the action that discards it" => sub {
        my $r = $stage->( { accounts => [ { username => 'kept1' }, { username => 'bad name!' } ] } );
        ok( $r->{ok}, 'staged' ) or diag explain $r;
        is( $r->{staged}, 1, '...one row' );
        like( $r->{note} // '', qr/accounts-import-remove with id \Q$r->{id}\E/,
            'the reply names accounts-import-remove, with this run\'s id' );
        my $rm = $s->call( 'op', 'accounts-import-remove', body => { id => $r->{id} } );
        ok( $rm->{ok}, '...which removes it' ) or diag explain $rm;
        is( scalar( my @f = staged() ), 0, 'gone' );
    };
}

done_testing;

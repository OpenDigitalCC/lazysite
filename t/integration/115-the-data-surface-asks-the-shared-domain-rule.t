#!/usr/bin/perl
# SM976 R2 and R4, through the doors (ruled 2026-10-09).
#
# R2, "Unbound cookie manager = unconfined": a cookie manager whose groups bind
# no domain is a whole-instance manager on every surface. The data surface had
# confined it to no table - it saw only tables naming no domain, and could bind
# a table to none - because the control API handed the data module SM648's
# "scopes were resolved" flag rather than the shared rule's notion of
# confinement. t/unit/data/67 holds R4's rule itself; this holds what the
# control API and MCP now hand it.
#
# R4, "Use the shared rule": the cases where the answer changed, as a caller
# sees them - an unbound token or MCP grant reaches a domain serving the
# primary's content (widens); a scoped caller no longer reads another domain's
# safety exports or sets its table's access rule (narrows).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

BEGIN {
    unless ( eval { require DBI; require DBD::SQLite; require YAML::PP; 1 } ) {
        require Test::More;
        Test::More::plan( skip_all => 'DBI / DBD::SQLite / YAML::PP not available' );
    }
}
my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(api ui mcp manage_domains manage_users manage_content manage_data purge);
my @WORK = qw(manage_domains manage_content manage_data purge);
my %CHAN = ( cku => 'ui', cks => 'ui', tku => 'api', mcu => 'mcp' );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub desc { my ($dom) = @_; return "title: t\n" . ( $dom ? "domain: $dom\n" : '' ) . "key: slug\nfields:\n  slug:\n    type: text\n" }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nextensions:\n  - plugins/data.pl\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/db/tables", "$d/lazysite/db/rebuilds" );
$s->add_user('op');
$s->grant( 'op', 'g-op', [ 'ui', 'manage_users', @WORK ], \@ALL );
for my $u ( sort keys %CHAN ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", [ $CHAN{$u}, @WORK ], \@ALL );
}
sub op { my ( $a, $b, $q ) = @_; return $s->call( 'op', $a, ( defined $b ? ( body => $b ) : () ), ( defined $q ? ( query => $q ) : () ) ) }
op( 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } );
op( 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } );
op( 'domain-add', { host => 'mirror.example.org' } );
ok( op( 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks' } )->{ok},
    'setup: cks is scoped to mine' );
my %TABLE = ( t_mine => 'mine.example.org', t_other => 'other.example.org', t_mirror => 'mirror.example.org',
    t_free => undef );
for my $t ( sort keys %TABLE ) {
    spit( "$d/lazysite/db/tables/$t.yaml", desc( $TABLE{$t} ) );
    # SM976 F3: written as an export is written now, carrying its table's domain
    # (t/unit/data/67 holds one written before, which is the primary's).
    spit( "$d/lazysite/db/rebuilds/$t-20260101T000000Z.json",
        encode_json( { lazysite_data => 1, table => $t, key => 'slug', domain => ( $TABLE{$t} // q() ),
                fields => { slug => { type => 'text' } }, rows => [] } ) );
}

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tku mcu);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query ) if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return eval { decode_json( $j->{result}{content}[0]{text} // '' ) } // { ok => 0 };
}

sub seen {
    my ($r) = @_;
    return join ',', sort map { $_->{table} } @{ $r->{tables} || $r->{exports} || [] };
}

subtest 'R2: a cookie manager bound to no domain reaches every table' => sub {
    is( seen( api( 'cku', 'data-tables' ) ), 't_free,t_mine,t_mirror,t_other', 'it lists them all, as the operator does' );
    is( seen( api( 'op', 'data-tables' ) ), 't_free,t_mine,t_mirror,t_other', '(the operator)' );
    ok( api( 'cku', 'data-table', undef, 'action=data-table&table=t_other' )->{ok}, 'it reads one bound to a domain' );
    ok( api( 'cku', 'data-table-save', { table => 'fresh', descriptor => desc('other.example.org') } )->{ok},
        'and binds a new table to any domain' );
};

subtest 'R4 widens: an unbound token or grant reaches a domain serving the primary\'s content' => sub {
    my @t = split /,/, seen( api( 'tku', 'data-tables' ) );
    ok( ( grep { $_ eq 't_mirror' } @t ), 'tku: the mirror\'s table is listed' );
    ok( !( grep { $_ eq 't_mine' || $_ eq 't_other' } @t ), '...and no domain with a root of its own' );
    ok( mcp( 'mcu', 'describe_data_table', { table => 't_mirror' } )->{ok}, 'mcu: the mirror\'s table reads' );
    ok( !mcp( 'mcu', 'describe_data_table', { table => 't_other' } )->{ok}, 'mcu: other\'s still does not' );
};

subtest 'R4 narrows: a scoped caller keeps to its own tables\' rules and exports' => sub {
    is( seen( api( 'cks', 'data-safety-exports' ) ), 't_free,t_mine', 'cks lists its own exports and the instance\'s' );
    my $read = api( 'cks', 'data-safety-export-read', undef, 'action=data-safety-export-read&file=t_other-20260101T000000Z.json' );
    is( $read->{error}, 'no such safety export', 'cks: another domain\'s export is not there' );
    my $acl = api( 'cks', 'data-table-acl-set', { table => 't_other', read => ['@nobody'] } );
    is( $acl->{kind}, 'no_such_table', 'cks: another domain\'s table rule is not its to set' );
    ok( api( 'cks', 'data-table-acl-set', { table => 't_mine', read => ['@nobody'] } )->{ok}, 'cks: its own is' );
    is( seen( mcp( 'mcu', 'list_data_safety_exports', {} ) ), 't_free,t_mirror', 'mcu lists the primary\'s exports only' );
};

done_testing();

#!/usr/bin/perl
# SM842: the destination decides who may configure a handler - on the token
# doors as on the manager's.
#
# SM799 kept the handler actions cookie-only. The release manager reversed it
# (2026-09-11): handler CRUD reaches every surface, and what governs it is the
# capability of where the handler SENDS. This drives the real control API and
# the real MCP server, each with a grant that opens the door (manage_forms) but
# not the destination (manage_data), and then with one that does.
#
# THE REFUSAL IS THE TEST. A fixture whose grant opened everything would pass
# the "allowed" half by construction; the half that proves the rule is the
# table handler refused to a manage_forms grant on each door, with the message
# naming the capability that would work.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path( map { "$docroot/lazysite/$_" } qw(auth forms logs db/tables connectors) );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n";
close $cf;
open my $tf, '>', "$docroot/lazysite/db/tables/leads.yaml" or die $!;
print {$tf} "fields:\n  name:\n    type: text\n";
close $tf;
qx($^X \Q$root/tools/lazysite-users.pl\E --docroot \Q$docroot\E setup-sysop --user sjm pw123456789 2>/dev/null);

sub stub_with {
    my (%caps) = @_;
    my $stub   = "$docroot/users-stub-" . join( "-", sort keys %caps ) . ".pl";
    my $pairs  = join ', ', map { "$_ => $caps{$_}" } sort keys %caps;
    open my $sf, '>', $stub or die $!;
    print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { $pairs } });\n";
    close $sf;
    chmod 0755, $stub;
    return $stub;
}

sub api {
    my ( $stub, $qs, $payload ) = @_;
    my $body = encode_json( $payload || {} );
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Basic ' . encode_base64( 'tester:lzs_tok', '' ),
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => $qs,
        CONTENT_TYPE        => 'application/json',
        CONTENT_LENGTH      => length $body,
        REMOTE_ADDR         => '127.0.0.1',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

sub mcp {
    my ( $stub, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        CONTENT_LENGTH      => length $body,
        LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION  => 'Bearer tester:lzs_tok',
    );
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json($jb) } || {};
    return $r->{result}{structuredContent} // { ok => 0, error => ( $r->{error}{message} // 'no answer' ) };
}

my %table = ( id => 'leads', type => 'table', name => 'Leads', table => 'leads', fields => 'name=name' );

subtest 'the control API: the door opens for manage_forms, the destination does not' => sub {
    my $forms = stub_with( api => 1, manage_forms => 1 );
    my $r     = api( $forms, 'action=handler-save', {%table} );
    ok( !$r->{ok}, 'a manage_forms token cannot make a table handler' );
    like( $r->{error} // '', qr/needs the 'manage_data' permission/, 'and is told what would work' )
        or diag explain $r;
    $r = api( $forms, 'action=handler-save', { id => 'store', type => 'file', name => 'Store' } );
    ok( $r->{ok}, 'but can make a file handler - reversing SM799\'s cookie-only rule' ) or diag explain $r;

    my $data = stub_with( api => 1, manage_data => 1 );
    $r = api( $data, 'action=handler-save', {%table} );
    ok( $r->{ok}, 'a manage_data token can make the table handler' ) or diag explain $r;
    $r = api( $data, 'action=handler-list', {} );
    ok( ( grep { $_->{id} eq 'leads' && $_->{cap} eq 'manage_data' } @{ $r->{handlers} || [] } ),
        'and lists it, saying which capability governs it' );

    my $nav = stub_with( api => 1, manage_nav => 1 );
    ok( !api( $nav, 'action=handler-list', {} )->{ok}, 'a grant with none of the three is refused at the door' );

    $r = api( $forms, 'action=form-targets-save', { form => 'contact', handlers => ['leads'] } );
    ok( $r->{ok}, 'binding a form to a handler that exists needs manage_forms alone' ) or diag explain $r;
    $r = api( $data, 'action=form-targets-save', { form => 'contact', handlers => ['leads'] } );
    ok( !$r->{ok}, 'and manage_data alone may not bind a form' );
};

subtest 'MCP: the same rule, the same message' => sub {
    my $forms = stub_with( mcp => 1, manage_forms => 1 );
    my $r     = mcp( $forms, 'save_handler', { %table, id => 'leads2' } );
    ok( !$r->{ok}, 'a manage_forms grant cannot make a table handler over MCP either' );
    like( $r->{error} // '', qr/needs the 'manage_data' permission/, 'with the same sentence' )
        or diag explain $r;
    my $data = stub_with( mcp => 1, manage_data => 1 );
    $r = mcp( $data, 'save_handler', { %table, id => 'leads2' } );
    ok( $r->{ok}, 'and a manage_data grant can' ) or diag explain $r;
    $r = mcp( $data, 'list_handlers', {} );
    ok( ( grep { $_->{id} eq 'leads2' } @{ $r->{handlers} || [] } ), 'list_handlers opens for it too' );
    $r = mcp( $forms, 'bind_form', { form => 'contact', target => { type => 'webhook', url => 'https://x' } } );
    ok( !$r->{ok}, 'bind_form takes no inline target any more' );
};

done_testing();

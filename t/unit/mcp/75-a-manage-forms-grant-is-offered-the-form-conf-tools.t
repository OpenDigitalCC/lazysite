#!/usr/bin/perl
# SM1392, ruling 152: A manage_forms GRANT IS OFFERED read_file AND write_file,
# FOR A FORM'S OWN CONFIGURATION, AND THE LISTING SAYS SO.
#
# SM1392 made the two tools admit manage_forms on lazysite/forms/<name>.conf
# (the path's own capability, SM1371) and left the listing alone: a grant
# holding manage_forms and not manage_content was admitted to a tool it was
# never offered - SM210's shape. Ruling 152: discovery matches enforcement,
# through ONE declaration on the tool (`cap_path => { manage_forms =>
# 'form_conf' }`) that the gate, _tool_callable and _path_only_for all read.
# The narrowest shape: the two tools, that one path shape, and the description
# of each saying what the grant reaches - never every path-aware tool for
# every path grant.
#
# With the change reverted: the listing offers neither tool to the grant.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir grant_caps run_child);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mcp   = "$root/lazysite-mcp.pl";

sub put {
    my ( $d, $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/forms" );
put( $d, 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( $d, 'lazysite/auth/groups-settings.json', '{"admins":{"label":"Admins","ui":1,"manage_users":1}}' );
put( $d, 'lazysite/forms/handlers.conf', "handlers:\n  - id: inbox\n    type: file\n" );
put( $d, 'lazysite/forms/contact.conf',  "targets:\n  - handler: inbox\n" );
put( $d, 'contact.md', "---\ntitle: Contact\nform: contact\n---\n\nHi.\n" );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}
sub rpc {
    my ( $auth, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params || {} } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{HTTP_AUTHORIZATION}  = $auth;
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? ( eval { decode_json($jb) } // {} ) : {};
}
sub tools_of {
    my ($auth) = @_;
    my $r = rpc( $auth, 'tools/list' );
    return { map { $_->{name} => $_->{description} } @{ $r->{result}{tools} || [] } };
}
sub call {
    my ( $auth, $name, $args ) = @_;
    my $r = rpc( $auth, 'tools/call', { name => $name, arguments => $args } );
    return $r->{result} ? $r->{result}{structuredContent} : { ok => 0, error => $r->{error}{message} // 'no answer' };
}

sub agent {
    my ( $who, @caps ) = @_;
    uapi( { action => 'add', username => $who, password => 'x-long-enough' } );
    uapi( { action => 'settings-set', username => $who, key => 'ui', value => 'off' } );
    grant_caps( $d, $who, 'mcp', @caps );
    my $tok = uapi( { action => 'token', username => $who } )->{token};
    return "Bearer $who:$tok";
}

my $forms   = agent( 'forms',   'manage_forms' );
my $content = agent( 'content', 'manage_content' );
my $none    = agent( 'none',    'analytics' );

subtest 'a manage_forms grant is offered read_file and write_file, and told where' => sub {
    my $t = tools_of($forms);
    ok( $t->{read_file},  'read_file is listed' );
    ok( $t->{write_file}, 'write_file is listed' );
    for my $name (qw(read_file write_file)) {
        like( $t->{$name} // '', qr/callable only on a form's own configuration \(lazysite\/forms\/<name>\.conf\)/,
            "${name}'s note says where" );
        like( $t->{$name} // '', qr/needs the manage_content capability/, '...and what reaches other paths' );
        like( $t->{$name} // '', qr/With manage_forms and not manage_content, this tool reaches a form's own configuration/,
            '...and the description itself says what the grant reaches' );
    }
    ok( !$t->{delete_file} && !$t->{copy_file} && !$t->{create_page} && !$t->{list_files},
        'no other path-aware tool is offered for the path grant' );
};

subtest 'a manage_content grant sees no such note, and a grant with neither sees neither tool' => sub {
    my $t = tools_of($content);
    ok( $t->{read_file} && $t->{read_file} !~ /NOTE: with your current grant/, 'read_file offered outright, no note' );
    my $n = tools_of($none);
    ok( !$n->{read_file} && !$n->{write_file}, 'neither tool is offered to a grant holding neither capability' );
};

subtest 'whoami splits the two off with their reach' => sub {
    my $w = call( $forms, 'whoami' );
    my $r = $w->{tools_by_reach} || {};
    is_deeply( [ sort @{ $r->{path_only} || [] } ], [qw(read_file write_file)], 'path_only is the two tools' );
    like( $r->{path_only_reach}{read_file} // '', qr/form's own configuration/, '...each with its reach' );
    ok( !( grep { $_ eq 'read_file' } @{ $r->{anywhere} || [] } ), 'and not anywhere' );
    like( $r->{note} // '', qr/path_only_reach/, 'the note points at the reach map' );
};

subtest 'the gate reads the same declaration' => sub {
    my $r = call( $forms, 'read_file', { path => '/lazysite/forms/contact.conf' } );
    ok( $r->{ok}, 'the offered tool is admitted on the form conf' ) or diag explain $r;
    my $p = call( $forms, 'read_file', { path => '/contact.md' } );
    ok( !$p->{ok}, '...and refused on a page' );
    like( $p->{error} // '', qr/needs manage_content/, '...for manage_content' );
};

subtest 'describe_capabilities names the two under manage_forms' => sub {
    my $dc = call( $forms, 'describe_capabilities' );
    my @m  = @{ $dc->{capabilities}{manage_forms}{unlocks}{mcp} || [] };
    ok( ( grep { $_ eq 'read_file' } @m ) && ( grep { $_ eq 'write_file' } @m ), 'unlocks.mcp lists them' )
        or diag explain \@m;
};

done_testing;

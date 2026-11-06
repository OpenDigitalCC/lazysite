#!/usr/bin/perl
# SM1371 (ruling 122): manage_forms COVERS A FORM'S OWN .conf FOR WRITING.
#
# WebDAV has admitted lazysite/forms/<name>.conf to manage_forms since 0.8.1.
# MCP's read_file/write_file and the manager's file editor refused it to every
# grant as "inside the reserved lazysite/ tree" - so a grant that could bind a
# form could not open the file the binding is written in, on two of the three
# doors. They now admit it to manage_forms and to nothing else, with the rules
# WebDAV applies: the targets name existing handlers only, and the three files
# under lazysite/forms/ that are not forms stay refused.
#
# With the change reverted, the manage_forms reads and writes below are refused
# as blocked paths, on both doors.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root site_tempdir grant_caps revoke_caps run_child);
use ManagerSession qw(new_site);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mcp   = "$root/lazysite-mcp.pl";

sub put {
    my ( $d, $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $f, '<', "$_[0]/$_[1]" or return ''; local $/; my $t = <$f>; close $f; $t }
sub forms_site {
    my ($d) = @_;
    make_path("$d/lazysite/forms");
    put( $d, 'lazysite/forms/handlers.conf', "handlers:\n  - id: inbox\n    type: file\n" );
    put( $d, 'lazysite/forms/contact.conf',  "targets:\n  - handler: inbox\n" );
    put( $d, 'lazysite/forms/smtp.conf',     "host: mail.example\n" );
    put( $d, 'contact.md', "---\ntitle: Contact\nform: contact\n---\n\nHi.\n" );
}
my $good = "targets:\n  - handler: inbox\nnotify: off\n";

# --- MCP -------------------------------------------------------------------
my $d = site_tempdir();
make_path("$d/lazysite/auth");
put( $d, 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( $d, 'lazysite/auth/groups-settings.json', '{"admins":{"label":"Admins","ui":1,"manage_users":1}}' );
forms_site($d);

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}
sub mcp_call {
    my ( $auth, $name, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $name, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{HTTP_AUTHORIZATION}  = $auth;
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $r && $r->{result} ? $r->{result}{structuredContent}
        : { ok => 0, error => ( $r && $r->{error} ? $r->{error}{message} : 'no answer' ) };
}

uapi( { action => 'add', username => 'agent', password => 'x-long-enough' } );
uapi( { action => 'settings-set', username => 'agent', key => 'ui', value => 'off' } );
grant_caps( $d, 'agent', 'mcp', 'manage_content' );
my $tok    = uapi( { action => 'token', username => 'agent' } )->{token};
my $bearer = "Bearer agent:$tok";
sub mwrite { mcp_call( $bearer, 'write_file', { path => $_[0], content => $_[1] } ) }

subtest 'MCP: without manage_forms the form config is refused' => sub {
    ok( !mwrite( '/lazysite/forms/contact.conf', $good )->{ok}, 'write_file refused' );
    ok( !mcp_call( $bearer, 'read_file', { path => '/lazysite/forms/contact.conf' } )->{ok}, 'read_file refused' );
    unlike( slurp( $d, 'lazysite/forms/contact.conf' ), qr/notify/, 'the file is unchanged' );
};

grant_caps( $d, 'agent', 'mcp', 'manage_content', 'manage_forms' );

subtest 'MCP: manage_forms reads and writes a form\'s own config' => sub {
    my $r = mcp_call( $bearer, 'read_file', { path => '/lazysite/forms/contact.conf' } );
    ok( $r->{ok}, 'read_file' ) or diag explain $r;
    my $w = mwrite( '/lazysite/forms/contact.conf', $good );
    ok( $w->{ok}, 'write_file' ) or diag explain $w;
    like( slurp( $d, 'lazysite/forms/contact.conf' ), qr/notify: off/, '...written' );
};

subtest 'MCP: the binding rules still hold, and the non-form files stay refused' => sub {
    my $bad = mwrite( '/lazysite/forms/contact.conf', "targets:\n  - handler: nowhere\n" );
    ok( !$bad->{ok}, 'a target naming no handler is refused' );
    like( $bad->{error} // '', qr/no handler 'nowhere'/, '...naming it' );
    ok( !mwrite( '/lazysite/forms/contact.conf', "targets:\n  - email: someone\@example.test\n" )->{ok},
        'an inline target is refused' );
    for my $f (qw(smtp handlers schedule)) {
        ok( !mwrite( "/lazysite/forms/$f.conf", "x: y\n" )->{ok}, "$f.conf stays refused to manage_forms" );
    }
    is( slurp( $d, 'lazysite/forms/smtp.conf' ), "host: mail.example\n", 'smtp.conf is untouched' );
};

subtest 'MCP: taken away, refused again at once' => sub {
    revoke_caps( $d, 'agent', 'manage_forms' );
    ok( !mwrite( '/lazysite/forms/contact.conf', $good )->{ok}, 'write_file refused' );
};

# --- the manager's file editor (cookie session) -----------------------------
subtest 'manager UI: the file editor admits the form config to manage_forms only' => sub {
    my $s = new_site( root => $root );
    forms_site( $s->docroot );
    my @ALL = qw(ui manage_content manage_forms);
    $s->add_user('editor');
    $s->add_user('boss');
    $s->grant( 'boss', 'admins', [qw(ui manage_users)], [qw(ui manage_users)] );
    $s->grant( 'editor', 'eds', [qw(ui manage_content)], \@ALL );
    my $save = sub {
        $s->call( 'editor', 'save', query => 'action=save&path=/lazysite/forms/contact.conf',
            body => { content => $_[0] } );
    };
    ok( !$save->($good)->{ok}, 'manage_content alone: refused' );
    $s->grant( 'editor', 'eds', [qw(ui manage_content manage_forms)], \@ALL );
    my $r = $save->($good);
    ok( $r->{ok}, 'with manage_forms: saved' ) or diag explain $r;
    like( slurp( $s->docroot, 'lazysite/forms/contact.conf' ), qr/notify: off/, '...written' );
    my $rd = $s->call( 'editor', 'read', query => 'action=read&path=/lazysite/forms/contact.conf' );
    ok( $rd->{ok}, 'and read' ) or diag explain $rd;
    ok( !$s->call( 'editor', 'save', query => 'action=save&path=/lazysite/forms/smtp.conf',
            body => { content => "x: y\n" } )->{ok}, 'smtp.conf stays refused' );
};

done_testing();

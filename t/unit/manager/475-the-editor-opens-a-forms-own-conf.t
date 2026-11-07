#!/usr/bin/perl
# SM1392: THE MANAGER'S EDITOR OPENS A FORM'S OWN CONF, AND EVERY DOOR NAMES
# manage_forms FOR IT.
#
# SM1371 opened lazysite/forms/<name>.conf to manage_forms over MCP, WebDAV and
# the control API's read and save. The editor page never asked the server: its
# isReservedPath marked every lazysite/ path "system file (read-only)" and
# showed the control-area text, so the one door SM1371 named for people did
# not open. The rule now exempts a form's own conf (and keeps smtp.conf,
# handlers.conf and schedule.conf reserved, as the server does); the Files
# page's open-in-editor link is offered for a .conf as before, so the two
# agree. Over MCP, read_file and write_file on that path asked manage_content
# first, so a caller without it was told "needs manage_content" for a file that
# capability never reaches; they now ask manage_forms, the path's own, as a
# layout path asks the design capabilities, and every other path keeps the
# tool's capability.
#
# With the change reverted: the editor's rule reserves the form conf, and the
# MCP refusal names manage_content.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root site_tempdir grant_caps run_child);
use ManagerSession qw(new_site);
use PageScript     ();

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mcp   = "$root/lazysite-mcp.pl";

my $edit  = PageScript::page_source("$root/starter/manager/edit.md");
my $files = PageScript::page_source("$root/starter/manager/files.md");

# --- the rule's source, read as t/unit/auth/16 reads the cookie split --------
subtest 'the editor\'s reserved-path rule exempts a form\'s own conf in its source' => sub {
    my $reserved = PageScript::extract_function( $edit, 'isReservedPath', 'edit.md' );
    my $formconf = PageScript::try_extract( $edit, 'isFormConfPath' ) // '';
    ok( length $formconf, 'edit.md has isFormConfPath' );
    like( $reserved, qr/isFormConfPath\(p\)\)\s*return false/, 'isReservedPath answers false for a form conf first' );
    like( $formconf, qr{lazysite\\/forms\\/\(\[A-Za-z0-9_-\]\+\)\\\.conf}, 'a form conf is lazysite/forms/<name>.conf' );
    like( $formconf, qr/'smtp'.*'handlers'.*'schedule'/s, '...and smtp, handlers and schedule are not forms' );
};

# --- the rule under node, when node is here ----------------------------------
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 2 unless length $node && -x $node;
    my $dir = tempdir( CLEANUP => 1 );
    my $run = sub {
        my ($js) = @_;
        open my $o, '>', "$dir/t.js" or die $!;
        print {$o} $js;
        close $o;
        my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
        chomp $out;
        return $out;
    };
    my $rule = PageScript::extract_function( $edit, 'isReservedPath', 'edit.md' ) . "\n"
        . ( PageScript::try_extract( $edit, 'isFormConfPath' ) // '' ) . "\n";
    my %want = (
        'lazysite/forms/contact.conf'             => 'open',
        '/lazysite/forms/contact.conf'            => 'open',
        'lazysite/forms/my-form_2.conf'           => 'open',
        'about.md'                                => 'open',
        'lazysite/forms/smtp.conf'                => 'reserved',
        'lazysite/forms/handlers.conf'            => 'reserved',
        'lazysite/forms/schedule.conf'            => 'reserved',
        'lazysite/forms/submissions/contact.jsonl' => 'reserved',
        'lazysite/forms/contact.conf.bak'         => 'reserved',
        'lazysite/forms/sub/contact.conf'         => 'reserved',
        'lazysite/nav.conf'                       => 'reserved',
        'lazysite/lazysite.conf'                  => 'reserved',
        'cgi-bin/lazysite-processor.pl'           => 'reserved',
    );
    subtest 'the editor reserves the control area and opens a form\'s own conf' => sub {
        for my $p ( sort keys %want ) {
            my $out = $run->( $rule . "console.log(isReservedPath(" . encode_json( [$p] ) . "[0]) ? 'reserved' : 'open');" );
            is( $out, $want{$p}, "$p: $want{$p}" );
        }
    };
    subtest 'the Files page offers the editor for a form\'s own conf' => sub {
        my $ext = ( $files =~ /(var TEXT_EXTENSIONS = \{.*?\};)/s )[0];
        ok( $ext, 'TEXT_EXTENSIONS found' ) or return;
        my $js = $ext . "\n" . PageScript::extract_function( $files, 'isEditable', 'files.md' ) . "\n";
        is( $run->( $js . "console.log(isEditable('contact.conf') ? 'link' : 'none');" ), 'link',
            'a .conf gets the open-in-editor link' );
    };
}

# --- MCP: the refusal names the path's own capability ------------------------
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
grant_caps( $d, 'agent', 'mcp', 'analytics' );
my $tok    = uapi( { action => 'token', username => 'agent' } )->{token};
my $bearer = "Bearer agent:$tok";
sub mread  { mcp_call( $bearer, 'read_file',  { path => $_[0] } ) }
sub mwrite { mcp_call( $bearer, 'write_file', { path => $_[0], content => $_[1] } ) }

subtest 'MCP: holding neither, the refusal names manage_forms, the path\'s own capability' => sub {
    for my $r ( mread('/lazysite/forms/contact.conf'), mwrite( '/lazysite/forms/contact.conf', $good ) ) {
        ok( !$r->{ok}, 'refused' );
        like( $r->{error} // '', qr/needs manage_forms/, '...naming manage_forms' );
        unlike( $r->{error} // '', qr/manage_content/, '...and not manage_content' );
    }
    my $page = mread('/contact.md');
    like( $page->{error} // '', qr/needs manage_content/, 'a page still needs manage_content: the general gate stands' );
    my $smtp = mread('/lazysite/forms/smtp.conf');
    ok( !$smtp->{ok}, 'smtp.conf is refused' );
    like( $smtp->{error} // '', qr/needs manage_content/, '...as the tool\'s own capability, not as a form' );
};

grant_caps( $d, 'agent', 'mcp', 'manage_forms' );

subtest 'MCP: manage_forms alone reaches a form\'s own conf, as over WebDAV, and nothing else' => sub {
    my $r = mread('/lazysite/forms/contact.conf');
    ok( $r->{ok}, 'read_file' ) or diag explain $r;
    my $w = mwrite( '/lazysite/forms/contact.conf', $good );
    ok( $w->{ok}, 'write_file' ) or diag explain $w;
    like( slurp( $d, 'lazysite/forms/contact.conf' ), qr/notify: off/, '...written' );
    my $page = mread('/contact.md');
    ok( !$page->{ok}, 'a page is still refused' );
    like( $page->{error} // '', qr/needs manage_content/, '...for manage_content' );
    ok( !mwrite( '/lazysite/forms/smtp.conf', "x: y\n" )->{ok}, 'smtp.conf stays refused' );
    is( slurp( $d, 'lazysite/forms/smtp.conf' ), "host: mail.example\n", '...untouched' );
};

# --- the manager's door: the server's refusal names manage_forms ------------
subtest 'manager UI: a read without manage_forms is refused naming manage_forms, with it the conf opens' => sub {
    my $s = new_site( root => $root );
    forms_site( $s->docroot );
    my @ALL = qw(ui manage_content manage_forms);
    $s->add_user('editor');
    $s->grant( 'editor', 'eds', [qw(ui manage_content)], \@ALL );
    my $rd = $s->call( 'editor', 'read', query => 'action=read&path=/lazysite/forms/contact.conf' );
    ok( !$rd->{ok}, 'manage_content alone: refused' );
    like( $rd->{error} // '', qr/manage_forms/, '...naming manage_forms' );
    $s->grant( 'editor', 'eds', [qw(ui manage_forms)], \@ALL );
    $rd = $s->call( 'editor', 'read', query => 'action=read&path=/lazysite/forms/contact.conf' );
    ok( $rd->{ok}, 'manage_forms alone: read' ) or diag explain $rd;
    like( $rd->{content} // '', qr/handler: inbox/, '...the conf' );
    ok( !$s->call( 'editor', 'read', query => 'action=read&path=/lazysite/forms/smtp.conf' )->{ok},
        'smtp.conf stays refused' );
};

done_testing;

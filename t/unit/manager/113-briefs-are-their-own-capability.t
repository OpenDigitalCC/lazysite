#!/usr/bin/perl
# SM576 part 1: `manage_briefs`. SM575 measured a partner agent reading,
# appending to and permanently deleting ANOTHER agent's brief, holding nothing
# but manage_content. The operator's answer was not ownership - it was to make
# the right separately grantable.
#
# THE MIGRATION THIS ASSERTS is the smaller, reversible one the filing named:
# manage_content keeps brief READS, manage_briefs is required to WRITE. So the
# interesting assertion is not "the new capability works" but the SPLIT - the
# same token, one call refused and the next allowed, with nothing changing but
# which capability it holds.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper               qw(repo_root grant_caps revoke_caps);
use Lazysite::Auth::Settings ();

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $d;

    # Pin the user-management tool this CGI shells to. _tool_path() otherwise
    # resolves `<cgi dir>/../tools/lazysite-users.pl` FIRST, which is a real
    # path outside the checkout when the tree is not at a repo-shaped location -
    # and a stale copy there answers every capability question with a stale
    # answer, silently. Naming it is what the env key is for.
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\nplugins:\n  - plugins/briefs.pl\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;
open my $pg, '>', "$d/about.md" or die $!;
print $pg "---\ntitle: About\n---\n\nAbout us.\n";
close $pg;

uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
grant_caps( $d, 'partner', 'manage_content', 'api' );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
ok( $tok, 'partner has a token' );

sub call {
    my ( $qs, %extra ) = @_;
    return mapi( $d, QUERY_STRING => $qs,
        HTTP_AUTHORIZATION => basic( 'partner', $tok ), %extra );
}

sub post {
    my ( $qs, $body ) = @_;
    return call( $qs, REQUEST_METHOD => 'POST', body => $body );
}

# --- 1. manage_content alone: reads yes, writes no ---------------------------
# The migration in one pair of calls. A site that has always granted
# manage_content must not silently lose brief access - so the read stands - and
# must not keep the write, which is the whole filing.
my $read = call('action=brief-read&path=/about');
ok( $read->{ok}, 'manage_content still READS a brief - nothing breaks at upgrade' )
    or diag( explain $read );

my $list = call('action=briefs-list');
ok( $list->{ok}, 'and still lists them' ) or diag( explain $list );

my $append = post( 'action=brief-append&path=/about', encode_json( { entry => 'why' } ) );
ok( !$append->{ok}, 'manage_content alone is REFUSED brief-append' )
    or diag( explain $append );

my $del = post( 'action=brief-delete&path=/about', '{}' );
ok( !$del->{ok}, 'and refused brief-delete' ) or diag( explain $del );

# --- 2. manage_briefs: the write is admitted ---------------------------------
# Same token, same call. Only the grant moves.
revoke_caps( $d, 'partner', 'manage_content' );
grant_caps( $d, 'partner', 'manage_briefs', 'api' );

my $append2 = post( 'action=brief-append&path=/about', encode_json( { entry => 'why' } ) );
ok( $append2->{ok}, 'manage_briefs APPENDS' ) or diag( explain $append2 );

my $read2 = call('action=brief-read&path=/about');
ok( $read2->{ok}, 'and reads - the write grant is not a narrower read grant' )
    or diag( explain $read2 );

# --- 3. the two channels gate it the same way --------------------------------
# SM566's lesson: a capability that means one thing on the API and another over
# MCP is a gap nobody decided. t/lint/23 pairs the twins; this pins the MCP
# table itself, because a `cap` left at manage_content there would leave the
# whole filing bypassable through the other door.
my $mcp = slurp("$root/lazysite-mcp.pl");
my ($tools) = $mcp =~ /my %TOOLS = \((.*)\n\);/s;
my %cap;
{
    my @part = split /^    ([a-z_]+)\s*=>\s*\{/m, ( $tools // '' );
    shift @part;
    while ( my ( $name, $chunk ) = splice @part, 0, 2 ) {
        $cap{$name} = $chunk;
    }
}
like( $cap{append_brief} // '', qr/cap\s*=>\s*'manage_briefs'/,
    'MCP append_brief is gated on manage_briefs' );
like( $cap{delete_brief} // '', qr/cap\s*=>\s*'manage_briefs'/,
    'MCP delete_brief too' );
like( $cap{read_brief} // '', qr/cap\s*=>\s*'manage_briefs'/,
    'MCP read_brief names manage_briefs as its gate' );
like( $cap{read_brief} // '', qr/cap_also\s*=>\s*'manage_content'/,
    'and admits manage_content as well - the reads keep working' );
like( $cap{list_briefs} // '', qr/cap_also\s*=>\s*'manage_content'/,
    'as does list_briefs' );

# --- 4. the plugin owns it, and the mirror is a mirror -----------------------
# ADR 0009: the plugin is the one place that says what it owns. t/lint/76 does
# the discovering; this asserts the declaration exists at all, because a lint
# that finds no declarations passes while checking nothing.
my $decl = eval { decode_json(`$^X \Q$root/plugins/briefs.pl\E --describe 2>/dev/null`) };
ok( ref $decl eq 'HASH', 'the briefs plugin answers --describe' );
is_deeply( ( $decl || {} )->{owns}{capabilities}, ['manage_briefs'],
    'and DECLARES manage_briefs, as the data plugin declares manage_data' );

my %cap_key = map { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
ok( $cap_key{manage_briefs}, 'manage_briefs is mirrored in @CAP_KEYS' );

done_testing();

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return <$fh>;
}

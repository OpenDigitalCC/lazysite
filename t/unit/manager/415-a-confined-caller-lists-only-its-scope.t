#!/usr/bin/perl
# SM1308 (ruling 47, T-01): the manager API's twins of MCP list_files and
# list_pages answer a caller confined to a scope from its scope, as MCP does.
#
# `list` with an EMPTY path listed the docroot: $path was '', action_list read
# that as '/', and the scope check skips an empty path. With no path at all it
# was refused, its '/' default reaching the scope check. `pages` takes no path,
# so the scope check had nothing to inspect, and a caller confined to one domain
# read every page name on the instance - over a cookie, and over a token. Now
# `list` naming no folder answers the scope roots (Files::action_list_scope_roots,
# MCP's function), and `pages` the pages within the scope.
#
# With the fix reverted, the empty path names /other, no path is refused, and
# `pages` names /other/b on both channels. The named folders, inside and outside
# the scope, and the unconfined callers are the controls.
use strict;
use warnings;
use Test::More;
use JSON::PP     qw(encode_json decode_json);
use File::Path   qw(make_path);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $api = repo_root() . '/lazysite-manager-api.pl';
plan skip_all => 'manager api missing' unless -f $api;

sub put {
    my ( $d, $rel, $text ) = @_;
    my ($dir) = "$d/$rel" =~ m{\A(.*)/[^/]+\z};
    make_path($dir);
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub paths { return [ sort map { $_->{path} } @{ $_[0]{entries} || [] } ] }

# --- a signed-in editor confined to one domain's content root ---------------
my @ALL = qw(ui manage_domains manage_users manage_config manage_content);
my $s   = new_site( root => repo_root() );
my $d   = $s->docroot;
put( $d, 'index.md',         "---\ntitle: Home\n---\nHome.\n" );
put( $d, 'sites/mine/a.md',  "---\ntitle: A\n---\nA.\n" );
put( $d, 'other/b.md',       "---\ntitle: B\n---\nB.\n" );
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains manage_users manage_config manage_content)], \@ALL );
$s->add_user('ed');
$s->grant( 'ed', 'editors', [qw(ui manage_content)], \@ALL );
{
    my $r = $s->call( 'boss', 'domain-add', body => { host => 'mine.example.org', content_root => 'sites/mine',
            site_url => 'https://mine.example.org', site_name => 'Mine' } );
    ok( $r->{ok}, 'set up the domain' ) or diag explain $r;
    $r = $s->call( 'boss', 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'editors' } );
    ok( $r->{ok}, 'and confine the editors to it' ) or diag explain $r;
}

subtest 'list naming no folder is the scope roots' => sub {
    for my $q ( 'action=list', 'action=list&path=' ) {
        my $r = $s->call( 'ed', 'list', query => $q );
        ok( $r->{ok}, "$q is answered" ) or diag explain $r;
        is_deeply( paths($r), ['/sites/mine'], "$q lists the scope root alone" ) or diag explain $r;
    }
    my $w = $s->call( 'boss', 'list', query => 'action=list&path=' );
    ok( ( grep { $_ eq '/other' } @{ paths($w) } ), 'the unconfined operator is still shown the docroot (control)' );
};

subtest 'list naming a folder: outside refused, inside listed (controls)' => sub {
    my $out = $s->call( 'ed', 'list', query => 'action=list&path=/other' );
    ok( !$out->{ok}, 'a folder outside the scope is refused' );
    my $in = $s->call( 'ed', 'list', query => 'action=list&path=/sites/mine' );
    ok( $in->{ok}, 'a folder inside it is listed' ) or diag explain $in;
    ok( ( grep { $_ eq '/sites/mine/a.md' } @{ paths($in) } ), '...with its files' );
};

subtest 'pages answers a confined editor the pages within its scope' => sub {
    my $r = $s->call( 'ed', 'pages' );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    my @u = @{ $r->{urls} || [] };
    ok( ( grep { $_ eq '/sites/mine/a' } @u ), 'a page in the scope is listed' );
    is_deeply( [ grep { !m{^/sites/mine/} } @u ], [], 'and no page outside it' ) or diag explain \@u;
    my $w = $s->call( 'boss', 'pages' );
    ok( ( grep { $_ eq '/other/b' } @{ $w->{urls} || [] } ), 'the operator sees every page (control)' );
};

# --- a token confined to a folder --------------------------------------------
subtest 'pages answers a confined token the pages within its scope' => sub {
    my $t = new_site( root => repo_root() )->docroot;
    put( $t, 'content/mine/a.md', "---\ntitle: A\n---\nA.\n" );
    put( $t, 'other/b.md',        "---\ntitle: B\n---\nB.\n" );
    put( $t, 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my %caps = ( api => 1, manage_content => 1 );
$caps{dav_scopes} = ['content/mine'] if ( $r->{username} // '' ) eq 'agent';
print encode_json({ ok => 1, settings => \%caps });
STUB
    chmod 0755, "$t/users-stub.pl";
    my $tok = sub {
        my ($user) = @_;
        local %ENV = %ENV;
        delete @ENV{qw(HTTP_COOKIE HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_X_REMOTE_GROUPS HTTP_X_CSRF_TOKEN)};
        $ENV{DOCUMENT_ROOT}       = $t;
        $ENV{REQUEST_METHOD}      = 'GET';
        $ENV{QUERY_STRING}        = 'action=pages';
        $ENV{CONTENT_LENGTH}      = 0;
        $ENV{LAZYSITE_USERS_TOOL} = "$t/users-stub.pl";
        $ENV{HTTP_AUTHORIZATION}  = 'Basic ' . encode_base64( "$user:lzs_tok", '' );
        my $out = run_child( [ $^X, $api ], stdin => '' )->{out};
        my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
        my $r = eval { decode_json( $jb // '' ) };
        return ref $r eq 'HASH' ? $r : { _raw => $out };
    };
    my $r = $tok->('agent');
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    my @u = @{ $r->{urls} || [] };
    ok( ( grep { $_ eq '/content/mine/a' } @u ), 'a page in the scope is listed' );
    is_deeply( [ grep { !m{^/content/mine/} } @u ], [], 'and no page outside it' ) or diag explain \@u;
    my $w = $tok->('wide');
    ok( ( grep { $_ eq '/other/b' } @{ $w->{urls} || [] } ), 'a token with no scope sees every page (control)' );
};

done_testing;

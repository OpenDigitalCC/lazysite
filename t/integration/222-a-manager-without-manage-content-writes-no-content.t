#!/usr/bin/perl
# SM1057, ruled 2026-10-12 "Require manage_content": on the manager API's cookie
# door a content write needs manage_content, as WebDAV and MCP already require,
# and the file's rule still applies on top.
#
# Before the ruling the content writes (save, delete, move, copy, file-upload,
# mkdir, migrate-to-local, lock, unlock, renew-lock) carried no capability on
# this channel: they self-authorised against the file's rule, and a path no
# rule governs admits every writer. So an account holding `ui` and nothing else
# - an analytics viewer, say - overwrote any unruled page, while the same
# account over WebDAV or MCP was refused. A `ui`-only account is now read-only
# in the manager; the engine's own tree (lazysite/...) keeps the capabilities
# that govern it (manage_nav for nav.conf, here as the control).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path     qw(make_path);
use ManagerSession qw(new_site);
use TestHelper     qw(repo_root);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(ui manage_users manage_content manage_config manage_nav);

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmanager: enabled\n" );
my $d = $s->docroot;
make_path("$d/docs");
spit( "$d/index.md",          "# home\n" );
spit( "$d/about.md",          "# about\n" );
spit( "$d/docs/guide.md",     "# guide\n" );
spit( "$d/owned.md",          "# owned\n" );
spit( "$d/lazysite/nav.conf", "Home | /\n" );

$s->add_user( 'sysop', 'pw-sysop-0123456789' );
$s->grant( 'sysop', 'sysops', [qw(ui manage_users manage_content manage_config manage_nav)], \@ALL );
$s->add_user( 'viewer', 'pw-viewer-0123456789' );
$s->grant( 'viewer', 'viewers', ['ui'], \@ALL );
$s->add_user( 'navver', 'pw-navver-0123456789' );
$s->grant( 'navver', 'navvers', [qw(ui manage_nav)], \@ALL );
$s->add_user( 'editor', 'pw-editor-0123456789' );
$s->grant( 'editor', 'editors', [qw(ui manage_content)], \@ALL );

# A rule that names the viewer as owner and writer: the rule admits it, the
# missing capability does not.
my $r0 = $s->call( 'sysop', 'acl-set', query => 'action=acl-set&path=owned.md',
    body => { owner => 'viewer', write => ['viewer'] } );
ok( $r0->{ok}, 'the sysop gives the viewer a rule on owned.md' ) or diag explain $r0;
my $r1 = $s->call( 'sysop', 'acl-set', query => 'action=acl-set&path=docs',
    body => { write => ['@sysops'] } );
ok( $r1->{ok}, 'and rules docs/ to the sysops' ) or diag explain $r1;

my %before = map { $_ => slurp("$d/$_") } qw(about.md docs/guide.md owned.md index.md);

sub refused_for_content {
    my ( $r, $what ) = @_;
    ok( !$r->{ok}, "$what is refused" ) or diag explain $r;
    like( $r->{error} // '', qr/manage_content/, "... for want of manage_content ($what)" );
    return;
}

# --- a `ui`-only account writes no content --------------------------------------
refused_for_content( $s->call( 'viewer', 'save', query => 'action=save&path=/about.md',
        body => { content => "# viewer was here\n" } ), 'save of an unruled page' );
refused_for_content( $s->call( 'viewer', 'save', query => 'action=save&path=/new.md',
        body => { content => "# new\n" } ), 'save of a new page' );
refused_for_content( $s->call( 'viewer', 'save', query => 'action=save&path=/owned.md',
        body => { content => "# mine\n" } ), 'save of a page whose rule names it' );
refused_for_content( $s->call( 'viewer', 'delete', query => 'action=delete&path=/about.md', body => {} ),
    'delete' );
refused_for_content( $s->call( 'viewer', 'mkdir', query => 'action=mkdir&path=/zz-dir', body => {} ),
    'mkdir' );
refused_for_content(
    $s->call( 'viewer', 'move', query => 'action=move&path=/about.md&to=/zz-moved.md', body => {} ),
    'move' );
refused_for_content(
    $s->call( 'viewer', 'copy', query => 'action=copy&path=/index.md&to=/zz-copy.md', body => {} ),
    'copy' );
refused_for_content( $s->call( 'viewer', 'file-upload', query => 'action=file-upload&path=/', body => {} ),
    'file-upload' );
refused_for_content(
    $s->call( 'viewer', 'migrate-to-local', query => 'action=migrate-to-local&path=/about.md', body => {} ),
    'migrate-to-local' );
for my $act (qw(lock unlock renew-lock)) {
    refused_for_content( $s->call( 'viewer', $act, query => "action=$act&path=/about.md", body => {} ),
        $act );
}

is( slurp("$d/$_"), $before{$_}, "$_ is unchanged" ) for sort keys %before;
ok( !-e "$d/$_", "no $_ was created" ) for qw(new.md zz-dir zz-moved.md zz-copy.md);

# --- and still reads -----------------------------------------------------------
my $rd = $s->call( 'viewer', 'read', query => 'action=read&path=/about.md' );
ok( $rd->{ok}, 'the ui-only account still reads a page' ) or diag explain $rd;

# --- the engine tree keeps its own capability ----------------------------------
my $nv = $s->call( 'navver', 'save', query => 'action=save&path=/lazysite/nav.conf',
    body => { content => "Home | /\nAbout | /about\n" } );
ok( $nv->{ok}, 'a manage_nav holder still saves nav.conf by path without manage_content' )
    or diag explain $nv;

# --- manage_content writes; the rule still applies on top ----------------------
my $ed = $s->call( 'editor', 'save', query => 'action=save&path=/about.md',
    body => { content => "# about, edited\n" } );
ok( $ed->{ok}, 'a manage_content holder saves an unruled page' ) or diag explain $ed;
my $er = $s->call( 'editor', 'save', query => 'action=save&path=/docs/guide.md',
    body => { content => "# guide, edited\n" } );
ok( !$er->{ok}, 'and is still refused a page whose rule does not name it' );
is( $er->{kind} // '',         'permission',             '... by the rule' );
is( slurp("$d/docs/guide.md"), $before{'docs/guide.md'}, 'docs/guide.md is unchanged' );

done_testing();

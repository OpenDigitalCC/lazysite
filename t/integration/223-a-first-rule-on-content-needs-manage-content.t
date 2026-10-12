#!/usr/bin/perl
# SM1057, ruled 2026-10-12 "Require manage_content" (the second ruling): on the
# manager API's cookie door, an acl-set that creates the FIRST rule on a content
# path that has none needs manage_content from a non-operator - as the token and
# MCP doors already require.
#
# Creating a first rule was authorised by "write access to the file", which a
# path no rule governs grants to every writer - so after n541 an account holding
# `ui` alone, read-only for content, could still claim an unruled page as its
# owner with a write list naming only itself, and lock the editors out of it.
# The ownership rule for an EXISTING rule is unchanged: its owner changes it.
# The engine's own tree is exempt as it is for content writes.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
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

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmanager: enabled\n" );
my $d = $s->docroot;
spit( "$d/$_.md",             "# $_\n" ) for qw(index about owned edited);
spit( "$d/lazysite/nav.conf", "Home | /\n" );

# The operator (SM991: a member of the operator group setup-sysop makes),
# who may name a rule's owner.
$s->users( 'setup-sysop', '--user', 'sysop', 'pw-sysop-0123456789' );
$s->add_user( 'viewer', 'pw-viewer-0123456789' );
$s->grant( 'viewer', 'viewers', ['ui'], \@ALL );
$s->add_user( 'navver', 'pw-navver-0123456789' );
$s->grant( 'navver', 'navvers', [qw(ui manage_nav)], \@ALL );
$s->add_user( 'editor', 'pw-editor-0123456789' );
$s->grant( 'editor', 'editors', [qw(ui manage_content)], \@ALL );

# An existing rule the viewer owns.
my $own = $s->call( 'sysop', 'acl-set', query => 'action=acl-set&path=owned.md',
    body => { owner => 'viewer', write => ['viewer'] } );
ok( $own->{ok}, 'the sysop gives the viewer a rule on owned.md' ) or diag explain $own;

sub rules {
    open my $fh, '<', "$d/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = <$fh>;
    close $fh;
    return JSON::PP::decode_json($j);
}

# --- a ui-only account creates no first rule on content -------------------------
for my $p (qw(about.md /)) {
    my $r = $s->call( 'viewer', 'acl-set', query => "action=acl-set&path=$p", body => { write => ['viewer'] } );
    ok( !$r->{ok}, "a ui-only account cannot create the first rule on $p" ) or diag explain $r;
    like( $r->{error} // '', qr/manage_content/, '... for want of manage_content' );
}
ok( !exists rules()->{'about.md'}, 'no rule was written for about.md' );
ok( !exists rules()->{'/'},        'nor a site-wide one' );

# --- the ownership rule for an existing rule is unchanged ------------------------
my $ch = $s->call( 'viewer', 'acl-set', query => 'action=acl-set&path=owned.md',
    body => { write => [ 'viewer', '@editors' ] } );
ok( $ch->{ok}, 'the owner still changes its own rule without manage_content' ) or diag explain $ch;

# --- the engine tree is exempt --------------------------------------------------
my $nv = $s->call( 'navver', 'acl-set', query => 'action=acl-set&path=lazysite/nav.conf',
    body => { write => ['navver'] } );
ok( $nv->{ok}, 'a first rule on lazysite/nav.conf needs no manage_content' ) or diag explain $nv;

# --- manage_content creates one -------------------------------------------------
my $ed = $s->call( 'editor', 'acl-set', query => 'action=acl-set&path=edited.md',
    body => { write => [ 'editor', '@editors' ] } );
ok( $ed->{ok}, 'a manage_content holder creates the first rule on a page' ) or diag explain $ed;
is( rules()->{'edited.md'}{owner}, 'editor', '... and owns it' );

done_testing();

#!/usr/bin/perl
# SM1414 (ruling 169): a member saves content over their own signed-in session.
#
# SM1057 shut the manager API's cookie door on every non-operator session without
# `ui`, so a member app's authors - members without the manager - could not save
# a post at all. write_content opens the door for read, save, mkdir, move and
# delete, and nothing else, under two controls SM1057's two causes ask for:
#
#   1. a write lands only where the rule governing the path names the caller or
#      their group as a writer; a path no rule governs is refused;
#   2. the paths sent are inside the content root of the domain the session is
#      signed in on, and the rule key is the one that tree's files use.
#
# The site has two domains with content roots and the primary; the rules are
# keyed by the docroot-relative paths acl-set writes. `author` holds
# write_content alone; `member` holds nothing (SM1057's refusal still answers it).
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

my ( $A, $B ) = ( 'blog-a.example.org', 'blog-b.example.org' );
my @ALL = qw(manager ui manage_users manage_content manage_config write_content);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmanager: enabled\n"
        . "alias_hosts: $A, $B\n"
        . "alias.$A.content_root: sites/a\nalias.$B.content_root: sites/b\n" );
my $d = $s->docroot;
make_path( "$d/sites/a/post", "$d/sites/a/news", "$d/sites/a/pages", "$d/sites/b/post", "$d/post" );
spit( "$d/index.md",            "# primary\n" );
spit( "$d/sites/a/index.md",    "# a\n" );
spit( "$d/sites/a/news/n.md",   "# news\n" );
spit( "$d/sites/a/pages/p.md",  "# page\n" );
spit( "$d/sites/a/post/old.md", "# an old post\n" );
spit( "$d/sites/b/index.md",    "# b\n" );

$s->add_user( 'sysop', 'pw-sysop-0123456789' );
$s->grant( 'sysop', 'sysops', [qw(manager ui manage_users manage_content manage_config)], \@ALL );
$s->add_user( 'author', 'pw-author-0123456789' );
$s->grant( 'author', 'writers', ['write_content'], \@ALL );
$s->add_user( 'member', 'pw-member-0123456789' );

for my $rule (
    [ 'sites/a/post', { write => [ '@writers', '@sysops' ] } ],
    [ 'sites/a/news', { write => ['@sysops'] } ],
    [ 'sites/b/post', { write => ['@writers'] } ],
    [ 'post',         { write => ['@writers'] } ],
    )
{
    my $r = $s->call( 'sysop', 'acl-set', query => "action=acl-set&path=$rule->[0]", body => $rule->[1] );
    ok( $r->{ok}, "rule set on $rule->[0]" ) or diag explain $r;
}

sub as {
    my ( $who, $host, $action, %o ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    delete local $ENV{HTTP_HOST} unless defined $host;
    return $s->call( $who, $action, groups => 1, %o );
}

subtest 'a write_content member saves where a rule names them, in its own domain' => sub {
    my $r = as( 'author', $A, 'save', query => 'action=save&path=/post/hello.md',
        body => { content => "# hello\n" } );
    ok( $r->{ok}, 'the save on the domain is served' ) or diag explain $r;
    is( slurp("$d/sites/a/post/hello.md"), "# hello\n", '... and lands in the domain\'s tree' );
    ok( !-e "$d/post/hello.md",         '... not in the primary\'s' );
    ok( !-e "$d/sites/b/post/hello.md", '... nor the other domain\'s' );

    my $rd = as( 'author', $A, 'read', query => 'action=read&path=/post/old.md' );
    ok( $rd->{ok}, 'a read of the domain\'s post is served' ) or diag explain $rd;
    like( $rd->{content} // '', qr/an old post/, '... from the domain\'s tree' );

    my $m = as( 'author', $A, 'mkdir', query => 'action=mkdir&path=/post/2026', body => {} );
    ok( $m->{ok}, 'mkdir under the named folder' ) or diag explain $m;
    ok( -d "$d/sites/a/post/2026", '... in the domain' );
    my $mv = as( 'author', $A, 'move', query => 'action=move&path=/post/hello.md&to=/post/2026/hello.md',
        body => {} );
    ok( $mv->{ok}, 'move within the named folder' ) or diag explain $mv;
    ok( -f "$d/sites/a/post/2026/hello.md", '... landed in the domain' );
    my $dl = as( 'author', $A, 'delete', query => 'action=delete&path=/post/2026/hello.md', body => {} );
    ok( $dl->{ok}, 'delete under the named folder' ) or diag explain $dl;
    ok( !-e "$d/sites/a/post/2026/hello.md", '... and the file is gone' );

    my $b = as( 'author', $B, 'save', query => 'action=save&path=/post/b.md',
        body => { content => "# on b\n" } );
    ok( $b->{ok}, 'on the other domain the same path is served' ) or diag explain $b;
    is( slurp("$d/sites/b/post/b.md"), "# on b\n", '... and lands in that domain\'s tree' );

    my $p = as( 'author', undef, 'save', query => 'action=save&path=/post/p.md',
        body => { content => "# primary post\n" } );
    ok( $p->{ok}, 'on the primary it is served under the primary\'s rule' ) or diag explain $p;
    is( slurp("$d/post/p.md"), "# primary post\n", '... in the primary\'s tree' );
};

subtest 'a write is refused where a rule names someone else or no rule governs' => sub {
    my %before = map { $_ => slurp("$d/$_") } qw(sites/a/news/n.md sites/a/pages/p.md sites/a/index.md);
    for my $c (
        [ save   => '/news/n.md',    'other',      { content => "# x\n" } ],
        [ save   => '/news/new.md',  'other',      { content => "# x\n" } ],
        [ save   => '/pages/p.md',   'ungoverned', { content => "# x\n" } ],
        [ save   => '/index.md',     'ungoverned', { content => "# x\n" } ],
        [ save   => '/pages/new.md', 'ungoverned', { content => "# x\n" } ],
        [ mkdir  => '/pages/sub',    'ungoverned', {} ],
        [ delete => '/news/n.md',    'other',      {} ],
        [ delete => '/pages/p.md',   'ungoverned', {} ],
        )
    {
        my ( $act, $p, $why, $body ) = @$c;
        my $r = as( 'author', $A, $act, query => "action=$act&path=$p", body => $body );
        ok( !$r->{ok}, "$act $p is refused ($why)" ) or diag explain $r;
        is( $r->{kind} // '', 'permission', '... as a permission refusal' );
        like( $r->{error} // '',
            $why eq 'other' ? qr/does not name you or your group/ : qr/No access rule governs/,
            '... saying which' );
        unlike( $r->{error} // '', qr{sites/a}, '... naming the path as the member sent it' );
    }
    my $mv = as( 'author', $A, 'move', query => 'action=move&path=/post/old.md&to=/pages/old.md', body => {} );
    ok( !$mv->{ok}, 'a move to a path no rule governs is refused' ) or diag explain $mv;
    ok( -f "$d/sites/a/post/old.md", '... and the source stays' );
    my $mv2 = as( 'author', $A, 'move', query => 'action=move&path=/news/n.md&to=/post/n.md', body => {} );
    ok( !$mv2->{ok}, 'a move from a folder whose rule names someone else is refused' ) or diag explain $mv2;
    is( slurp("$d/$_"), $before{$_}, "$_ is unchanged" ) for sort keys %before;
    ok( !-e "$d/sites/a/$_", "no $_ was made" ) for qw(news/new.md pages/new.md pages/sub pages/old.md);

    my $x = as( 'author', undef, 'save', query => 'action=save&path=/sites/a/post/y.md',
        body => { content => "# x\n" } );
    ok( !$x->{ok}, 'from the primary, the domain\'s tree is not reached' ) or diag explain $x;
    ok( !-e "$d/sites/a/post/y.md", '... and nothing was written there' );

    my $e = as( 'author', $A, 'save', query => 'action=save&path=/lazysite/nav.conf',
        body => { content => "x\n" } );
    ok( !$e->{ok}, 'the engine\'s own tree is never reached' ) or diag explain $e;
    like( $e->{error} // '', qr/engine's own tree/, '... by the door\'s own refusal' );
    my $t = as( 'author', $A, 'save', query => 'action=save&path=/post/../news/n.md',
        body => { content => "x\n" } );
    ok( !$t->{ok}, 'a climbing path is refused' );
};

subtest 'every action outside the set is refused' => sub {
    for my $c (
        [ 'acl-set', query => 'action=acl-set&path=/post', body => { write => ['author'] } ],
        [ 'config-read' ],
        [ 'config-set', query => 'action=config-set', body => { key => 'site_name', value => 'x' } ],
        [ 'users', query => 'action=users', body => { action => 'list' } ],
        [ 'list', query => 'action=list&path=/post' ],
        [ 'copy', query => 'action=copy&path=/post/old.md&to=/post/copy.md', body => {} ],
        [ 'lock', query => 'action=lock&path=/post/old.md', body => {} ],
        )
    {
        my ( $act, %o ) = @$c;
        my $r = as( 'author', $A, $act, %o );
        ok( !$r->{ok}, "$act is refused" ) or diag explain $r;
        like( $r->{error} // '', qr/does not have manager access.*write_content permission reaches/s,
            '... by the manager gate, which names the set' );
    }
    ok( !-e "$d/sites/a/post/copy.md", 'nothing was copied' );
};

subtest 'an account without write_content or ui is refused as SM1057 refuses it' => sub {
    for my $c ( [ save => '/post/m.md', { content => "# m\n" } ], [ read => '/post/old.md' ] ) {
        my ( $act, $p, $body ) = @$c;
        my $r = as( 'member', $A, $act, query => "action=$act&path=$p", ( $body ? ( body => $body ) : () ) );
        ok( !$r->{ok}, "member's $act is refused" ) or diag explain $r;
        like( $r->{error} // '', qr/does not have manager access/, '... by the manager gate' );
        unlike( $r->{error} // '', qr/write_content/, '... which says nothing of a door it does not hold' );
    }
    ok( !-e "$d/sites/a/post/m.md" && !-e "$d/post/m.md", 'nothing was written' );
};

done_testing();

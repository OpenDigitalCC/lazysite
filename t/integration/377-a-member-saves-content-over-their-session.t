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

my ( $A, $B, $C ) = ( 'blog-a.example.org', 'blog-b.example.org', 'blog-c.example.org' );
my @ALL = qw(manager ui manage_users manage_content manage_config write_content);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmanager: enabled\n"
        . "alias_hosts: $A, $B, $C\n"
        . "alias.$A.content_root: sites/a\nalias.$B.content_root: sites/b\n"
        . "alias.$C.content_root: sites/a/c\n" );
my $d = $s->docroot;
make_path( "$d/sites/a/post", "$d/sites/a/news", "$d/sites/a/pages", "$d/sites/b/post", "$d/post",
    "$d/sites/a/drafts", "$d/sites/a/members", "$d/sites/a/c" );
spit( "$d/sites/a/drafts/d.md",  "# a draft\n" );
spit( "$d/sites/a/members/m.md", "# members only\n" );
spit( "$d/sites/a/c/index.md",   "# c\n" );
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
    # SM1414 (ruling 173): for the listings - a protected folder naming the
    # author's group, one naming someone else, and a domain nested in A's tree
    # whose rule names the author (so only the domain keeps it out).
    [ 'sites/a/drafts',  { read => [ '@writers', '@sysops' ], write => ['@writers'] } ],
    [ 'sites/a/members', { read => ['@sysops'] } ],
    [ 'sites/a/c',       { write => ['@writers'] } ],
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

# n776 (SM1414): a write's answer names the path on the member's site, as the
# listing does - never the docroot path with the domain's folder in it.
subtest 'a write answers the path on the member\'s own site' => sub {
    my $sv = as( 'author', $A, 'save', query => 'action=save&path=/post/where.md',
        body => { content => "# where\n" } );
    ok( $sv->{ok}, 'a save on the domain' ) or diag explain $sv;
    is( $sv->{path}, '/post/where.md', '... answers the path the member sent' );
    my $mk = as( 'author', $A, 'mkdir', query => 'action=mkdir&path=/post/2027', body => {} );
    is( $mk->{path}, '/post/2027', 'a mkdir answers the site\'s path' ) or diag explain $mk;
    my $mv = as( 'author', $A, 'move', query => 'action=move&path=/post/where.md&to=/post/2027/where.md',
        body => {} );
    is( $mv->{from}, '/post/where.md',      'a move answers where from on the site' ) or diag explain $mv;
    is( $mv->{to},   '/post/2027/where.md', '... and where to' );
    my $dl = as( 'author', $A, 'delete', query => 'action=delete&path=/post/2027/where.md', body => {} );
    is( $dl->{path}, '/post/2027/where.md', 'a delete answers the site\'s path' ) or diag explain $dl;
    unlike( join( ' ', map { $_ // '' } $sv->{path}, $mk->{path}, $mv->{from}, $mv->{to}, $dl->{path} ),
        qr{sites/a}, 'no answer names the folder holding the domain' );

    my $p = as( 'author', undef, 'save', query => 'action=save&path=/post/p2.md',
        body => { content => "# primary\n" } );
    is( $p->{path}, '/post/p2.md', 'on the primary (the docroot) the path is the same' ) or diag explain $p;
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
        [ 'acl-get', query => 'action=acl-get&path=/post' ],
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

# SM1414 (ruling 173): list joins the set. The names a listing shows, sorted.
sub names_of { my ($r) = @_; return [ sort map { $_->{name} } @{ $r->{entries} || [] } ] }

subtest 'a listing shows the entries a rule lets the member read, by the site\'s paths' => sub {
    my $r = as( 'author', $A, 'list', query => 'action=list&path=/' );
    ok( $r->{ok}, 'the domain\'s root is listed' ) or diag explain $r;
    is_deeply( names_of($r), [qw(drafts news post)],
        '... showing the folders a rule governs and lets the author read, and no unruled entry' )
        or diag explain $r;
    is( $r->{path}, '/', '... named as the member sent it' );
    ok( !exists $r->{address_profiles}, '... carrying no picker lists' );
    my ($post) = grep { $_->{name} eq 'post' } @{ $r->{entries} || [] };
    is( $post->{path} // '', '/post', '... each entry by its path on this site' );

    my $none = as( 'author', $A, 'list', query => 'action=list' );
    is_deeply( names_of($none), names_of($r), 'a listing naming no folder lists the domain\'s root' )
        or diag explain $none;

    my $p = as( 'author', $A, 'list', query => 'action=list&path=/post' );
    ok( $p->{ok}, 'a folder the rule names is listed' ) or diag explain $p;
    my ($old) = grep { $_->{name} eq 'old.md' } @{ $p->{entries} || [] };
    is( $old->{path} // '', '/post/old.md', '... its file by the path the member reads next' );
    ok( !grep( { exists $old->{$_} } qw(owner read write lock governed_by) ),
        '... carrying no rule\'s lists, owner or governing key' ) or diag explain $old;
    my $rd = as( 'author', $A, 'read', query => 'action=read&path=' . ( $old->{path} // '' ) );
    like( $rd->{content} // '', qr/an old post/, '... which reads back the file' );

    my $u = as( 'author', $A, 'list', query => 'action=list&path=/pages' );
    ok( $u->{ok}, 'a folder no rule governs is listed' ) or diag explain $u;
    is_deeply( names_of($u), [], '... and shows the member nothing' );
};

subtest 'a protected entry naming someone else is hidden' => sub {
    my $r = as( 'author', $A, 'list', query => 'action=list&path=/' );
    ok( !grep( { $_ eq 'members' } @{ names_of($r) } ), 'the folder whose read list names others is not shown' );
    my $in = as( 'author', $A, 'list', query => 'action=list&path=/members' );
    is_deeply( names_of($in), [], '... nor, listed by name, anything in it' ) or diag explain $in;
    my $dr = as( 'author', $A, 'list', query => 'action=list&path=/drafts' );
    is_deeply( names_of($dr), ['d.md'], 'a protected folder naming the author\'s group shows its file' )
        or diag explain $dr;
    my $op = $s->call( 'sysop', 'list', query => 'action=list&path=/sites/a/members' );
    is_deeply( names_of($op), ['m.md'], '(the operator sees it is there)' ) or diag explain $op;
};

subtest 'a listing never shows the reserved tree or another domain\'s root' => sub {
    # A site-wide write rule governs everything, so only the door's own reach keeps
    # the engine's tree and the other domains out of the listings.
    my $w = $s->call( 'sysop', 'acl-set', query => 'action=acl-set&path=/', body => { write => ['@sysops'] } );
    ok( $w->{ok}, 'a site-wide write rule is set' ) or diag explain $w;

    my $prim = as( 'author', undef, 'list', query => 'action=list&path=/' );
    ok( $prim->{ok}, 'the primary\'s root is listed' ) or diag explain $prim;
    ok( !grep( { $_ eq 'lazysite' } @{ names_of($prim) } ), '... without the engine\'s tree' )
        or diag explain $prim;
    ok( grep( { $_ eq 'sites' } @{ names_of($prim) } ), '... with the folder the rule now governs' );
    my $sites = as( 'author', undef, 'list', query => 'action=list&path=/sites' );
    is_deeply( names_of($sites), [], '... and in it, neither domain\'s root' ) or diag explain $sites;

    my $on_a = as( 'author', $A, 'list', query => 'action=list&path=/' );
    ok( !grep( { $_ eq 'c' } @{ names_of($on_a) } ), 'a domain nested in A\'s tree is not shown on A' )
        or diag explain $on_a;
    for my $c ( [ $A, '/c' ], [ undef, '/sites/a' ], [ $A, '/lazysite' ], [ undef, '/lazysite/auth' ] ) {
        my ( $host, $p ) = @$c;
        my $r = as( 'author', $host, 'list', query => "action=list&path=$p" );
        ok( !$r->{ok}, "listing $p on " . ( $host // 'the primary' ) . ' is refused' ) or diag explain $r;
    }
    my $sv = as( 'author', $A, 'save', query => 'action=save&path=/c/x.md', body => { content => "# x\n" } );
    ok( !$sv->{ok}, 'a save into the nested domain from A is refused' ) or diag explain $sv;
    like( $sv->{error} // '', qr/another domain's content/, '... by the door\'s own reach' );
    ok( !-e "$d/sites/a/c/x.md", '... and nothing was written' );

    my $rm = $s->call( 'sysop', 'acl-remove', query => 'action=acl-remove&path=/', body => {} );
    ok( $rm->{ok}, 'the site-wide rule is removed' ) or diag explain $rm;
};

subtest 'an account without write_content or ui is refused as SM1057 refuses it' => sub {
    for my $c ( [ save => '/post/m.md', { content => "# m\n" } ], [ read => '/post/old.md' ], [ list => '/' ] ) {
        my ( $act, $p, $body ) = @$c;
        my $r = as( 'member', $A, $act, query => "action=$act&path=$p", ( $body ? ( body => $body ) : () ) );
        ok( !$r->{ok}, "member's $act is refused" ) or diag explain $r;
        like( $r->{error} // '', qr/does not have manager access/, '... by the manager gate' );
        unlike( $r->{error} // '', qr/write_content/, '... which says nothing of a door it does not hold' );
    }
    ok( !-e "$d/sites/a/post/m.md" && !-e "$d/post/m.md", 'nothing was written' );
};

done_testing();

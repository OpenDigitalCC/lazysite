#!/usr/bin/perl
# SM1057: a signed-in account that does not hold the manager (`ui`) writes
# nothing through the manager API, on any host.
#
# Reported from sites.lazysite.io (0.15.4): on the domain
# tprf-news.sites.lazysite.io an account in no group - holding no capability -
# signed in at /login and sent `action=save` with its cookie and CSRF token. It
# got 200 for an existing post that carried an owner rule, for /search.md, and
# for a new file; `action=read` of the post was refused.
#
# What the 200s were. The manager API's cookie door asked one thing of a session:
# that it carried a user. The `ui` capability, which the /manager/ pages ask for
# (the processor's _is_manager), was never asked here, and `save` is
# deliberately not capability-gated on this channel - it self-authorises against
# the file's rule. A path no rule governs is open to every writer, so any
# signed-in member wrote any unruled path in the instance.
#
# And the paths were not the domain's. The manager's paths are docroot-relative
# whichever host carries the request, so /post/p.md on the domain's host is
# <docroot>/post/p.md - in the PRIMARY site's tree, where no rule governs it -
# and /search.md is the primary's own search page. The domain's file was never
# touched, which is why it compared equal afterwards; the read was "not found".
#
# This file builds that site - a domain with a content root, rules keyed as a
# partner sets them, a member in no group - and sends each request with the
# domain's Host and with none.
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

my $HOST = 'tprf.example.org';
my @ALL  = qw(ui manage_users manage_content manage_config);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmanager: enabled\n"
        . "alias_hosts: $HOST\nalias.$HOST.content_root: sites/tprf\n" );
my $d = $s->docroot;
make_path("$d/sites/tprf/post");
spit( "$d/index.md",             "# primary\n" );
spit( "$d/search.md",            "# primary search\n" );
spit( "$d/sites/tprf/index.md",  "# tprf\n" );
spit( "$d/sites/tprf/search.md", "# tprf search\n" );
spit( "$d/sites/tprf/post/p.md", "# a post\n" );

# The sysop secures the site (a group grants manager access); the author owns the
# post; `member` is in no group at all.
$s->add_user( 'sysop', 'pw-sysop-0123456789' );
$s->grant( 'sysop', 'sysops', [qw(ui manage_users manage_content manage_config)], \@ALL );
$s->add_user( 'author', 'pw-author-0123456789' );
$s->grant( 'author', 'authors', [qw(ui manage_content)], \@ALL );
$s->add_user( 'member', 'pw-member-0123456789' );

# The rules as the partner set them: keyed by the content root.
for my $rule (
    [ 'sites/tprf',           { write => ['@sysops'] } ],
    [ 'sites/tprf/post',      { write => [ '@authors', '@sysops' ] } ],
    [ 'sites/tprf/post/p.md', { write => [ 'author',   '@sysops' ], owner => 'author' } ],
    )
{
    my $r = $s->call( 'sysop', 'acl-set', query => "action=acl-set&path=$rule->[0]", body => $rule->[1] );
    ok( $r->{ok}, "rule set on $rule->[0]" ) or diag explain $r;
}

my %before = map { $_ => slurp("$d/$_") } qw(search.md sites/tprf/search.md sites/tprf/post/p.md);

sub as_member {
    my ( $host, $action, %o ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    delete local $ENV{HTTP_HOST} unless defined $host;
    return $s->call( 'member', $action, %o );
}

for my $host ( $HOST, undef ) {
    my $on = defined $host ? "on $host" : 'on the primary';
    for my $p ( 'post/p.md', 'search.md', 'post/zz-new.md', 'sites/tprf/post/p.md', 'sites/tprf/search.md' ) {
        my $r = as_member( $host, 'save', query => "action=save&path=/$p",
            body => { content => "# written by member\n" } );
        ok( !$r->{ok}, "member's save of /$p $on is refused" ) or diag explain $r;
        like( $r->{error} // '', qr/does not have manager access/, "... by the manager gate, not by chance ($p)" );
    }
    my $r = as_member( $host, 'read', query => 'action=read&path=/sites/tprf/post/p.md' );
    ok( !$r->{ok}, "member's read $on is refused as well" );
    like( $r->{error} // '', qr/does not have manager access/, '... by the same gate' );
    # The other writes a cookie reaches with no capability of their own: each is
    # refused at the same gate, before the per-file rule is asked.
    for my $w ( [ delete => '/search.md' ], [ mkdir => '/zz-dir' ], [ lock => '/search.md' ],
        [ move => '/search.md', '&to=/zz-moved.md' ], [ copy => '/index.md', '&to=/zz-copy.md' ] )
    {
        my ( $act, $p, $extra ) = @$w;
        my $rr = as_member( $host, $act, query => "action=$act&path=$p" . ( $extra // '' ), body => {} );
        ok( !$rr->{ok}, "member's $act of $p $on is refused" ) or diag explain $rr;
        like( $rr->{error} // '', qr/does not have manager access/, "... by the manager gate ($act)" );
    }
    my $ra = as_member( $host, 'acl-set', query => 'action=acl-set&path=/post/zz-claim.md',
        body => { write => ['member'] } );
    ok( !$ra->{ok}, "member cannot claim an unruled path with a rule $on" ) or diag explain $ra;
    like( $ra->{error} // '', qr/does not have manager access/, '... by the manager gate (acl-set)' );
}

ok( !-e "$d/post", 'nothing was written into the primary tree' );
ok( !-e "$d/$_",   "no $_ was created" ) for qw(zz-dir zz-moved.md zz-copy.md);
ok( !-e "$d/lazysite/auth/acls.json" || ( slurp("$d/lazysite/auth/acls.json") // '' ) !~ /zz-claim/,
    'no rule was claimed' );
is( slurp("$d/$_"), $before{$_}, "$_ is unchanged" ) for sort keys %before;

# The author - a manager, named in the rule - still saves the post on the
# domain's host, by its content-root path.
{
    local $ENV{HTTP_HOST} = $HOST;
    my $r = $s->call( 'author', 'save', query => 'action=save&path=/sites/tprf/post/p.md',
        body => { content => "# edited by its author\n" } );
    ok( $r->{ok}, 'the author saves the post' ) or diag explain $r;
    is( slurp("$d/sites/tprf/post/p.md"), "# edited by its author\n", '... and the bytes land in the domain' );
}

done_testing();

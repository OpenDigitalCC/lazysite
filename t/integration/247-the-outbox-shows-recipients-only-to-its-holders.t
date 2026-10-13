#!/usr/bin/perl
# SM1072 (SM1010 R3): THE NOTIFICATION OUTBOX IS SHOWN IN THE MANAGER, TO THOSE
# WHO MAY WRITE THE RULES, AND A CONFINED CALLER SEES ONLY ITS OWN DOMAINS.
#
# The outbox view shows recipients - the accounts and addresses an event
# resolves to, and the fields it carries - so it answers manage_notifications
# alone, on both doors (the control API's notify-outbox-list, MCP's
# read_notify_outbox), and a caller confined to some domains is shown only the
# events of the rules bound to them (SM1051's rule: a domain's handler is that
# domain's; an instance handler is the operator's). An event it may not see is
# not found, never forbidden, so ids cannot be probed.
#
# And the Handlers page's row: handler-list carries each notify rule's queue in
# counts (Q5, ruled: "waiting for the scheduler" when the daemon is not taking
# it), and nothing of who the events go to.
#
# Callers: op, the cookie operator; notifier, a cookie account holding only
# manage_notifications; former, one holding only manage_forms; tks, a token
# confined to mine.example.org; mcs, an MCP grant confined to the same domain.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use Lazysite::Handlers ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp manage_users manage_domains manage_content manage_forms manage_notifications);
my %CAPS = (
    op       => [qw(ui manage_users manage_domains manage_content manage_forms manage_notifications)],
    notifier => [qw(ui manage_notifications)],
    former   => [qw(ui manage_forms)],
    tks      => [qw(api manage_notifications)],
    mcs      => [qw(mcp manage_notifications)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\nsite_url: https://news.example\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/forms" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->add_user( 'alice', 'pw-alice-0123456789' );
$s->users( 'set', 'alice', 'email', 'alice@example.net' );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query )
        if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks, g-mcs' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0] $set->[1]{host}" ) or diag( $r->{error} // '' );
}

sub rule {
    my ( $id, %o ) = @_;
    return { id => $id, type => 'notify', name => "Rule $id", recipients => '[{"accounts":["alice"]}]',
        unsubscribe_path => '/account', %o };
}
for my $r ( rule('r-inst'), rule( 'r-mine', domain => 'mine.example.org' ), rule( 'r-other', domain => 'other.example.org' ) ) {
    my $a = api( 'op', 'handler-save', $r );
    ok( $a->{ok}, "set up: the operator saves $r->{id}" ) or diag( $a->{error} // '' );
}

# One event for each rule, queued as a form delivery queues it.
$Lazysite::Handlers::DOCROOT = $d;
my %ev;
for my $id (qw(r-inst r-mine r-other)) {
    my $r = Lazysite::Handlers::deliver( $id, { post => "p-$id", comment => "about $id" }, origin => 'form',
        source => 'form:comment', actor => 'op' );
    ok( $r->{queued}, "an event is queued for $id" ) or diag explain $r;
    $ev{$id} = $r->{queued};
}
sub rules_of { return join ',', sort map { $_->{rule} } @{ $_[0]{entries} || [] } }

subtest 'a holder of manage_notifications sees the outbox, recipients and all' => sub {
    my $l = api( 'notifier', 'notify-outbox-list' );
    ok( $l->{ok}, 'it lists' ) or diag explain $l;
    is( rules_of($l), 'r-inst,r-mine,r-other', 'every rule\'s event, unconfined' );
    my $one = api( 'notifier', 'notify-outbox-list', undef, "action=notify-outbox-list&id=$ev{'r-mine'}" );
    ok( $one->{ok}, 'one event by id' ) or diag explain $one;
    is_deeply( [ map { $_->{who} } @{ $one->{recipients}{list} || [] } ], ['account alice'], 'with who it goes to' );
    is( $one->{entry}{fields}{comment}, 'about r-mine', 'and what it carries' );
};

subtest 'it is manage_notifications\' alone' => sub {
    my $r = api( 'former', 'notify-outbox-list' );
    ok( !$r->{ok}, 'a holder of manage_forms only is refused' );
    is( $s->last_status, 403, 'as forbidden' );
    unlike( encode_json($r), qr/alice|about r-/, 'and is shown nothing of it' );
    ok( !api( 'alice', 'notify-outbox-list' )->{ok}, 'a member is refused' );
};

subtest 'a confined token sees its own domain\'s rules only' => sub {
    my $l = api( 'tks', 'notify-outbox-list' );
    ok( $l->{ok}, 'it lists' ) or diag explain $l;
    is( rules_of($l), 'r-mine', 'only the rule bound to its domain - not the instance\'s, not another domain\'s' );
    for my $id (qw(r-other r-inst)) {
        my $one = api( 'tks', 'notify-outbox-list', undef, "action=notify-outbox-list&id=$ev{$id}" );
        is( $one->{kind}, 'not-found', "${id}'s event by id: not found, so ids cannot be probed" );
        unlike( encode_json($one), qr/alice/, '...and nothing of its recipients' );
    }
};

subtest 'the MCP twin applies the same rule' => sub {
    my $l = mcp( 'mcs', 'read_notify_outbox', {} );
    ok( $l->{ok}, 'it lists' ) or diag explain $l;
    is( rules_of($l), 'r-mine', 'only its own domain\'s rule' );
    my $one = mcp( 'mcs', 'read_notify_outbox', { id => $ev{'r-other'} } );
    is( $one->{kind}, 'not-found', 'another domain\'s event is not found' );
};

subtest 'the Handlers row carries the queue in counts, and no recipients' => sub {
    my $l = api( 'notifier', 'handler-list' );
    ok( $l->{ok}, 'handler-list' ) or diag explain $l;
    my ($h) = grep { $_->{id} eq 'r-mine' } @{ $l->{handlers} || [] };
    is( $h->{outbox}{queued}, 1, 'one queued' );
    ok( !$h->{outbox}{waiting}, 'a fresh event is not waiting' );
    unlike( encode_json( $h->{outbox} ), qr/alice/, 'counts only' );
};

done_testing;

#!/usr/bin/perl
# SM1107 (0.15.6 test plan, U8): AN OPERATOR RETRIES AN OUTBOX ENTRY NOW, ON
# BOTH DOORS, UNDER THE SAME GATE AS THE OUTBOX LIST.
#
# "No way to retry an outbox entry now. After a transport fix, entries sit in
# backoff for minutes." notify-outbox-retry (control API) and retry_notify_outbox
# (MCP) make a rule's waiting entries, or one event, due at once. They answer
# manage_notifications alone, a confined caller reaches only its own domains'
# rules (another's event is not found), and the action is audited as any
# mutator is. The sending itself is the job's (Lazysite::Outbox, t/unit/notify/08).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
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
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
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
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ],
        stdin => ( $json // '' ) )->{out};
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
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
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

# Put every event into backoff, as a failed transport leaves them.
my $outbox = "$d/lazysite/notify/outbox";
sub backoff {
    opendir my $dh, $outbox or die "$outbox: $!";
    for my $f ( grep { /\.json\z/ } readdir $dh ) {
        open my $in, '<:raw', "$outbox/$f" or die;
        my $e = decode_json( do { local $/; <$in> } );
        close $in;
        @$e{qw(attempts next_at last_error)} = ( 1, time + 3600, 'connection refused' );
        open my $out, '>:raw', "$outbox/$f" or die;
        print {$out} encode_json($e);
        close $out;
    }
    return;
}
sub due_now {
    my %due;
    opendir my $dh, $outbox or die;
    for my $f ( grep { /\.json\z/ } readdir $dh ) {
        open my $in, '<:raw', "$outbox/$f" or die;
        my $e = decode_json( do { local $/; <$in> } );
        close $in;
        $due{ $e->{rule} } = $e->{next_at} <= time ? 1 : 0;
    }
    return \%due;
}
sub audit_rows { open my $in, '<', "$d/lazysite/logs/audit.log" or return (); return grep { /notify-outbox-retry/ } <$in> }
backoff();
is_deeply( due_now(), { 'r-inst' => 0, 'r-mine' => 0, 'r-other' => 0 }, 'set up: every event waits in backoff' );

subtest 'a holder retries one event by id' => sub {
    my $r = api( 'notifier', 'notify-outbox-retry', { id => $ev{'r-mine'} } );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    is( $r->{retried}, 1, 'one made due' );
    is_deeply( due_now(), { 'r-inst' => 0, 'r-mine' => 1, 'r-other' => 0 }, 'only that event is due now' );
    my @a = audit_rows();
    is( scalar @a, 1, 'and it is audited' );
    like( $a[0], qr/notifier/, '...naming who did it' );
    # SM1123: the row names what was retried, not '/', and what came of it.
    like( $a[0], qr/\| notify-outbox-retry \| \Q$ev{'r-mine'}\E \|/, '...the target is the entry id' );
    like( $a[0], qr/\| retried=1 sent=0 already_due=0\b/, '...and the detail has the counts' );
};

sub audit_of { my ($act) = @_; open my $in, '<', "$d/lazysite/logs/audit.log" or return (); return grep { /\| \Q$act\E \|/ } <$in> }

subtest 'it is manage_notifications\' alone' => sub {
    my $r = api( 'former', 'notify-outbox-retry', { rule => 'r-inst' } );
    ok( !$r->{ok}, 'a holder of manage_forms only is refused' );
    is( $s->last_status, 403, 'as forbidden' );
    ok( !api( 'alice', 'notify-outbox-retry', { rule => 'r-inst' } )->{ok}, 'a member is refused' );
    is( due_now()->{'r-inst'}, 0, 'and nothing was made due' );
    my $e = api( 'notifier', 'notify-outbox-retry', {} );
    ok( !$e->{ok}, 'with neither a rule nor an id there is nothing to retry' );
    is( $e->{kind}, 'invalid', 'said as invalid' );
};

subtest 'a confined token reaches its own domain\'s rules only' => sub {
    my $r = api( 'tks', 'notify-outbox-retry', { id => $ev{'r-other'} } );
    is( $r->{kind}, 'not-found', 'another domain\'s event is not found' );
    $r = api( 'tks', 'notify-outbox-retry', { rule => 'r-inst' } );
    is( $r->{retried}, 0, 'the instance rule retries nothing' );
    is_deeply( due_now(), { 'r-inst' => 0, 'r-mine' => 1, 'r-other' => 0 }, 'neither became due' );
    backoff();
    $r = api( 'tks', 'notify-outbox-retry', { rule => 'r-mine' } );
    is( $r->{retried}, 1, 'its own rule retries' );
    is_deeply( due_now(), { 'r-inst' => 0, 'r-mine' => 1, 'r-other' => 0 }, 'only its own became due' );
    my ($row) = reverse audit_of('notify-outbox-retry');
    like( $row, qr/\| tks \| notify-outbox-retry \| notify:r-mine \|/, 'SM1123: a retry by rule is audited against notify:<rule>' );
    like( $row, qr/\| retried=1 sent=0 already_due=0\b/, '...with the counts' );
};

subtest 'the MCP twin applies the same rule' => sub {
    backoff();
    my $r = mcp( 'mcs', 'retry_notify_outbox', { id => $ev{'r-other'} } );
    is( $r->{kind}, 'not-found', 'another domain\'s event is not found' );
    $r = mcp( 'mcs', 'retry_notify_outbox', { rule => 'r-mine' } );
    ok( $r->{ok}, 'its own rule' ) or diag explain $r;
    is( $r->{retried}, 1, 'made due' );
    is_deeply( due_now(), { 'r-inst' => 0, 'r-mine' => 1, 'r-other' => 0 }, 'only its own became due' );
    my ($row) = reverse audit_of('retry_notify_outbox');
    like( $row, qr/\| mcs \| retry_notify_outbox \| notify:r-mine \|/, 'SM1123: the twin audits against notify:<rule> too' );
    like( $row, qr/\| mcp \| retried=1 sent=0 already_due=0\b/, '...with the counts' );
};

done_testing;

#!/usr/bin/perl
# SM579 phase 1: a connector is a reusable, credentialed destination; WHO may
# cause a call is decided by the connector's declared modes and callers; HOW
# OFTEN by its rate cap; the answer lands in a table row; every call is one
# audit line and one record line, never the payload.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use JSON::PP;

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'HTTP::Daemon/LWP/DBI/SQLite/YAML::PP not available';
}
use Lazysite::Manager::Connectors;

my $d = site_tempdir();
make_path( "$d/lazysite/db/tables", "$d/lazysite/auth" );
$Lazysite::Manager::Connectors::DOCROOT = $d;

# --- a remote that answers, records what it was sent, and can be told to hang
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
my $base = $srv->url;    # http://127.0.0.1:PORT/
my @seen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    # one process per connection, so a request told to hang does not hold up
    # the ones that follow it
    while ( my $conn = $srv->accept ) {
        my $kid = fork;
        next if $kid;
        while ( my $req = $conn->get_request ) {
            my $path = $req->uri->path;
            if ( $path eq '/hang' ) { sleep 5; $conn->send_error(504); next }
            if ( $path eq '/fail' ) { $conn->send_error( 422, 'nope' ); next }
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content( encode_json( { got => ( $req->content ? decode_json( $req->content ) : {} ), auth => ( $req->header('Authorization') // '' ), path => $path } ) );
            $conn->send_response($res);
        }
        $conn->close;
        exit 0;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

sub save_ok {
    my ( $id, %over ) = @_;
    my $r = Lazysite::Manager::Connectors::action_connector_save( $id,
        { name => "c $id", url => "${base}echo", modes => { authenticated => 1 }, callers => ['senders'], rate_per_hour => 3, timeout => 2, %over } );
    ok( $r->{ok}, "connector '$id' saved" ) or diag $r->{error};
    return $r;
}

subtest 'a connector is bounded at save time' => sub {
    my $bad = Lazysite::Manager::Connectors::action_connector_save( 'x', { url => 'ftp://nope' } );
    ok( !$bad->{ok}, 'a non-https url is refused' );
    like( $bad->{error}, qr/https/, 'and the refusal says what is accepted' );
    $bad = Lazysite::Manager::Connectors::action_connector_save( 'Bad Id', { url => 'https://a.example/x' } );
    ok( !$bad->{ok}, 'an id with a space is refused' );
    my $r = save_ok('echo');
    is( $r->{connector}{modes}{public},        0, 'public is OFF unless said' );
    is( $r->{connector}{modes}{authenticated}, 1, 'authenticated is on by default' );
    my $list = Lazysite::Manager::Connectors::action_connector_list();
    is( scalar @{ $list->{connectors} }, 1, 'listed' );
    is( $list->{connectors}[0]{has_secret}, 0, 'no secret yet, and the listing says so without carrying one' );
    ok( !exists $list->{connectors}[0]{secret}, 'the listing never carries a secret' );
};

subtest 'the secret is held apart, 0600, and travels in the named header' => sub {
    my $r = Lazysite::Manager::Connectors::action_connector_secret_set( 'echo', 'tok-123' );
    ok( $r->{ok}, 'secret set' ) or diag $r->{error};
    my $mode = ( stat "$d/lazysite/connectors/secrets.json" )[2] & 0777;
    is( $mode, 0600, 'secrets.json is 0600' );
    my $conf = do { local ( @ARGV, $/ ) = "$d/lazysite/connectors/connectors.json"; <> };
    unlike( $conf, qr/tok-123/, 'and the connector file never holds it' );
    my $c = Lazysite::Manager::Connectors::call( 'echo', { q => 'hello' }, mode => 'authenticated', caps => { manage_connectors => 1 }, actor => 'ops', trigger => 'test' );
    ok( $c->{ok}, 'an authenticated call by a manage_connectors holder answers' ) or diag $c->{error};
    is( $c->{state}, 'answered', 'state answered' );
    is( $c->{answer}{auth}, 'Bearer tok-123', 'the secret went in the Authorization header with its prefix' );
    is( $c->{answer}{got}{q}, 'hello', 'the payload reached the remote as JSON' );
};

subtest 'WHO may call: modes and callers decide, before anything is sent' => sub {
    my $r = Lazysite::Manager::Connectors::call( 'echo', { q => 1 }, mode => 'public', actor => '' );
    ok( !$r->{ok}, 'a public trigger is refused' );
    like( $r->{error}, qr/public is opt-in/, 'and the refusal says public is opt-in' );
    is( $r->{state}, 'refused', 'state refused' );
    $r = Lazysite::Manager::Connectors::call( 'echo', { q => 1 }, mode => 'authenticated', caps => {}, groups => ['editors'], actor => 'ed' );
    ok( !$r->{ok}, 'an authenticated caller outside the callers groups is refused' );
    like( $r->{error}, qr/senders/, 'naming the groups that may' );
    $r = Lazysite::Manager::Connectors::call( 'echo', { q => 1 }, mode => 'authenticated', caps => {}, groups => ['senders'], actor => 'sam' );
    ok( $r->{ok}, 'a caller in a named group may' ) or diag $r->{error};
    $r = Lazysite::Manager::Connectors::call( 'echo', { q => 1 }, mode => 'scheduled' );
    ok( !$r->{ok}, 'scheduled is refused when not declared' );
    $r = Lazysite::Manager::Connectors::call( 'echo', { f => [1] }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    ok( !$r->{ok} && $r->{error} =~ /never a file/, 'a structured or file value is refused: text fields only' );
};

subtest 'HOW OFTEN: the rate cap counts the record, in every mode' => sub {
  # 3/hour: two calls happened above (one answered by ops, one by sam); a third is the cap
    my $r = Lazysite::Manager::Connectors::call( 'echo', { q => 3 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    ok( $r->{ok}, 'third call within the cap' ) or diag $r->{error};
    $r = Lazysite::Manager::Connectors::call( 'echo', { q => 4 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    ok( !$r->{ok}, 'the fourth is refused' );
    like( $r->{error}, qr/rate cap reached: 3/, 'naming the cap' );
    my $calls = Lazysite::Manager::Connectors::action_connector_calls( connector => 'echo' );
    # SM771: every refusal is a row - the four above (public, caller, scheduled,
    # payload) and this cap - so a connector's own log shows who tried it
    is( $calls->{counts}{refused}, 5, 'every refusal is on the record, not only the cap' );
    is( $calls->{counts}{answered}, 3, 'beside the three that answered' );
    ok( ( grep { ( $_->{why} // '' ) =~ /none of the groups/ && $_->{actor} eq 'ed' } @{ $calls->{calls} } ),
        'the account outside the callers is there by name, with the reason' );
    is( $calls->{counts}{answered} + 0, 3, 'and the refusals did not consume the cap (three answered under a cap of three)' );
    my $rec = do { local ( @ARGV, $/ ) = "$d/lazysite/connectors/calls.jsonl"; <> };
    unlike( $rec, qr/hello/, 'the record never carries the payload' );
};

subtest 'a remote that fails or never answers is said so, not "waiting"' => sub {
    save_ok( 'flaky', url => "${base}fail", rate_per_hour => 0 );
    my $r = Lazysite::Manager::Connectors::call( 'flaky', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    is( $r->{state}, 'failed', 'a 4xx/5xx is failed' );
    is( $r->{http},  422,      'with the status' );
    save_ok( 'slow', url => "${base}hang", rate_per_hour => 0, timeout => 1 );
    $r = Lazysite::Manager::Connectors::call( 'slow', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    is( $r->{state}, 'unanswered', 'a timeout is unanswered' ) or diag explain $r;
    # SM771: the answer that never came is the library's sentence, not its stack
    like( $r->{answer}, qr/timeout|timed out/i, 'the answer says the transport reason' );
    unlike( $r->{answer}, qr{ at \S+ line \d+}, 'and carries no library path or line' );
    unlike( $r->{answer}, qr{/usr/|/perl},      'nor a host path' );
    my $calls = Lazysite::Manager::Connectors::action_connector_calls( state => 'unanswered' );
    is( scalar @{ $calls->{calls} }, 1, 'and connector-calls lists it by state' );
};

subtest 'the answer lands in the table the connector names' => sub {
    open my $f, '>', "$d/lazysite/db/tables/answers.yaml" or die $!;
    print {$f} "key: id\nauto_key: true\nfields:\n  connector: { type: text }\n  call_id: { type: text }\n  mode: { type: text }\n  actor: { type: text }\n  at: { type: integer }\n  state: { type: text }\n  http: { type: integer }\n  answer: { type: text }\n";
    close $f;
    require Lazysite::Data::Tables;
    my $a = Lazysite::Data::Tables::apply_schema( $d, 'answers' );
    ok( $a->{ok}, 'answers table applied' ) or diag explain $a;
    save_ok( 'kept', answer_table => 'answers', rate_per_hour => 0 );
    my $r = Lazysite::Manager::Connectors::call( 'kept', { q => 'row' }, mode => 'authenticated', caps => { manage_connectors => 1 }, actor => 'ops' );
    ok( $r->{ok},       'answered' ) or diag $r->{error};
    ok( $r->{kept}{ok}, 'and kept' ) or diag explain $r->{kept};
    my $rows = Lazysite::Data::Tables::read_rows( $d, 'answers', as => 'operator' );
    is( scalar @{ $rows->{rows} }, 1, 'one row' );
    like( $rows->{rows}[0]{answer}, qr/"q":"row"/, 'holding the answer as JSON text' );
    is( $rows->{rows}[0]{actor}, 'ops', 'and who caused it' );

    save_ok( 'lost', answer_table => 'no_such_table', rate_per_hour => 0 );
    $r = Lazysite::Manager::Connectors::call( 'lost', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    ok( $r->{ok},        'the call itself answered' );
    ok( !$r->{kept}{ok}, 'but a missing table is reported on the call, not skipped' );
    like( $r->{kept}{error}, qr/no_such_table/, 'by name' );
};

subtest 'the sweep expires old records and counts the unanswered' => sub {
    open my $f, '>>', "$d/lazysite/connectors/calls.jsonl" or die $!;
    print {$f} encode_json( { call_id => 'old', connector => 'echo', at => time - 40 * 86400, state => 'answered' } ), "\n";
    close $f;
    my $s = Lazysite::Manager::Connectors::sweep($d);
    ok( $s->{ok}, 'swept' );
    is( $s->{expired},    1, 'one old record expired' );
    is( $s->{unanswered}, 1, 'one unanswered counted' );
};

# SM768: a store that exists and cannot be opened is not an empty store. On
# edge, with lazysite/connectors/ unwritable after a failed install, the
# listing said has_secret: 0 for a secret that was there the whole time. Each
# action must say "cannot tell" - and none may write, or call, past it.
subtest 'an unopenable secret store is reported, never rendered as absence' => sub {
    plan skip_all => 'root opens everything' if $> == 0;
    my $sf = "$d/lazysite/connectors/secrets.json";
    ok( -f $sf, 'the secret store exists' );
    chmod 0000, $sf;
    my $list = Lazysite::Manager::Connectors::action_connector_list();
    ok( $list->{ok}, 'the listing still answers (the connector store itself is readable)' );
    is( $list->{secrets_readable}, 0, 'and says the secret store could not be read' );
    my ($echo) = grep { $_->{id} eq 'echo' } @{ $list->{connectors} };
    ok( exists $echo->{has_secret} && !defined $echo->{has_secret}, 'has_secret is null - not 0 - for a secret that is still there' );
    like( $list->{warning}, qr/secret store \(connectors\/secrets\.json\) exists but cannot be opened by this process \(unix user \S+\)/, 'the warning names the file and the unix user' );
    unlike( $list->{warning}, qr{\Q$d\E}, 'and never the host path' );

    my $set = Lazysite::Manager::Connectors::action_connector_secret_set( 'echo', 'tok-999' );
    ok( !$set->{ok}, 'a secret is not written over a store that could not be read' );
    like( $set->{error}, qr/nothing was written/, 'and says so' );
    my $del = Lazysite::Manager::Connectors::action_connector_delete('echo');
    ok( !$del->{ok}, 'nor is a connector deleted while its secret is out of reach' );

 # 'lost' has no rate cap, so the only thing standing between it and the wire is the store
    my $r = Lazysite::Manager::Connectors::call( 'lost', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    is( $r->{state}, 'refused', 'a call is refused rather than sent without its credential' );
    like( $r->{error}, qr/without its credential/, 'and the refusal says why' );
    my $calls = Lazysite::Manager::Connectors::action_connector_calls( connector => 'lost', state => 'refused' );
    ok( ( grep { ( $_->{why} // '' ) eq 'secret store unreadable' } @{ $calls->{calls} } ), 'the refusal is in the call record' );

    chmod 0600, $sf;
    $list = Lazysite::Manager::Connectors::action_connector_list();
    ($echo) = grep { $_->{id} eq 'echo' } @{ $list->{connectors} };
    is( $echo->{has_secret},       1, 'the secret was there all along' );
    is( $list->{secrets_readable}, 1, 'and the store reads again' );

    # the call record: a cap that cannot be checked refuses
    my $cf = "$d/lazysite/connectors/calls.jsonl";
    chmod 0000, $cf;
    $r = Lazysite::Manager::Connectors::call( 'echo', { q => 1 }, mode => 'authenticated', caps => { manage_connectors => 1 } );
    is( $r->{state}, 'refused', 'a rate-capped connector whose call record cannot be read refuses' );
    like( $r->{error}, qr/rate cap cannot be checked/, 'and says the cap, not the count, is the reason' );
    ok( !Lazysite::Manager::Connectors::action_connector_calls()->{ok}, 'the record listing reports the fault' );
    chmod 0660, $cf;
};

subtest 'delete takes the secret with it' => sub {
    my $r = Lazysite::Manager::Connectors::action_connector_delete('echo');
    ok( $r->{ok}, 'deleted' );
    my $sec = do { local ( @ARGV, $/ ) = "$d/lazysite/connectors/secrets.json"; <> };
    unlike( $sec, qr/tok-123/, 'the secret went with it' );
};

done_testing;

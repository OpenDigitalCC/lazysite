#!/usr/bin/perl
# SM842: ONE WAY TO DELIVER.
#
# A handler is a named function a form or the schedule calls. This file proves
# the contract Lazysite::Handlers holds on every surface's behalf:
#
#   * ONE PARSER. The three that read handlers.conf disagreed about an absent
#     `enabled` - the MCP listing said off, delivery said on - so an agent was
#     told a handler was off while it took every submission.
#   * THE DESTINATION DECIDES who may configure a handler: a table handler
#     needs manage_data, a connector handler manage_connectors, email and file
#     manage_forms; changing a handler's type needs both; binding a form to one
#     that exists needs manage_forms alone.
#   * A FORM NAMES HANDLERS AND NOTHING ELSE. No inline target, no handler
#     nobody created, no connector that would refuse every submission.
#   * THE SCHEDULE calls any handler, under the same authority.
#   * THE CONVERSION brings an old site to this shape once, says what it did,
#     and changes nothing the second time.
#   * A STORE THAT CANNOT BE READ is never overwritten: SM785's shape, where a
#     save over an unreadable file replaced every record with one.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Handlers            ();
use Lazysite::Manager::Connectors ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub fresh_site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/connectors",
        "$d/lazysite/db/tables" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    $Lazysite::Handlers::DOCROOT            = $d;
    $Lazysite::Manager::Connectors::DOCROOT = $d;
    return $d;
}

my %FORMS = ( caps => { manage_forms      => 1 } );
my %DATA  = ( caps => { manage_data       => 1 } );
my %CONN  = ( caps => { manage_connectors => 1 } );
my %ALL   = ( unconstrained => 1 );

subtest 'one parser, and absent `enabled` means on everywhere' => sub {
    my $d = fresh_site();
    spit( "$d/lazysite/forms/handlers.conf",
        "# a comment\nhandlers:\n  - id: store\n    type: file\n    name: Store\n"
            . "    path: lazysite/forms/submissions\n"
            . "\t- id: tabbed\n\t  type: smtp\n\t  enabled: false\n"
            . "  - id: empty-value\n    type: file\n    path:\n" );
    my $all = Lazysite::Handlers::read_handlers();
    is_deeply( [ map { $_->{id} } @$all ], [qw(store tabbed empty-value)],
        'every record, whatever the indentation' );
    ok( !exists $all->[2]{path}, 'an empty value is an absent key' );
    my $list = Lazysite::Handlers::action_handler_list();
    my %en   = map { $_->{id} => ( $_->{enabled} ? 1 : 0 ) } @{ $list->{handlers} };
    is( $en{store},  1, 'an absent enabled lists as ON - the old MCP listing said off' );
    is( $en{tabbed}, 0, 'an explicit false lists as off' );
    ok( Lazysite::Handlers::enabled( $all->[0] ), 'and delivery reads it the same way' );
    ok( ref $list->{types} eq 'ARRAY' && @{ $list->{types} } == 4,
        'the listing carries the four types and their fields' );
};

subtest 'the destination decides who may configure a handler' => sub {
    my $d = fresh_site();
    spit( "$d/lazysite/db/tables/leads.yaml", "fields:\n  name:\n    type: text\n  email:\n    type: text\n" );
    Lazysite::Manager::Connectors::action_connector_save( 'crm',
        { url => 'https://crm.example/in', modes => { public => 1, scheduled => 1 } } );

    my %table = ( id => 'leads', type => 'table', name => 'Leads', table => 'leads',
        fields => 'name=name,email=email' );
    my $r = Lazysite::Handlers::action_handler_save( {%table}, %FORMS );
    ok( !$r->{ok}, 'manage_forms cannot create a table handler' );
    like( $r->{error}, qr/needs the 'manage_data' permission - the destination decides/,
        'and is told which capability the destination needs' );
    ok( Lazysite::Handlers::action_handler_save( {%table}, %DATA )->{ok}, 'manage_data can' );

    my %conn = ( id => 'to-crm', type => 'connector', name => 'CRM', connector => 'crm' );
    ok( !Lazysite::Handlers::action_handler_save( {%conn}, %DATA )->{ok},
        'manage_data cannot create a connector handler' );
    ok( Lazysite::Handlers::action_handler_save( {%conn}, %CONN )->{ok}, 'manage_connectors can' );

    my %file = ( id => 'store', type => 'file', name => 'Store' );
    ok( !Lazysite::Handlers::action_handler_save( {%file}, %CONN )->{ok},
        'manage_connectors cannot create a file handler' );
    ok( Lazysite::Handlers::action_handler_save( {%file}, %FORMS )->{ok}, 'manage_forms can' );

    $r = Lazysite::Handlers::action_handler_save(
        { %table, id => 'store' }, caps => { manage_data => 1 } );
    ok( !$r->{ok}, 'turning a file handler into a table handler needs BOTH destinations' );
    like( $r->{error}, qr/existing file handler 'store'.*manage_forms/, 'naming the one missing' );
    ok( Lazysite::Handlers::action_handler_save( { %table, id => 'store' },
            caps => { manage_data => 1, manage_forms => 1 } )->{ok}, 'with both it goes through' );

    ok( !Lazysite::Handlers::action_handler_delete( 'leads', %FORMS )->{ok},
        'deleting a table handler needs manage_data too' );
    ok( Lazysite::Handlers::action_handler_delete( 'leads', %DATA )->{ok}, 'and with it, goes' );
};

subtest 'a handler is exactly its type\'s fields, checked against the live site' => sub {
    my $d = fresh_site();
    spit( "$d/lazysite/db/tables/leads.yaml", "fields:\n  name:\n    type: text\n" );
    my $save = sub { Lazysite::Handlers::action_handler_save( $_[0], %ALL ) };

    my $r = $save->( { id => 'x', type => 'file', name => 'X', url => 'https://nope' } );
    like( $r->{error}, qr/a file handler does not take: url/, 'a key the type does not declare is refused by name' );
    is( $r->{field}, 'url', 'and the refusal names the field' );

    for my $old (qw(webhook api)) {
        $r = $save->( { id => 'x', type => $old, name => 'X', url => 'https://a.example' } );
        like( $r->{error}, qr/there is no '$old' handler any more: outbound HTTP goes through a connector/,
            "a '$old' handler is refused, pointing at connectors" );
    }
    like( $save->( { id => 'x', type => 'db', name => 'X' } )->{error},
        qr/use type 'table' with keep_copy: false/, 'a db handler is refused, pointing at table' );
    like( $save->( { id => 'x', name => 'X' } )->{error}, qr/type is required/, 'a missing type is named as missing' );
    like( $save->( { type => 'file', name => 'X' } )->{error}, qr/id is required/, 'and a missing id' );
    like( $save->( { id => 'x', type => 'smtp', name => 'X', to => 'a@b.c' } )->{error},
        qr/from is required for a smtp handler/, 'a required field without a default is refused' );
    like( $save->( { id => 'x', type => 'smtp', name => 'X', from => 'nobody', to => 'a@b.c' } )->{error},
        qr/from must be an email address/, 'an address that is not one' );
    for my $bad ( '../etc', '/var/tmp', 'lazysite/auth' ) {
        ok( !$save->( { id => 'x', type => 'file', name => 'X', path => $bad } )->{ok},
            "a store at '$bad' is refused" );
    }
    ok( $save->( { id => 'x', type => 'file', name => 'X', path => 'lazysite/forms/leads' } )->{ok},
        'a store under lazysite/forms is allowed' );
    like( $save->( { id => 't', type => 'table', name => 'T', table => 'nosuch', fields => 'a=name' } )->{error},
        qr/no table 'nosuch' is declared - the declared tables are: leads/,
        'a table that is not declared is refused at save, naming the ones that are' );
    like( $save->( { id => 't', type => 'table', name => 'T', table => 'leads', fields => 'a=colour' } )->{error},
        qr/'leads' has no column colour/, 'and a mapping to a column that does not exist' );
    like( $save->( { id => 't', type => 'table', name => 'T', table => 'leads', fields => 'nonsense' } )->{error},
        qr/is not field=column/, 'a mapping that is not one' );
    like( $save->( { id => 'c', type => 'connector', name => 'C', connector => 'ghost' } )->{error},
        qr/no connector 'ghost'/, 'a connector that does not exist' );
    my $h = $save->( { id => 't', type => 'table', name => 'T', table => 'leads', fields => 'n=name' } )->{handler};
    is( $h->{keep_copy}, 'true', 'keep_copy takes its default' );
};

subtest 'a function in use is not deleted' => sub {
    my $d = fresh_site();
    Lazysite::Handlers::action_handler_save( { id => 'store', type => 'file', name => 'S' }, %ALL );
    ok( Lazysite::Handlers::action_form_targets_save( 'contact', ['store'] )->{ok}, 'bound to a form' );
    ok( Lazysite::Handlers::action_schedule_save(
            { id => 'nightly', handler => 'store', every => 3600 }, %ALL )->{ok}, 'and scheduled' );
    my $r = Lazysite::Handlers::action_handler_delete( 'store', %ALL );
    ok( !$r->{ok}, 'deleting it is refused' );
    like( $r->{error}, qr/in use - forms: contact; schedule entries: nightly/, 'naming every user' );
    is_deeply( $r->{used_by}, { forms => ['contact'], schedule => ['nightly'] }, 'and listing them' );
};

subtest 'a form names handlers, and nothing else' => sub {
    my $d = fresh_site();
    Lazysite::Handlers::action_handler_save( { id => 'store', type => 'file', name => 'S' }, %ALL );
    spit( "$d/lazysite/forms/contact.conf",
        "rate_limit: 20\nupload_max_kb: 100\ntargets:\n  - handler: old\nquarantine: off\n" );
    ok( Lazysite::Handlers::action_form_targets_save( 'contact', [ { handler => 'store' } ] )->{ok},
        'bound, in the shape the manager sends' );
    my $conf = slurp("$d/lazysite/forms/contact.conf");
    like( $conf, qr/\Atargets:\n  - handler: store\n/, 'the targets are the handler ids' );
    unlike( $conf, qr/handler: old/, 'replacing the old list' );
    like( $conf, qr/^rate_limit: 20$/m, 'the form\'s other settings survive - bind_form used to drop them' );
    like( $conf, qr/^upload_max_kb: 100$/m, 'every one of them' );
    like( $conf, qr/^quarantine: off$/m,    'wherever they were in the file' );

    my $r = Lazysite::Handlers::action_form_targets_save( 'contact', [ { type => 'webhook', url => 'https://x' } ] );
    like( $r->{error}, qr/inline targets were removed in 0.13.13/, 'an inline target is refused' );
    $r = Lazysite::Handlers::action_form_targets_save( 'contact', ['ghost'] );
    like( $r->{error}, qr/no handler 'ghost' - the configured handlers are: store/, 'a handler nobody made' );
    for my $reserved (qw(handlers smtp schedule)) {
        ok( !Lazysite::Handlers::action_form_targets_save( $reserved, ['store'] )->{ok},
            "'$reserved' is not a form name" );
    }

    Lazysite::Manager::Connectors::action_connector_save( 'private', { url => 'https://p.example/x' } );
    Lazysite::Handlers::action_handler_save(
        { id => 'to-private', type => 'connector', name => 'P', connector => 'private' }, %ALL );
    $r = Lazysite::Handlers::action_form_targets_save( 'contact', ['to-private'] );
    like( $r->{error}, qr/does not permit public invocation, so it would refuse every submission/,
        'a connector that refuses public invocation is refused at the binding, not at every submission' );

    is_deeply( Lazysite::Handlers::form_conf_problems("targets:\n  - handler: store\n"), [],
        'a good config has no problems' );
    my $p = Lazysite::Handlers::form_conf_problems("targets:\n  - type: file\n    path: x\n  - handler: nope\n");
    is( scalar @$p, 2, 'an inline target and an unknown handler are both problems' );
};

subtest 'the schedule calls handlers, under the same authority' => sub {
    my $d = fresh_site();
    spit( "$d/lazysite/db/tables/leads.yaml", "fields:\n  name:\n    type: text\n" );
    Lazysite::Handlers::action_handler_save(
        { id => 'rows', type => 'table', name => 'R', table => 'leads', fields => 'name=name' }, %ALL );
    my %e = ( id => 'tick', handler => 'rows', every => 600, payload => { name => 'timer' } );
    like( Lazysite::Handlers::action_schedule_save( { %e, every => 60 }, %ALL )->{error},
        qr/at least 300/, 'the floor is the scheduler\'s own tick, and named' );
    like( Lazysite::Handlers::action_schedule_save( { %e, payload => { deep => { a => 1 } } }, %ALL )->{error},
        qr/fixed values only/, 'a payload is flat' );
    like( Lazysite::Handlers::action_schedule_save( {%e}, %FORMS )->{error},
        qr/manage_data/, 'scheduling a table handler needs manage_data' );
    ok( Lazysite::Handlers::action_schedule_save( {%e}, %DATA )->{ok}, 'and with it, stands' );
    my $l = Lazysite::Handlers::action_schedule_list();
    is( $l->{schedule}[0]{payload}{name}, 'timer', 'the payload round-trips' );
    is( $l->{schedule}[0]{cap}, 'manage_data', 'and the listing says which capability runs it' );
    like( slurp("$d/lazysite/forms/schedule.conf"), qr/payload: \{"name":"timer"\}/,
        'as one line of JSON in a file a person can read' );

    Lazysite::Manager::Connectors::action_connector_save( 'pub', { url => 'https://p.example/x', modes => { public => 1 } } );
    Lazysite::Handlers::action_handler_save( { id => 'to-pub', type => 'connector', name => 'P', connector => 'pub' }, %ALL );
    like( Lazysite::Handlers::action_schedule_save( { id => 'p', handler => 'to-pub', every => 900 }, %ALL )->{error},
        qr/does not permit scheduled invocation/, 'a connector the timer would be refused by is refused here' );

    my $due = Lazysite::Handlers::due_entries( Lazysite::Handlers::read_schedule(), {}, time );
    is( scalar @$due, 1, 'an entry that never ran is due' );
    $due = Lazysite::Handlers::due_entries( Lazysite::Handlers::read_schedule(), { tick => { last_run => time - 10 } }, time );
    is( scalar @$due, 0, 'one that just ran is not' );
    $due = Lazysite::Handlers::due_entries( Lazysite::Handlers::read_schedule(), { tick => { last_run => time + 9999 } }, time );
    is( scalar @$due, 1, 'a last run in the future is not a reason to stay silent for ever' );
};

subtest 'delivery: one function, one audit line per handler, visible fields only' => sub {
    my $d = fresh_site();
    Lazysite::Handlers::action_handler_save( { id => 'store', type => 'file', name => 'S' }, %ALL );
    Lazysite::Handlers::action_handler_save( { id => 'off', type => 'file', name => 'O', enabled => 'false' }, %ALL );
    my $r = Lazysite::Handlers::deliver( 'store', { name => 'Ada', _sneaky => 'x' },
        origin => 'form', source => 'form:contact', store => 'contact', ip => '203.0.113.5' );
    ok( $r->{ok}, 'a file handler delivers' ) or diag explain $r;
    my ($line) = split /\n/, slurp("$d/lazysite/forms/submissions/contact.jsonl") // '';
    my $rec    = JSON::PP::decode_json( $line // '{}' );
    is( $rec->{name}, 'Ada', 'the field is stored' );
    ok( !exists $rec->{_sneaky}, 'a _-prefixed key a caller passed is not' );
    is( $rec->{_ip}, '203.0.113.5', 'and the address that is known is' );

    $r = Lazysite::Handlers::deliver( 'off', { a => 1 }, origin => 'form', source => 'form:contact', store => 'contact' );
    like( $r->{why}, qr/switched off/, 'a switched-off handler says so, rather than silently delivering nothing' );
    $r = Lazysite::Handlers::deliver( 'ghost', { a => 1 }, origin => 'form', source => 'form:contact' );
    like( $r->{why}, qr/no handler 'ghost'/, 'an unknown handler says so' );

    $r = Lazysite::Handlers::deliver( 'store', { kind => 'ping' },
        origin => 'timer', source => 'timer:nightly', store => 'nightly', actor => 'jobs' );
    my $t = JSON::PP::decode_json( ( split /\n/, slurp("$d/lazysite/forms/submissions/nightly.jsonl") )[0] );
    is( $t->{_source}, 'timer:nightly', 'a timer delivery names where it came from' );

    my $audit = slurp("$d/lazysite/logs/audit.log") // '';
    like( $audit, qr/\|  \| deliver \| form:contact -> store \| 203\.0\.113\.5 \| ok \| form/,
        'the form delivery is one audit line: no actor, the source, the handler, the outcome' );
    like( $audit, qr/\| deliver \| form:contact -> off \|[^|]*\| failed \| form \| handler 'off' is switched off/,
        'a failed one says why' );
    like( $audit, qr/\| jobs \| deliver \| timer:nightly -> store \|  \| ok \| timer/,
        'and a timer delivery names the job account' );
    unlike( $audit, qr/Ada/, 'the fields are never in the trail' );
};

subtest 'a store that cannot be read is never overwritten (SM785\'s shape)' => sub {
    plan skip_all => 'root reads through a mode of 000' if $> == 0;
    my $d = fresh_site();
    Lazysite::Handlers::action_handler_save( { id => 'a', type => 'file', name => 'A' }, %ALL );
    Lazysite::Handlers::action_handler_save( { id => 'b', type => 'file', name => 'B' }, %ALL );
    my $f      = "$d/lazysite/forms/handlers.conf";
    my $before = slurp($f);
    chmod 0000, $f;
    my $r = Lazysite::Handlers::action_handler_save( { id => 'c', type => 'file', name => 'C' }, %ALL );
    ok( !$r->{ok}, 'a save over an unreadable handlers.conf is refused' );
    like( $r->{error}, qr/cannot be opened.*nothing was written/, 'saying so' );
    ok( !Lazysite::Handlers::action_handler_list()->{ok}, 'and the listing refuses rather than showing none' );
    chmod 0644, $f;
    is( slurp($f), $before, 'the two handlers are still there, byte for byte' );
};

subtest 'the conversion: one pass, reported, and a no-op the second time' => sub {
    my $d = fresh_site();
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n"
            . "  - id: local-storage\n    type: file\n    name: Local\n    path: lazysite/forms/submissions\n"
            . "  - id: rows\n    type: db\n    name: Rows\n    table: leads\n    fields: a=b\n"
            . "  - id: Slack\n    type: webhook\n    name: Slack\n    url: https://hooks.example/T1\n    format: slack\n"
            . "  - id: plain\n    type: webhook\n    name: Plain\n    url: http://intranet.example/hook\n" );
    spit( "$d/lazysite/forms/contact.conf", "rate_limit: 5\ntargets:\n  - type: file\n  - type: webhook\n    url: https://in.example/c\n" );
    spit( "$d/lazysite/forms/mixed.conf", "targets:\n  - handler: local-storage\n  - type: webhook\n    url: https://dormant.example/x\n" );
    Lazysite::Manager::Connectors::write_store( { tick => {
                url => 'https://t.example/x', method => 'POST', secret_header => 'Authorization',
                secret_prefix => 'Bearer ', modes => { scheduled => 1, authenticated => 1, public => 0 },
                callers => [], rate_per_hour => 60, timeout => 10, answer_table => '', data_class => 'form',
                row_table => '', row_map => {}, schedule_every => 900, schedule_payload => { r => 'd' } } } );

    my $r = Lazysite::Handlers::convert();
    ok( $r->{ok}, 'the conversion runs' ) or diag explain $r;
    my $all = { map { $_->{id} => $_ } @{ Lazysite::Handlers::read_handlers() } };
    is( $all->{rows}{type},      'table', 'a db handler became a table handler' );
    is( $all->{rows}{keep_copy}, 'false', 'keeping no copy, as db never did' );
    is( $all->{Slack}{type}, 'connector', 'an https webhook became a connector handler' );
    my $conns = Lazysite::Manager::Connectors::connectors();
    my $c     = $conns->{ $all->{Slack}{connector} };
    is( $c->{url}, 'https://hooks.example/T1', 'whose connector has the webhook\'s URL' );
    is( $c->{format}, 'slack',                 'and its body format' );
    ok( $c->{modes}{public} && !$c->{modes}{authenticated}, 'public, as a form needs, and nothing more' );
    is( $c->{rate_per_hour}, 0, 'with no rate cap, because the webhook had none' );
    is( $all->{plain}{type}, 'webhook', 'a plain-http webhook to another host is left as it was' );
    ok( ( grep { /'http:\/\/intranet.example\/hook' is neither/ } @{ $r->{left} } ),
        'and reported as not converted, with what to do' );

    my ($ids) = Lazysite::Handlers::parse_form_conf( slurp("$d/lazysite/forms/contact.conf") );
    is( $ids->[0], 'local-storage', 'an inline file target reuses the handler that already delivers there' );
    is( $all->{ $ids->[1] }{type}, 'connector', 'an inline webhook became a connector and a handler' );
    like( slurp("$d/lazysite/forms/contact.conf"), qr/^rate_limit: 5$/m, 'the form kept its other settings' );
    my ($mixed) = Lazysite::Handlers::parse_form_conf( slurp("$d/lazysite/forms/mixed.conf") );
    is_deeply( $mixed, ['local-storage'], 'an inline target beside a handler - which never delivered - was dropped' );
    ok( !( grep { ( $_->{url} // '' ) eq 'https://dormant.example/x' } values %$conns ),
        'and was not woken up as a connector' );

    ok( !exists $conns->{tick}{schedule_every}, 'the connector lost its schedule keys' );
    my ($entry) = @{ Lazysite::Handlers::read_schedule() };
    is( $entry->{every},                        900, 'which became a schedule entry' );
    is( $all->{ $entry->{handler} }{connector}, 'tick', 'calling a connector handler for it' );
    is( $entry->{payload}{r},                   'd', 'with the same fixed payload' );

    my $again = Lazysite::Handlers::convert();
    ok( $again->{ok}, 'a second run' );
    is_deeply( $again->{changed}, [], 'changes nothing' );
    is( scalar @{ $again->{left} }, 1, 'and still reports the one thing it cannot do' );
};

done_testing();

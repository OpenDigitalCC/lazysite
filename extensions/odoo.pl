#!/usr/bin/perl

# SM747: the Odoo extension - a page uses Odoo through named operations.
#
# A FACILITY, NOT AN APPLICATION. What a page does with Odoo - list stock, take
# an order into a basket, record a timesheet - is an operation pack in OOM
# (libodoo-oom-perl), not code here; lazysite names an operation, binds its
# parameters, renders what it is handed and presents a plan for confirmation.
# The engine is Lazysite::Odoo; this file declares the extension and answers
# --describe and the Status button.
#
# THE DEPENDENCY IS DECLARED WITH ITS PACKAGE AND VERSION, because guessing the
# package from the module name would tell an operator to install
# libodoo-ops-perl, which does not exist. 0.02 is the first deb to carry the
# Ops layer (the 0.01 deb carries the mapper alone - filed to OOM 2026-10-12).

use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    # As the data extension: find the Lazysite tree beside this script, and leave
    # --describe answerable when it is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
    # SM1369 X7: its own modules are in its payload lib, beside this file (the X1
    # rule), found by the one resolver; --describe needs none of them.
    eval { require Lazysite::Extensions; Lazysite::Extensions::add_payload_lib( Cwd::abs_path(__FILE__) ); 1 };
}

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'odoo',
        name        => 'Odoo',
        description => 'Pages use an Odoo instance through named operations - '
            . 'listing facts, or planning and applying changes - under a '
            . 'connection user whose rights are set in Odoo. The operations '
            . 'come from OOM operation packs; lazysite holds no Odoo knowledge.',
        version     => '0.1',
        config_file => 'lazysite/odoo.conf',

        # SM409: born disabled, executes only while listed.
        contract => 1,

        config_schema => [
            { key => 'odoo_url', label => 'Odoo address', type => 'text',
                note => 'https:// to any host. Plain http:// is accepted only to this '
                    . 'host (127.0.0.1 or localhost) - never to a private network '
                    . 'address: reach an internal Odoo over https:// to its private name.' },
            { key => 'odoo_db', label => 'Odoo database', type => 'text',
                note => 'The database name on that Odoo instance.' },
            { key => 'odoo_login', label => 'Connection user (Odoo login)', type => 'text',
                note => 'A site-level Odoo account. Its rights are set IN ODOO and are what '
                    . 'bound every operation run through it; lazysite grants it nothing. '
                    . 'Its API key is set separately and never shown.' },
            { key => 'odoo_timeout', label => 'Timeout per call (seconds)', type => 'text',
                default => '30',
                note    => 'How long one call to Odoo may take before it is given up and '
                    . 'the page told so.' },
            { key => 'odoo_max_kb', label => 'Largest answer accepted (KB)', type => 'text',
                default => '2048',
                note    => 'An answer over this is refused by name rather than read.' },
            { key => 'odoo_allow_writes', label => 'Allow writes', type => 'boolean',
                default => 'false',
                note    => 'Off: write operations can plan but never apply. Odoo\'s own '
                    . 'rights for the connection user still decide what an apply may do.' },
            { key => 'odoo_ca_file', label => 'CA bundle for the Odoo connection (file path)', type => 'text',
                note => 'Leave blank unless your Odoo is behind a certificate from a private '
                    . 'authority - the usual case for an internal Odoo reached over https:// to its '
                    . 'private name. A full path to a PEM file holding that authority\'s certificate; '
                    . 'it must be readable by the web server\'s user. It is used for the connection to '
                    . 'Odoo only: the rest of the server, and every other site on it, keeps the system '
                    . 'certificate store. Verification stays on.' },
            { key => 'odoo_remember_device', label => 'Offer "remember this device" at the two-factor step', type => 'boolean',
                default => 'false',
                note => 'Off: a person with two-factor authentication in Odoo is asked for the '
                    . 'code at every sign-in. On: the code step offers Odoo\'s own "don\'t ask '
                    . 'again on this device", and the browser keeps Odoo\'s device cookie (HttpOnly, '
                    . 'Secure, this site only) for as long as Odoo trusts it. Leave it off where a '
                    . 'browser is shared: whoever is signed in is responsible for that device. '
                    . 'Needs OOM 0.27 or later and an https:// site.' },
            { key => 'odoo_identity_ttl', label => 'Identity cookie lifetime (seconds)', type => 'text',
                default => '900',
                note => 'How long a page may show who a signed-in person is in Odoo before it is '
                    . 'asked of Odoo again (60 to 86400). Presentation only: never what a person '
                    . 'may do.' },
            { key => 'odoo_site_signin', label => 'The Odoo sign-in is the site sign-in', type => 'boolean',
                default => 'false',
                note => 'Off (the default): nothing changes. On: a person who signs in to Odoo through '
                    . 'this site (password, and the authenticator code where Odoo asks) is signed in to the '
                    . 'site as odoo:<their login>. No lazysite account is made or needed, and a person '
                    . 'disabled in Odoo cannot sign in. Pages show "Signed in as" with a sign-out that ends '
                    . 'the Odoo session too. Needs a secured site (a group that grants manager access) and '
                    . 'OOM 0.33 or later for groups.' },
            { key => 'odoo_group_map', label => 'Odoo groups that become site groups', type => 'text',
                validate => 'Lazysite::Odoo::SiteSignin::validate_group_map',
                note => 'Only with the Odoo sign-in as the site sign-in. Comma separated '
                    . '<Odoo group xml id> = <site group>, for example '
                    . 'sales_team.group_sale_salesman = sales, base.group_user = staff. Odoo is asked, as '
                    . 'the person, whether they hold each (at most 50); the held ones become site groups '
                    . 'that page access and file ACLs read. A site group that carries any capability '
                    . '(the manager, the API, anything on the Groups page) is refused by name: a person '
                    . 'signed in through Odoo is never given manager rights.' },
            # SM1328 (ruling 52): the one name every dialog and message says for Odoo.
            { key => 'odoo_display_name', label => 'Name shown for Odoo', type => 'text',
                default => 'Odoo',
                note => 'What the sign-in dialog, the sign-in page and button, and the messages a '
                    . 'visitor or a manager reads call Odoo - the name people know it by here. '
                    . 'Empty: they name nothing ("Sign in", "That sign-in was not accepted"). '
                    . 'A page already cached shows the old name until it is next rendered.' },
            { key => 'odoo_packs', label => 'Extra operation packs', type => 'text', list => ',',
                note => 'Leave blank unless you have installed an extra OOM operation pack. '
                    . 'An operation pack is a set of named Odoo operations (list, plan, apply); '
                    . 'OOM ships its own. Name each extra pack by its Perl namespace, comma '
                    . 'separated (for example Example::Odoo::Ops), and its operations become '
                    . 'callable by name from pages and agents beside OOM\'s.' },
            { key => 'odoo_daemon', label => 'Resident OOM (oomd)', type => 'text',
                default => 'off',
                note => 'off, on or required. On: the Odoo daemon extension\'s companion, oomd, a resident OOM that keeps OOM, '
                    . 'the operations, the sign-in and the TLS connection loaded, so a call takes tens of milliseconds '
                    . 'instead of most of a second. It runs under lazysited, so the daemon extension must be enabled '
                    . 'too, and needs the odoo-oom-tools package (oomd). If it is not running a call runs in-process '
                    . 'as before, slower and recorded as such. Required: the same, but a call is refused when the '
                    . 'daemon is not running, instead of falling back.' },
            { key => 'odoo_daemon_workers', label => 'Resident OOM workers', type => 'text',
                default => '4',
                note => 'How many requests oomd serves at once (1 to 64). Set it to match the number of workers '
                    . 'your Odoo runs, which lazysite cannot read from Odoo.' },
            { key => 'odoo_pack_dirs', label => 'Operation pack directories', type => 'text', list => ':',
                note => 'Leave blank unless this site carries its own OOM operation packs. A colon '
                    . 'separated list of full paths, each a directory that holds pack directories '
                    . '(each with a pack.yaml), for example /var/www/example/lazysite/odoo-packs. '
                    . 'A pack is code that runs as this site, so a directory must exist and lie '
                    . 'under this site\'s own tree, or be /usr/share/odoo-oom/packs; any other is '
                    . 'refused by name. A pack\'s operations are named pack.operation and bind '
                    . 'like any other.' },
        ],

        owns => {
            config_keys =>
                [qw(odoo_url odoo_db odoo_login odoo_timeout odoo_max_kb odoo_allow_writes odoo_ca_file odoo_remember_device odoo_identity_ttl odoo_site_signin odoo_group_map odoo_display_name odoo_packs odoo_pack_dirs odoo_daemon odoo_daemon_workers)],

            # NO `storage`, deliberately. lazysite/odoo/ holds the connection
            # user's key and plans carrying Odoo's own records; a site package
            # carries declared storage to another site, and neither belongs
            # there.
            # The page endpoint (SM411: it verifies its own caller).
            endpoints => ['lazysite-odoo.pl'],

            # SM1369 X2 (H-7, ruling 71): the two capabilities this extension
            # owns. manage_odoo (OM3) is its admin capability - the connection
            # user's key, the connection's state and the call record - which sat
            # under manage_connectors until X2; every group holding that is
            # topped up with this (`top_up_from`), so nothing changes for a
            # group. settle_odoo_writes (SM1276, rulings 10a-10c) is who may
            # say whether an Odoo change whose answer never came was made, on
            # another person's run, and dismiss a run. Each is described in
            # hooks.capability_info; core mirrors both from the extension index
            # (t/lint/76), never from a literal.
            capabilities => [qw(manage_odoo settle_odoo_writes)],

            deps => ['Odoo::Ops (libodoo-oom-perl >= 0.03)'],

            hooks => hooks(),
        },

        # SM1164 D1: a config save rewrites the daemon's config and tells the daemon.
        on_save => 'daemon-refresh',
        actions => [
            { id => 'status', label => 'Status', run => 'action', read => 1 },
            { id => 'daemon-refresh', label => 'Refresh the resident OOM', run => 'action', hidden => JSON::PP::true() },
        ],
    };
}

# SM1369 X2 (H-7, H-9): WHAT THIS EXTENSION DECLARES TO CORE, and core carries
# from the extension index: its capabilities' metadata, its ten control-API
# actions with their MCP twins, and the refusal kinds its answers carry. The
# wire is what it was before X2 - the names, the gates (manage_odoo for what
# was manage_connectors', with the top-up), the parameters, the twins'
# descriptions and schemas, the hints derived from each row - and the handlers
# are Lazysite::Odoo::Actions, in this extension's payload lib.
sub hooks {
    my $F   = JSON::PP::false();
    my $str = sub { { type => 'string' } };
    return {
        capability_info => {
            manage_odoo => {
                section => 'Site',
                label   => 'Odoo connection',
                title => 'Configure the Odoo connection: the connection user\'s key, each grant\'s and '
                    . 'scheduled binding\'s own Odoo account, the connection\'s state and the record of every call.',
                grants => 'Set and clear the API key of the Odoo connection user, and of the Odoo account a '
                    . 'lazysite account\'s MCP calls or a scheduled binding runs as (never read one back); read '
                    . 'the connection\'s state and the record of every Odoo call, which names who caused each, '
                    . 'through which binding and operation, and how it ended - never a payload or a credential. '
                    . 'Run any Odoo binding, as manage_connectors may call any connector. Was manage_connectors\' '
                    . 'until 0.16.8 (ruling 71): every group holding manage_connectors is topped up with this on '
                    . 'next use, so nothing changes for a group.',
                top_up_from => ['manage_connectors'],
                unlocks => { ui => ['the Odoo extension\'s settings and Status (Extensions)'] },
            },
            settle_odoo_writes => {
                section => 'Operations',
                label   => 'Settle Odoo writes',
                title => 'Settle an Odoo write whose answer never came: say it was made or was '
                    . 'not, on any run, and dismiss a run. The run\'s own maker may decide for '
                    . 'their own run without this. Declared by the Odoo extension.',
                grants => 'Decide, for a change Odoo cannot be asked about, whether it was made, on a run anyone '
                    . 'made, and dismiss an unsettled run so it is no longer offered. Every decision and every '
                    . 'dismissal is one call record and one audit line naming who. Held by the operator group by default.',
                unlocks => { ui => ['the Unknown Odoo writes panel of the Odoo extension (Extensions)'] },
            },
        },

        # SM747 CU: the connection user. The key is set and cleared, never read.
        # SM747 E: every one has its MCP twin (R5, "All operations should also be
        # mcp tools"); `grant` names the lazysite account an MCP grant's own Odoo
        # account belongs to (Q2). An operation reaches an agent through a
        # BINDING, as it reaches a page: the binding's modes, callers and caps
        # decide, and only the fields it maps may be sent. An agent is an
        # AUTHENTICATED caller and never a visitor, so a binding that works on a
        # visitor's key is neither listed nor run here.
        api_actions => [
            { name => 'odoo-status', mcp => 'odoo_status', handler => 'Lazysite::Odoo::Actions::status',
                gate => ['manage_odoo'], cookie_cap => 'manage_odoo', params => [],
                description => 'The Odoo connection: whether OOM is installed, the connection settings, whether the connection user (and each grant\'s and scheduled binding\'s own Odoo account) has a key, and when a scheduled key expires where OOM reports it - never the key - and the operations installed.',
                input_schema => { type => 'object', properties => {}, additionalProperties => $F },
            },
            { name => 'odoo-calls', mcp => 'odoo_calls', handler => 'Lazysite::Odoo::Actions::calls',
                gate => ['manage_odoo'], cookie_cap => 'manage_odoo',
                params => [ { name => 'binding', in => 'query' }, { name => 'limit', in => 'query' } ],
                description => 'The record of Odoo calls, newest first: who caused each, through which binding and operation, in which mode, and how it ended. Never a payload or a credential.',
                input_schema => { type => 'object',
                    properties => { binding => $str->(), limit => { type => 'integer' } }, additionalProperties => $F },
            },
            { name => 'odoo-secret-set', mcp => 'odoo_secret_set', handler => 'Lazysite::Odoo::Actions::secret_set',
                gate => ['manage_odoo'], cookie_cap => 'manage_odoo', instance_wide => 1, mutates => 1,
                params => [
                    { name => 'secret', in => 'body', required => 1 },
                    { name => 'grant', in => 'body', note => 'a lazysite account: its MCP calls run as this Odoo account' },
                    { name => 'scheduled', in => 'body', note => 'a scheduled binding id: it runs as this Odoo login' },
                    { name => 'login', in => 'body', note => 'the Odoo login, with grant or scheduled' },
                ],
                description => 'Set the API key of the Odoo connection user, or - with `grant` and `login` - of the Odoo account a lazysite account\'s MCP calls run as, or - with `scheduled` (a binding id) and `login` - of the Odoo login that scheduled binding runs as. The key is stored on its own and never returned.',
                input_schema => { type => 'object',
                    properties => { secret => $str->(), grant => $str->(), scheduled => $str->(), login => $str->() },
                    required => ['secret'], additionalProperties => $F },
            },
            { name => 'odoo-secret-clear', mcp => 'odoo_secret_clear', handler => 'Lazysite::Odoo::Actions::secret_clear',
                gate => ['manage_odoo'], cookie_cap => 'manage_odoo', instance_wide => 1, mutates => 1, destructive => 1,
                params => [ { name => 'grant', in => 'body' }, { name => 'scheduled', in => 'body' } ],
                description => 'Remove the Odoo connection user\'s API key, or - with `grant` - a grant\'s own Odoo account, or - with `scheduled` - a scheduled binding\'s own Odoo login.',
                input_schema => { type => 'object', properties => { grant => $str->(), scheduled => $str->() },
                    additionalProperties => $F },
            },
            # SM747 E: running a bound operation is gated by the BINDING - its
            # modes, callers and caps (Lazysite::Odoo::may_call) - as
            # connector-call is gated by its connector, so any signed-in caller
            # reaches the action and the binding decides. openWorld: the call
            # leaves this instance for Odoo.
            { name => 'odoo-bindings', mcp => 'odoo_bindings', handler => 'Lazysite::Odoo::Actions::bindings',
                gate => 'ALWAYS', always_reason => 'the BINDING decides, by its modes, callers and caps (Lazysite::Odoo::may_call), as the connector decides connector-call; this lists the bindings this account may run',
                params => [],
                description => 'The Odoo bindings this account may run: each one\'s operation, what it does, whether it writes, and the fields it takes.',
                input_schema => { type => 'object', properties => {}, additionalProperties => $F },
            },
            { name => 'odoo-run', mcp => 'odoo_run', handler => 'Lazysite::Odoo::Actions::run',
                gate => 'ALWAYS', always_reason => 'the BINDING decides, by its modes, callers and caps (Lazysite::Odoo::may_call), as the connector decides connector-call',
                mutates => 1, open_world => 1,
                params  => [
                    { name => 'binding', in => 'body', required => 1 },
                    { name => 'params', in => 'body', note => 'the request fields the binding maps; nothing else is taken' },
                ],
                description => 'Run an Odoo binding by its id with the fields it takes. A read answers its report; a write answers its plan to confirm with odoo_confirm, or - where the binding says immediate - applies it. The binding decides whether this account may, and how often.',
                input_schema => { type => 'object', properties => { binding => $str->(), params => { type => 'object' } },
                    required => ['binding'], additionalProperties => $F },
            },
            { name => 'odoo-confirm', mcp => 'odoo_confirm', handler => 'Lazysite::Odoo::Actions::confirm',
                gate => 'ALWAYS', always_reason => 'a plan is applied only by the account that made it, through the binding that decided the run (Lazysite::Odoo::may_call)',
                mutates => 1, open_world => 1,
                params  => [ { name => 'plan', in => 'body', required => 1 } ],
                description => 'Apply a plan odoo_run gave you, by its id. Only the account that made a plan may apply it, within an hour, through the binding as it stands now.',
                input_schema => { type => 'object', properties => { plan => $str->() }, required => ['plan'],
                    additionalProperties => $F },
            },
            # SM1278 (rulings 10b, 10c): the runs left unknown, an operator's
            # decision on one, and dismissing one. Listing and dismissing are
            # settle_odoo_writes'; a resume is gated by the run's binding inside
            # Lazysite::Odoo::resume, as a confirm is. openWorld: OOM reads the
            # run back from Odoo and applies the rest.
            { name => 'odoo-resume', mcp => 'odoo_resume', handler => 'Lazysite::Odoo::Actions::resume',
                gate => 'ALWAYS', always_reason => 'the run\'s BINDING decides who may resume it (Lazysite::Odoo::resume), as a confirm is decided; a change that cannot be read back is settled only by the run\'s maker or a holder of settle_odoo_writes, checked inside',
                mutates => 1, open_world => 1,
                params  => [
                    { name => 'run', in => 'body', required => 1, note => 'the run an apply named, or one from odoo-unknown-runs' },
                    { name => 'assume_done', in => 'body', note => 'change keys or numbers you say were made (the run\'s maker, or settle_odoo_writes)' },
                    { name => 'assume_not_done', in => 'body', note => 'change keys or numbers you say were not made' },
                ],
                description => 'Resume an Odoo run whose apply left a change unknown (its request was sent and no answer came), by the run an answer named. OOM reads each such change back first; one it cannot read back is refused unknown-outcome until you say it was made (assume_done) or was not (assume_not_done) - only the run\'s maker, or a holder of settle_odoo_writes, may say. The rest of the run is then applied.',
                input_schema => { type => 'object',
                    properties => { run => $str->(),
                        assume_done     => { type => 'array', items => $str->() },
                        assume_not_done => { type => 'array', items => $str->() } },
                    required => ['run'], additionalProperties => $F },
            },
            { name => 'odoo-unknown-runs', mcp => 'odoo_unknown_runs', handler => 'Lazysite::Odoo::Actions::unknown_runs',
                gate => ['settle_odoo_writes'], cookie_cap => 'settle_odoo_writes', params => [],
                description => 'The Odoo runs whose apply left a change unknown and that are not yet settled or dismissed, newest first: the binding, who made the run, when, and each change still unknown (its key, action, model and record). Never a value.',
                input_schema => { type => 'object', properties => {}, additionalProperties => $F },
            },
            { name => 'odoo-dismiss', mcp => 'odoo_dismiss', handler => 'Lazysite::Odoo::Actions::dismiss',
                gate => ['settle_odoo_writes'], cookie_cap => 'settle_odoo_writes', mutates => 1,
                params => [
                    { name => 'run', in => 'body', required => 1 },
                    { name => 'reason', in => 'body', note => 'a line of text kept with the run' },
                ],
                description => 'Dismiss an Odoo run left unknown: it is no longer offered for resuming, and is kept as dismissed with who, when and the reason given. Nothing is sent to Odoo.',
                input_schema => { type => 'object', properties => { run => $str->(), reason => $str->() },
                    required => ['run'], additionalProperties => $F },
            },
        ],

        # SM747: this extension's refusal kinds (Lazysite::Odoo::fault and its
        # gate) and the status the control API and the page endpoint send for
        # each. Odoo answering badly is a BAD GATEWAY - the request was fine and
        # the upstream was not - except where Odoo refused this caller's
        # operation (403) or the record is gone (404). A plan that can no longer
        # apply is a conflict with the state it was made against. SM1275: a run
        # left unknown that OOM cannot read back (a person must say), or one
        # already settled or dismissed, is each in conflict with the state the
        # run is in. B: a person signed in to Odoo has to sign in again (none,
        # ended, or refused; SM1157: Odoo refused the authenticator code, or
        # waits for it). `method`: the page endpoint, a write sent as a GET.
        refusal_kinds => {
            ( map { $_ => '403 Forbidden' } qw(mode scope-refused odoo-access-refused read-only no-owner wrong-domain two-factor) ),
            ( map { $_ => '401 Unauthorized' } qw(signin-required signin-refused second-factor second-factor-required) ),
            ( map { $_ => '404 Not Found' } qw(no-operation odoo-missing) ),
            ( map { $_ => '409 Conflict' } qw(stale applied edited binding instance unknown-outcome settled dismissed) ),
            ( map { $_ => '502 Bad Gateway' } qw(transport-failure odoo-fault invalid-credential session-expired) ),
            'odoo-validation'  => '422 Unprocessable Content',
            'apply-incomplete' => '207 Multi-Status',
            'method'           => '405 Method Not Allowed',
            ( map { $_ => '503 Service Unavailable' } qw(no-key config) ),
        },
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1 if $argv[$i] eq '--describe';
        $opt{status} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'status';
        $opt{refresh} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'daemon-refresh';
        $opt{status}  = 1                     if $argv[$i] eq '--scan';
        $opt{docroot} = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    if ( $opt{refresh} ) {
        print encode_json( refresh( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }
    if ( $opt{status} ) {
        print encode_json( status( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe | --action status --docroot DIR' } );
    return 1;
}

# SM1164 D1: the on_save hook. The daemon's config is written from the saved
# config (or removed when odoo_daemon is off) and a running daemon is sent
# SIGHUP. Reports; never fails the save.
sub refresh {
    my ($docroot) = @_;
    my $have = eval { require Lazysite::Odoo::Daemon; 1 };
    return { ok => 0, error => 'the lazysite modules could not be loaded' } unless $have;
    my $r = Lazysite::Odoo::Daemon::refresh($docroot);
    return { ok => $r->{ok} ? 1 : 0, ( $r->{ok} ? () : ( error => $r->{error} ) ), changed => $r->{changed} ? 1 : 0 };
}

# What an operator needs before trusting it: is OOM here and new enough, and is
# the connection configured. REPORTS, never repairs, and never shows the key.
sub status {
    my ($docroot) = @_;
    my %out       = ( ok => 1 );
    my $have      = eval { require Lazysite::Odoo; 1 };
    unless ($have) {
        $out{message} = 'Odoo: the lazysite modules could not be loaded';
        return \%out;
    }
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $docroot;
    my ( $oom, $why ) = Lazysite::Odoo::oom_check();
    $out{oom} = $oom ? 'present' : $why;
    my ( $conn, $cwhy ) = Lazysite::Odoo::connection();
    $out{connection} = $conn ? { url => $conn->{url}, db => $conn->{db}, login => $conn->{login},
        allow_writes => $conn->{allow_writes} } : { problem => $cwhy };
    $out{message} = 'Odoo: '
        . ( !$oom ? $why : !$conn ? "not configured - $cwhy" : "connection user $conn->{login} on $conn->{url}" );
    return \%out;
}

1;

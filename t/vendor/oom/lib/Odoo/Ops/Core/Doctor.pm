package Odoo::Ops::Core::Doctor;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use JSON::PP ();
use Odoo::JSON ();
use Scalar::Util qw(blessed);
use HTTP::Tiny;
use Time::Local ();

use parent 'Odoo::Ops::Operation';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Credential;
use Odoo::Ops::Modules;
use Odoo::Ops::Profile;
use Odoo::Ops::Runs;
use Odoo::Transport;

=head1 NAME

Odoo::Ops::Core::Doctor - one report on whether a config can do what it claims

=head1 SYNOPSIS

    oom-ops doctor --conf site.conf [--json]
    oom-ops run core.doctor --conf site.conf

    my $report = Odoo::Ops::Core::Doctor->examine('site.conf');
    print Odoo::Ops::Core::Doctor->format_text($report);
    exit $report->{summary}{exit};

=head1 DESCRIPTION

C<core.doctor>: the config, the credential file, the TLS chain, the
server, the login, the database, the profiles and behaviours, the
modules, and (when C<allow_writes = 1>) what a write would meet, in
one report. It writes nothing and fixes nothing.

Each check has a C<name>, a C<status> and one C<detail> line a person
acts on. Statuses: C<ok>, C<warn>, C<fail>, C<info> (a fact, never a warning; the exit code ignores it), and C<skipped> (an earlier
failure left nothing to run it against; the detail says which). The
report is C<< { checks => [...], summary => {...}, series, uid } >>;
C<summary> carries the counts, a C<text> line and the C<exit> code
(0 all ok, 1 a warning, 2 a failure).

Checks, in order, and what a failure in each one skips:

    config.*       the file, its keys, url, login and db, transport,
                   runs_dir, allow_writes, and mailcatcher (C<info> when
                   absent, C<ok> when it answers, C<warn> when it does
                   not). A file that does not load
                   skips everything.
    credential.*   the key file (exists, regular, mode 0600 or
                   stricter, not empty), or for credential = password the
                   password file (the same rules). A failure skips
                   authentication and everything after it.
    tls.*          ssl_ca_file parses; the server certificate verifies
                   against it; its subject and expiry. A failure skips
                   reachability and everything after it.
    reach.*        common.version answers (series), /web/login answers
                   200, clock skew from the Date header. No version
                   skips authentication and everything after it.
    auth.*         the transport is served on this series, the login
                   authenticates (uid), the user's name and email, the
                   groups base.group_system, base.group_user and
                   base.group_portal.
    transport.session
                   C<ok> with the login when the credential is password and
                   its web session opened; C<info> for any other credential
                   (core.report render needs a web session).
    config.cache   C<info>: the cache directory, its mode and the file names in it
                   (C<warn> when the mode lets others in); C<cache = 0> says so.
                   The login and version checks ask Odoo for real, whatever is
                   remembered.
    config.fields_cache
                   C<info>: whether this login's field definitions are kept and through which
                   login the state of C<ir.model.fields> is read (C<the daemon's own connection
                   login>, a C<cache_stamp_conf> config's name, or the login itself); C<warn>
                   when the named login cannot read it either. Never a credential.
    config.data_cache
                   C<info>: whether the data cache is on, and when it is, its directory, how
                   many files it holds, how many bytes, and the cap per login; C<warn> when
                   its directory lets others in. Never contents.
    act_as         C<info>: the service credential an operation that acts for a person writes with
                   (L<Odoo::Ops::Acting>): the label of oomd's C<act_as> or the config named by
                   C<act_as_conf>, and the login it signs in as; C<fail> when it does not sign in
                   (Odoo's words). Nothing is reported when the config names none. Never a credential.
    pack.*         one line for each pack the config's C<pack_dirs> hold (L<Odoo::Ops::Pack>):
                   C<ok> with its version, C<oom_min> and series; a pack that was refused
                   is C<warn> with the reason, C<fail> when the config's C<pack> names it.
                   Nothing is reported when no pack is configured.
    server.wkhtmltopdf
                   the state Odoo reports for its pdf renderer
                   (C<get_wkhtmltopdf_state>): C<ok> for ok and upgrade,
                   C<warn> for workers, broken or install (core.report pdf
                   will fail), C<info> when the series refuses the call.
    db.*           the configured db is the one served; whether
                   db/list is refused (the good case) or open.
    profile.*, behaviour.*, probe.*
                   every profile pack validated against the server,
                   every behaviour file of its models, the behaviour
                   probes as core.check runs them. A pack whose own
                   module is not installed (C<module:> of its profile) is
                   C<info>, "not applicable here", before any series
                   question; a mapped field whose module is not installed
                   is an C<info> line of its own and the pack stays C<ok>.
                   A pack whose own
                   C<Common::ready> refuses the series (C<refused/series>) is
                   C<info>.
                   probe.rights:<model> for each model doctor reads beyond
                   the login (ir.model.data, ir.cron, ir.mail_server,
                   ir.config_parameter): ok when readable, info with Odoo's
                   own refusal text when not.
    module.*       one line for each module the behaviour files and the
                   profiles name (a model's, action's or wizard's
                   C<module>, a C<module:X> probe, a profile's pack, model
                   and field C<module>): C<ok> when installed, C<info> when
                   not, saying what names it. There is no list here. When
                   C<ir.module.module> is not readable by the user: one
                   C<info> line, C<modules>, with Odoo's text.
    write.*        only with allow_writes = 1: web.base.url against the
                   config's host, mail.catchall.domain, outgoing mail
                   servers, the acting user's notification_type.
    runs           the newest run under runs_dir, its state, and
                   whether its instance is this config's.

No secret appears in a detail: a key file is named by path and mode,
never by content, and a url's user info is dropped.

The checks that need no connection (C<config.*>, C<credential.*>,
C<tls.*>) also run from L</examine> when the config cannot build a
context, so a missing key file is reported rather than thrown.

=cut

sub op_name ($class) { 'core.doctor' }
sub summary ($class) { 'Whether this config can do what it claims: config, credential, TLS, server, login, profiles, modules' }

# every call the checks make: the base scope covers fields_get and
# res.users.read; has_group is the group test
sub read_scope ($class) {
    return {
        'res.users'          => [qw(read has_group)],
        'res.company'        => ['search_count'],
        'ir.module.module'   => ['search_read'],
        'ir.config_parameter' => [qw(search_read search_count)],
        'ir.mail_server'     => ['search_count'],
        'ir.model.data'      => ['search_count'],
        'ir.cron'            => ['search_count'],
        'ir.actions.report'  => ['get_wkhtmltopdf_state'],
    };
}

# http and tls are injectable so the offline test needs no network:
#   http: an object with get($url) and post($url, \%opts), HTTP::Tiny's shape
#   catcher_http: the same, for the mail catcher's /api/v1/info only
#   tls:  sub ($host, $port, $ca_file) returning { verified, error, subject, not_after (epoch) }
sub new ($class, %args) {
    my $self = $class->SUPER::new(%args);
    $self->{http} = $args{http};
    $self->{tls}  = $args{tls};
    $self->{catcher_http} = $args{catcher_http};
    return $self;
}

=head2 examine($conf_path, %opts)

Class method: the whole report for a config file, including a file
that does not load and a credential that cannot be resolved. Options
C<http>, C<catcher_http>, C<tls>, C<transport> and C<now> are for tests.

=cut

sub examine ($class, $path, %opts) {
    my $config = eval { Odoo::Ops::Config->load($path) };
    if ( !$config ) {
        my @c = $class->_load_failure( $path, $@ );
        return _finish( \@c, undef, undef );
    }
    my $ctx = eval { $class->_context( $config, %opts ) };
    if ( !$ctx ) {
        my $why = _msg($@);
        my @c   = $class->_static_checks($config);
        push @c, _check( 'config.context', 'fail', $why );
        push @c, map { _check( $_, 'skipped', 'the config cannot build a connection' ) } qw(reach.version auth.login);
        return _finish( \@c, undef, undef );
    }
    my $op = $class->new( ctx => $ctx, params => {}, http => $opts{http}, tls => $opts{tls}, catcher_http => $opts{catcher_http} );
    return $op->run;
}

# a context for the checks: when the credential file is the fault, a
# placeholder keeps the unauthenticated checks (TLS, version) runnable
sub _context ($class, $config, %opts) {
    # a password credential opens its web session in the report, not here: a refused login is a line of it
    my %extra = ( defer_login => 1, cache => 0, ($opts{now} ? ( now => $opts{now} ) : ()), ($opts{transport} ? ( transport => $opts{transport} ) : ()) );
    my $ctx = eval { Odoo::Ops::Context->new( config => $config, %extra ) };
    return $ctx if $ctx;
    my $err = $@;
    die $err if !( blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'config' );
    return Odoo::Ops::Context->new(
        config     => $config,
        credential => { login => $config->get('login'), api_key => 'doctor-placeholder' },
        %extra,
    );
}

sub _load_failure ($class, $path, $err) {
    my $m = _msg($err);
    my @c;
    if ( $m =~ /api_key inline|password/ && $m =~ /refused/ ) {
        push @c, _check( 'config.file', 'ok', 'readable' ), _check( 'credential.inline', 'fail', _strip($m) );
    }
    elsif ( $m =~ /a session is a run-time value/ ) {
        push @c, _check( 'config.file', 'ok', 'readable' ), _check( 'credential.session', 'fail', _strip($m) );
    }
    elsif ( $m =~ /unknown key/ ) {
        push @c, _check( 'config.file', 'ok', 'parses' ), _check( 'config.keys', 'fail', _strip($m) );
    }
    elsif ( $m =~ /config missing/ ) {
        push @c, _check( 'config.file', 'ok', 'parses' ), _check( 'config.fields', 'fail', _strip($m) );
    }
    else {
        push @c, _check( 'config.file', 'fail', _strip($m) );
    }
    push @c, _check( $_, 'skipped', 'the config does not load' ) for qw(credential.key_file tls.ca reach.version auth.login);
    return @c;
}

sub report ($self) {
    my $ctx    = $self->ctx;
    my $config = $ctx->config;
    my @c      = $self->_static_checks($config);
    push @c, $self->_catcher_check($config);
    push @c, $self->_cache_check($config);
    push @c, $self->_data_cache_check($config);
    push @c, $self->_pack_dir_checks($config);
    push @c, $self->_tls_chain($config);

    my $cred_ok     = !( grep { $_->{name} =~ /^credential\./ && $_->{status} eq 'fail' } @c );
    my $tls_ok      = !( grep { $_->{name} =~ /^tls\./ && $_->{status} eq 'fail' } @c );
    my ( $series, $uid );

    # reachability: no key needed
    my $reach_ok = 0;
    if ( !$tls_ok ) {
        push @c, _check( $_, 'skipped', 'the TLS check failed' ) for qw(reach.version reach.login_page reach.clock);
    }
    else {
        my $v = eval { $self->client->version };
        if ( !$v ) {
            push @c, _check( 'reach.version', 'fail', 'common.version did not answer: ' . _strip( _msg($@) ) );
            push @c, _check( $_, 'skipped', 'the server did not answer common.version' ) for qw(reach.login_page reach.clock);
        }
        else {
            $series = eval { $self->client->server_series };
            if ( $series ) {
                $reach_ok = 1;
                push @c, _check( 'reach.version', 'ok', "server_version $v->{server_version}, series $series" );
            }
            else {
                push @c, _check( 'reach.version', 'fail', 'cannot read a series from the version answer' );
            }
            push @c, $self->_web_checks($config);
        }
    }

    # the database list is asked without a key
    push @c, $reach_ok ? $self->_db_list($config) : _check( 'db.list', 'skipped', 'the server is not reachable' );

    # authentication
    my $auth_ok = 0;
    if ( !$reach_ok ) {
        push @c, _check( $_, 'skipped', 'the server is not reachable' ) for qw(auth.transport auth.login);
    }
    else {
        my $by_password = ( $config->get('credential') // 'file' ) eq 'password';
        my $tr = $by_password ? 'session' : ( $config->get('transport') // 'jsonrpc' );
        if ( $tr eq 'json2' && $series < 19 ) {
            push @c, _check( 'auth.transport', 'fail', "transport json2 is served on 19 only (docs/MAPPER-SPEC.md section 9); this server is series $series" );
            push @c, _check( 'auth.login', 'skipped', 'the transport is not served on this series' );
        }
        else {
            push @c, _check( 'auth.transport', 'ok', $by_password ? "session (credential password) on series $series" : "$tr on series $series" );
            if ( !$cred_ok ) {
                push @c, _check( 'auth.login', 'skipped', 'the credential check failed' );
            }
            else {
                my @a = $self->_auth_checks($config);
                $auth_ok = !( grep { $_->{status} eq 'fail' } @a );
                $uid     = eval { $self->client->uid } if $auth_ok;
                push @c, @a;
            }
        }
    }

    push @c, $self->_session_check($config);

    my $why = !$reach_ok ? 'the server is not reachable' : 'authentication failed or was skipped';
    if ( !$auth_ok ) {
        push @c, _check( $_, 'skipped', $why ) for qw(db.served profile modules server.wkhtmltopdf);
        push @c, _check( 'write', 'skipped', $why ) if $config->allow_writes;
    }
    else {
        push @c, $self->_db_served($config);
        push @c, $self->_pack_checks($config);
        push @c, $self->_rights_checks;
        push @c, $self->_module_checks;
        push @c, $self->_wkhtmltopdf_check( $series );
        push @c, $self->_write_checks($config) if $config->allow_writes;
    }

    push @c, $self->_fields_cache_check( $config, $uid );
    push @c, $self->_act_as_check;
    push @c, $self->_runs_check($config);
    return _finish( \@c, $series, $uid, $config );
}

# The cache directory (docs/OPS.md, Speed): where it is, its mode and the file names in it. The
# contents are not read out: the report names what is held, never a value. The checks above ask
# Odoo for real (the context is made with cache => 0), so a remembered answer never stands for one.
sub _cache_check ($self, $config) {
    require Odoo::Cache;
    return _check( 'config.cache', 'info', 'cache = 0: nothing is remembered between processes' ) if !$config->cache_enabled;
    my $d = Odoo::Cache->new( dir => $config->cache_dir // Odoo::Cache->default_dir )->describe;
    my $shown = _scrub( $d->{dir} );
    return _check( 'config.cache', 'info', "$shown does not exist yet; the first cold process makes it (mode 0700)" ) if !$d->{exists};
    my $held = @{ $d->{files} } ? join( ', ', map { "$_->{name} ($_->{mode})" } @{ $d->{files} } ) : 'nothing yet';
    return _check( 'config.cache', 'warn', "$shown is mode $d->{mode}; it should be 0700 (chmod 700); holds $held" ) if $d->{mode} ne '0700';
    my @loose = grep { $_->{mode} ne '0600' } @{ $d->{files} };
    return _check( 'config.cache', 'warn', "$shown holds files that are not 0600: " . join( ', ', map { $_->{name} } @loose ) . '; they are not read' ) if @loose;
    return _check( 'config.cache', 'info', "$shown, mode $d->{mode}; holds $held" );
}

# Whether this login's field definitions are kept, and through which login the state of ir.model.fields is read
# (a config name or the daemon, never a credential).
sub _fields_cache_check ($self, $config, $uid) {
    return _check( 'config.fields_cache', 'info', 'cache = 0: field definitions are read from Odoo every time' ) if !$config->cache_enabled;
    return _check( 'config.fields_cache', 'skipped', 'the login did not authenticate' ) if !defined $uid;
    my $ctx = $self->ctx;
    if ( my $via = $ctx->stamp_via ) {
        my $what = $via eq 'daemon' ? "the daemon's own connection login" : "the login of config " . ( $via =~ s{\Aconf:}{}r ) . ' (cache_stamp_conf)';
        return _check( 'config.fields_cache', 'info', "field definitions are kept for this login; the state of ir.model.fields is read through $what" )
            if defined $ctx->stamp_state;
        return _check( 'config.fields_cache', 'warn', "field definitions are not kept for this login: $what may not read ir.model.fields either; name a login that may" );
    }
    return _check( 'config.fields_cache', 'info', 'field definitions are kept for this login; it reads ir.model.fields itself' )
        if defined eval { $self->client->fields_stamp };
    return _check( 'config.fields_cache', 'info', 'field definitions are not kept for this login: it may not read ir.model.fields and no login is named to read it; set cache_stamp_conf to an ops config whose login may (oomd uses its own connection credential)' );
}

# The service credential of an operation that acts for a person: its name, whether it signs in and the login.
sub _act_as_check ($self) {
    require Odoo::Ops::Acting;
    my $d = Odoo::Ops::Acting->describe( $self->ctx );
    return () if !$d->{configured};
    my $what = ( $d->{kind} // '' ) eq 'act_as' ? "label '$d->{name}' (act_as)" : "config $d->{name} (act_as_conf)";
    return _check( 'act_as', 'fail', "$what: " . _scrub( $d->{error} // 'cannot be read' ) ) if !defined $d->{signs_in};
    return _check( 'act_as', 'fail', "$what does not sign in: " . _scrub( $d->{error} // '' ) ) if !$d->{signs_in};
    return _check( 'act_as', 'info', "$what signs in as $d->{login}" );
}

# The data cache (docs/OPS.md, Data cache): on or off, and when on where it is and how much it holds.
# Counts and bytes only; a row is never read out.
sub _data_cache_check ($self, $config) {
    require Odoo::Cache::Data;
    return _check( 'config.data_cache', 'info', 'data_cache = 0: a read is always live' ) if !$config->data_cache;
    return _check( 'config.data_cache', 'info', 'data_cache = 1 needs cache = 1: a read is always live' ) if !$config->cache_enabled;
    my $dir = $config->cache_dir // Odoo::Cache->default_dir;
    my $d   = Odoo::Cache::Data->describe($dir);
    my $shown = _scrub( $d->{dir} );
    my $cap   = $config->data_cache_max_mb;
    return _check( 'config.data_cache', 'info', "$shown does not exist yet; the first cached read makes it (mode 0700); cap $cap MB per login" ) if !$d->{exists};
    my $mode = sprintf '%04o', ( stat $d->{dir} )[2] & 0777;
    my $held = "$d->{files} files, $d->{bytes} bytes, $d->{logins} login" . ( $d->{logins} == 1 ? '' : 's' ) . "; cap $cap MB per login";
    return _check( 'config.data_cache', 'warn', "$shown is mode $mode; it should be 0700 (chmod 700); $held" ) if $mode ne '0700';
    return _check( 'config.data_cache', 'info', "$shown, mode $mode; $held" );
}

# The packs the config's pack_dirs hold: each loaded one with its version, each refused one with the reason
sub _pack_dir_checks ($self, $config) {
    require Odoo::Ops::Registry;
    my $reg = Odoo::Ops::Registry->new( config => $config );
    my %packs = $reg->packs;
    my %named = map { $_ => 1 } $config->pack_only;
    my @c;
    for my $n ( sort keys %packs ) {
        my $p = $packs{$n};
        push @c, _check( "pack.$n", 'ok', "version $p->{version}, needs OOM $p->{oom_min}, series " . join( ' ', @{ $p->{series} } )
            . ', operations ' . join( ' ', grep { ( $reg->pack_of($_) // '' ) eq $n } $reg->names ) );
    }
    for my $r ( $reg->refused ) {
        push @c, _check( "pack.$r->{name}", $named{ $r->{name} } ? 'fail' : 'warn', 'refused: ' . _scrub( $r->{reason} ) );
    }
    return @c;
}

# The one config key a mailshot trial depends on. Absent is information, not a
# warning: a real instance has no catcher and the exit code must not change.
# A short timeout of its own: the catcher is a local development aid, so a
# dead one must not hold the report for the 15 s the Odoo checks allow.
sub _catcher_check ($self, $config) {
    my $url = $config->get('mailcatcher');
    return _check( 'config.mailcatcher', 'info', Odoo::Ops::Config->no_catcher_sentence )
        if !defined $url || $url eq '';
    my $shown = _scrub($url);
    my $http  = $self->{catcher_http} // HTTP::Tiny->new( timeout => 2, agent => 'odoo-oom-perl-doctor' );
    my $res   = eval { $http->get( $url =~ s{/+\z}{}r . '/api/v1/info' ) };
    return _check( 'config.mailcatcher', 'ok', "$shown answers /api/v1/info" )
        if $res && $res->{success} && ( $res->{status} // 0 ) == 200;
    my $why = !$res ? _strip( _msg($@) ) : ( $res->{status} // 0 ) == 599 ? _strip( $res->{content} // 'no answer' ) : 'HTTP ' . ( $res->{status} // '?' );
    return _check( 'config.mailcatcher', 'warn', "$shown does not answer /api/v1/info ($why): oom-mailshot test will show mailing.preview's rendering instead" );
}

# --- config, credential, TLS: no connection ---------------------------------

sub _static_checks ($class, $config) {
    my @c = ( _check( 'config.file', 'ok', 'loaded ' . ( $config->path // '(in memory)' ) ), _check( 'config.keys', 'ok', 'every key is known' ) );

    my $url = $config->get('url');
    my ( $scheme, $host ) = $url =~ m{^(https?)://(?:[^/@]*@)?([^/:?#]+)(?::\d+)?(?:/.*)?\z}i;
    if ( !$scheme ) {
        push @c, _check( 'config.url', 'fail', 'url ' . _scrub($url) . ' is not http(s)://host[:port]' );
    }
    elsif ( lc $scheme eq 'http' && $host !~ /^(?:localhost|127\.|\[?::1)/ ) {
        push @c, _check( 'config.url', 'warn', _scrub($url) . ' is plain http: the key travels unencrypted' );
    }
    else {
        push @c, _check( 'config.url', 'ok', _scrub($url) );
    }

    my @missing = grep { !defined $config->get($_) || $config->get($_) eq '' } qw(db login);
    push @c, @missing
        ? _check( 'config.fields', 'fail', 'missing: ' . join( ', ', @missing ) )
        : _check( 'config.fields', 'ok', 'db ' . $config->get('db') . ', login ' . $config->get('login') );

    my $tr = $config->get('transport') // 'jsonrpc';
    push @c, $tr =~ /^(?:jsonrpc|xmlrpc|json2)\z/
        ? _check( 'config.transport', 'ok', $tr )
        : _check( 'config.transport', 'fail', "unknown transport '$tr' (jsonrpc, xmlrpc, json2)" );

    push @c, _json_check();
    push @c, _runs_dir_check($config);

    my $w = $config->get('allow_writes');
    push @c,
        !defined $w ? _check( 'config.writes', 'warn', 'allow_writes is not stated: this config reads only' )
        : $w eq '1' ? _check( 'config.writes', 'ok', 'allow_writes = 1: apply is permitted on this instance' )
        : $w eq '0' ? _check( 'config.writes', 'ok', 'allow_writes = 0: reads only' )
        :             _check( 'config.writes', 'warn', "allow_writes is '$w'; only the literal 1 permits writes, so this config reads only" );

    push @c, $class->_credential_checks($config);
    push @c, $class->_tls_ca_check($config);
    return @c;
}

# which JSON encoder decodes Odoo's answers: the fast one is a Recommends, so its absence is a note, not a fault
sub _json_check () {
    my $be = Odoo::JSON->backend;
    return $be eq 'JSON::PP'
        ? _check( 'config.json', 'ok', 'JSON::PP (pure Perl); libcpanel-json-xs-perl (Cpanel::JSON::XS) decodes the same answers about a hundred times faster' )
        : _check( 'config.json', 'ok', "$be (" . ( $be->VERSION // '?' ) . ')' );
}

sub _runs_dir_check ($config) {
    my $dir = $config->get('runs_dir');
    return _check( 'config.runs_dir', 'fail', 'runs_dir is not set: run and apply need a folder for their run directories' ) if !defined $dir || $dir eq '';
    if ( -d $dir ) {
        return -w $dir
            ? _check( 'config.runs_dir', 'ok', "$dir exists and is writable" )
            : _check( 'config.runs_dir', 'fail', "$dir is not writable by this user" );
    }
    return _check( 'config.runs_dir', 'fail', "$dir exists and is not a directory" ) if -e $dir;
    my $parent = ( File::Spec->splitpath( File::Spec->canonpath($dir) ) )[1];
    $parent = File::Spec->curdir if !length $parent;
    return -d $parent && -w $parent
        ? _check( 'config.runs_dir', 'warn', "$dir does not exist yet; the first run creates it" )
        : _check( 'config.runs_dir', 'fail', "$dir does not exist and its parent is not writable" );
}

sub _credential_checks ($class, $config) {
    my $strategy = $config->get('credential') // 'file';
    return $class->_password_file_check($config) if $strategy eq 'password';
    if ( $strategy ne 'file' ) {
        return _check( 'credential.key_file', 'fail',
              $strategy eq 'cookie'  ? "credential strategy 'cookie' is reserved and not implemented here"
            : $strategy eq 'session' ? 'a session is a run-time value and cannot be a file entry'
            :                          "unknown credential strategy '$strategy'" );
    }
    my $path = $config->get('api_key_file');
    return _check( 'credential.key_file', 'fail', 'api_key_file is not set' ) if !defined $path || $path eq '';
    my @st = stat $path;
    return _check( 'credential.key_file', 'fail', "$path: $!" ) if !@st;
    return _check( 'credential.key_file', 'fail', "$path is not a regular file" ) if !-f _;
    my $mode = $st[2] & 07777;
    return _check( 'credential.key_file', 'fail', sprintf( '%s is mode %04o; group and other must have no access (chmod 600)', $path, $mode ) ) if $mode & 077;
    return _check( 'credential.key_file', 'fail', "$path is empty" ) if !$st[7];
    open my $fh, '<', $path or return _check( 'credential.key_file', 'fail', "$path cannot be read: $!" );
    my $line = <$fh>;
    close $fh;
    return _check( 'credential.key_file', 'fail', "$path has no key on its first line" ) if !defined $line || $line !~ /\S/;
    return _check( 'credential.key_file', 'ok', sprintf( '%s, mode %04o', $path, $mode ) );
}

# the password strategy's file: the key file's rules, and the file is named, never read aloud
sub _password_file_check ($class, $config) {
    my $n    = 'credential.password_file';
    my $path = $config->get('password_file');
    return _check( $n, 'fail', 'password_file is not set' ) if !defined $path || $path eq '';
    my @st = stat $path;
    return _check( $n, 'fail', "$path: $!" ) if !@st;
    return _check( $n, 'fail', "$path is not a regular file" ) if !-f _;
    my $mode = $st[2] & 07777;
    return _check( $n, 'fail', sprintf( '%s is mode %04o; group and other must have no access (chmod 600)', $path, $mode ) ) if $mode & 077;
    return _check( $n, 'fail', "$path is empty" ) if !$st[7];
    open my $fh, '<', $path or return _check( $n, 'fail', "$path cannot be read: $!" );
    my $line = <$fh>;
    close $fh;
    return _check( $n, 'fail', "$path has no password on its first line" ) if !defined $line || $line !~ /\S/;
    return _check( $n, 'ok', sprintf( 'credential password, login %s, %s, mode %04o', $config->get('login') // '?', $path, $mode ) );
}

sub _tls_ca_check ($class, $config) {
    my $ca = $config->get('ssl_ca_file');
    my $v  = $config->get('ssl_verify');
    if ( defined $v && $v eq '0' ) {
        return _check( 'tls.ca', 'warn', 'ssl_verify = 0: the server certificate is not verified' );
    }
    return _check( 'tls.ca', 'ok', 'no ssl_ca_file: the system trust store is used' ) if !defined $ca || $ca eq '';
    return _check( 'tls.ca', 'fail', "ssl_ca_file $ca: $!" ) if !-e $ca;
    return _check( 'tls.ca', 'fail', "ssl_ca_file $ca is not a regular file" ) if !-f _;
    my $text = do { local $/; open my $fh, '<', $ca or return _check( 'tls.ca', 'fail', "ssl_ca_file $ca cannot be read: $!" ); <$fh> };
    return _check( 'tls.ca', 'fail', "ssl_ca_file $ca holds no PEM certificate (no BEGIN CERTIFICATE line)" )
        if ( $text // '' ) !~ /-----BEGIN (?:TRUSTED |X509 )?CERTIFICATE-----/;
    my $info = _parse_pem_cert($ca);
    return _check( 'tls.ca', 'fail', "ssl_ca_file $ca: the first certificate does not parse" ) if $info && $info->{error};
    return _check( 'tls.ca', 'ok', $info ? "$ca, $info->{subject}" : $ca );
}

# subject and expiry of the first certificate in a PEM file, through
# Net::SSLeay (a dependency of the TLS stack already); undef when it
# cannot be loaded, { error } when the certificate does not parse
sub _parse_pem_cert ($file) {
    return undef if !eval { require Net::SSLeay; 1 };
    my $bio = Net::SSLeay::BIO_new_file( $file, 'r' ) or return { error => 1 };
    my $x   = Net::SSLeay::PEM_read_bio_X509($bio);
    Net::SSLeay::BIO_free($bio);
    return { error => 1 } if !$x;
    my $info = { subject => Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_subject_name($x) ) };
    Net::SSLeay::X509_free($x);
    return $info;
}

# --- TLS chain, web routes, clock -------------------------------------------

sub _tls_probe ($self, $host, $port, $ca) {
    return $self->{tls}->( $host, $port, $ca ) if $self->{tls};
    return _default_tls_probe( $host, $port, $ca );
}

sub _default_tls_probe ($host, $port, $ca) {
    no warnings q(once);
    require IO::Socket::SSL;
    my %o = ( PeerHost => $host, PeerPort => $port, SSL_hostname => $host, Timeout => 15, ( $ca ? ( SSL_ca_file => $ca ) : () ) );
    my $s = IO::Socket::SSL->new( %o, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER() );
    my %r = ( verified => $s ? 1 : 0 );
    if ( !$s ) {
        $r{error} = $IO::Socket::SSL::SSL_ERROR || "$!";
        $r{error} =~ s/^SSL connect attempt failed( error:[0-9A-F]+:[^:]*:[^:]*:[^:]*:)?\s*//;
        # the certificate is still worth naming when it does not verify
        $s = IO::Socket::SSL->new( %o, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE() ) or return \%r;
    }
    if ( my $x = $s->peer_certificate ) {
        $r{subject} = Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_subject_name($x) );
        my $iso = Net::SSLeay::P_ASN1_TIME_get_isotime( Net::SSLeay::X509_get_notAfter($x) );
        if ( $iso && $iso =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z/ ) {
            $r{not_after} = Time::Local::timegm( $6, $5, $4, $3, $2 - 1, $1 );
        }
    }
    $s->close;
    return \%r;
}

# the server certificate against ssl_ca_file (or the system store): does
# it verify, whose is it, when does it run out
sub _tls_chain ($self, $config) {
    my $url = $config->get('url') // '';
    my ( $scheme, $host, $port ) = $url =~ m{^(https?)://(?:[^/@]*@)?([^/:?#]+)(?::(\d+))?}i;
    return _check( 'tls.chain', 'skipped', 'the url is not https' ) if !$scheme || lc $scheme ne 'https';
    my ($ca_state) = map { $_->{status} } grep { $_->{name} eq 'tls.ca' } $self->_tls_ca_check($config);
    return _check( 'tls.chain', 'skipped', 'ssl_ca_file failed its check' ) if $ca_state eq 'fail';
    my $r = eval { $self->_tls_probe( $host, $port // 443, $config->get('ssl_ca_file') ) };
    return _check( 'tls.chain', 'fail', 'no TLS connection to ' . "$host:" . ( $port // 443 ) . ': ' . _strip( _msg($@) ) ) if !$r;
    my $verify_off = ( $config->get('ssl_verify') // '' ) eq '0';
    if ( !$r->{verified} ) {
        my $why = _strip( $r->{error} // 'unknown' );
        return $verify_off
            ? _check( 'tls.chain', 'warn', "the certificate does not verify ($why); ssl_verify = 0 lets requests through" )
            : _check( 'tls.chain', 'fail', "the server certificate does not verify against " . ( $config->get('ssl_ca_file') // 'the system store' ) . ": $why" );
    }
    my $d = 'verifies' . ( $r->{subject} ? "; subject $r->{subject}" : '' );
    return _check( 'tls.chain', 'ok', $d ) if !$r->{not_after};
    my $days = int( ( $r->{not_after} - $self->ctx->now ) / 86400 );
    my $when = Odoo::Ops::iso_time( $r->{not_after} );
    return _check( 'tls.chain', 'fail', "$d; expired $when" ) if $days < 0;
    return _check( 'tls.chain', $days < 14 ? 'warn' : 'ok', "$d; expires $when ($days days)" );
}

sub _http ($self, $config) {
    return $self->{http} //= Odoo::Transport::http_client(
        timeout     => 15,
        ssl_ca_file => $config->get('ssl_ca_file'),
        ssl_verify  => $config->get('ssl_verify'),
    );
}

# TLS chain, then /web/login and the clock, from one pair of requests
sub _web_checks ($self, $config) {
    my @c;
    my $url = $config->get('url') =~ s{/+\z}{}r;
    my ( $scheme, $host, $port ) = $url =~ m{^(https?)://(?:[^/@]*@)?([^/:?#]+)(?::(\d+))?}i;
    return () if !$scheme;
    $port //= lc $scheme eq 'https' ? 443 : 80;

    my $res = eval { $self->_http($config)->get("$url/web/login") };
    if ( !$res || ( $res->{status} // 0 ) == 599 ) {
        my $m = $res ? ( $res->{content} // 'no answer' ) : _msg($@);
        push @c, _check( 'reach.login_page', 'fail', "/web/login did not answer: " . _strip($m) );
        push @c, _check( 'reach.clock', 'skipped', 'no answer to read a Date header from' );
        return @c;
    }
    my $s = $res->{status};
    push @c, $s == 200 ? _check( 'reach.login_page', 'ok', '/web/login answers 200' )
        : _check( 'reach.login_page', $s >= 500 ? 'fail' : 'warn', "/web/login answers HTTP $s" . ( $res->{headers}{location} ? ' to ' . _scrub( $res->{headers}{location} ) : '' ) . ': the proxy may not route this host to Odoo' );

    my $date = $res->{headers}{date};
    $date = $date->[0] if ref $date eq 'ARRAY';
    my $at = defined $date ? _http_date($date) : undef;
    if ( !defined $at ) {
        push @c, _check( 'reach.clock', 'warn', 'the server sent no readable Date header' );
    }
    else {
        my $skew = $at - $self->ctx->now;
        my $abs  = abs $skew;
        push @c, _check( 'reach.clock', $abs > 60 ? 'warn' : 'ok',
            sprintf( 'server clock %s this host by %d s%s', $skew < 0 ? 'behind' : 'ahead of', $abs, $abs > 60 ? ' (over 60 s)' : '' ) );
    }
    return @c;
}

sub _http_date ($d) {
    my %mon = ( Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5, Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11 );
    my ( $day, $m, $y, $H, $M, $S ) = $d =~ /(\d{1,2})\s+([A-Z][a-z]{2})\s+(\d{4})\s+(\d\d):(\d\d):(\d\d)/ or return undef;
    return undef if !defined $mon{$m};
    return Time::Local::timegm( $S, $M, $H, $day, $mon{$m}, $y );
}

# --- database ---------------------------------------------------------------

sub _db_list ($self, $config) {
    my $url = $config->get('url') =~ s{/+\z}{}r;
    my $res = eval {
        $self->_http($config)->post(
            "$url/jsonrpc",
            { content => '{"jsonrpc":"2.0","method":"call","params":{"service":"db","method":"list","args":[]},"id":1}',
              headers => { 'content-type' => 'application/json' } },
        );
    };
    return _check( 'db.list', 'ok', 'db/list was not asked: ' . _strip( _msg($@) ) ) if !$res;
    if ( !$res->{success} ) {
        return _check( 'db.list', 'ok', "db/list is not served here (HTTP $res->{status})" );
    }
    my $d = eval { Odoo::JSON->new( utf8 => 0 )->decode( $res->{content} ) };
    return _check( 'db.list', 'ok', 'db/list answered something unreadable; treated as closed' ) if ref $d ne 'HASH';
    if ( my $e = $d->{error} ) {
        my $name = ref $e->{data} eq 'HASH' ? ( $e->{data}{name} // '' ) : '';
        return $name =~ /AccessDenied/
            ? _check( 'db.list', 'ok', 'db/list is refused: LIST_DB is closed (the good case)' )
            : _check( 'db.list', 'ok', 'db/list answered an error (' . ( $name || 'unnamed' ) . '); treated as closed' );
    }
    my $n = ref $d->{result} eq 'ARRAY' ? scalar @{ $d->{result} } : 0;
    return _check( 'db.list', 'warn', "db/list is open: anyone can list the $n database name(s) on this server (list_db = False closes it)" );
}

sub _db_served ($self, $config) {
    my $db = $config->get('db');
    my $n  = eval { $self->client->execute_kw( q(res.company), q(search_count), [ [] ] ) };
    return defined $n
        ? _check( 'db.served', 'ok', "database $db is the one served; $n company record(s) readable" )
        : _check( 'db.served', 'fail', "database $db: res.company is not readable: " . _strip( _msg($@) ) );
}

# --- authentication ---------------------------------------------------------

sub _auth_checks ($self, $config) {
    my @c;
    my $client = $self->client;
    my ( $uid, $err );
    if ( ( $config->get('credential') // 'file' ) eq 'password' ) {
        # the web login takes the password: the session is the authentication
        my $id = eval { $self->ctx->open_session };
        $err = $@;
        if ($id) { $uid = $id->{uid}; $self->{session_login} = $id->{login} // $config->get('login') }
        else     { $self->{session_error} = $err ? _strip( _msg($err) ) : 'no session was opened' }
    }
    else {
        my %cred = eval { Odoo::Ops::Credential->resolve($config) };
        $uid = eval { $client->verify_credentials( $cred{login}, $cred{api_key} ) };
        $err = $@;
    }
    if ( !$uid ) {
        my $m = $err ? _strip( _msg($err) ) : sprintf( "login '%s' was refused on database '%s' (wrong key, login or database)", $config->get('login'), $config->get('db') );
        $m = sprintf( "login '%s' was refused on database '%s' (wrong password, login or database): %s", $config->get('login'), $config->get('db'), $m )
            if defined $self->{session_error};
        return ( _check( 'auth.login', 'fail', $m ), _check( 'auth.user', 'skipped', 'the login failed' ), _check( 'auth.groups', 'skipped', 'the login failed' ) );
    }
    push @c, _check( 'auth.login', 'ok', "'" . $config->get('login') . "' authenticates as uid $uid" );

    my $u = eval { $client->model('res.users')->read_one( $client->uid, [ 'name', 'email' ] ) };
    if ( !$u ) {
        push @c, _check( 'auth.user', 'warn', 'the user record cannot be read: ' . _strip( _msg($@) ) );
    }
    elsif ( !defined $u->{email} || !length( $u->{email} ) ) {
        push @c, _check( 'auth.user', 'warn', "$u->{name} has no email address; the behaviour files (crm.lead, stock.picking) say what that changes for mail-sending actions on this series" );
    }
    else {
        push @c, _check( 'auth.user', 'ok', "$u->{name}, email $u->{email}" );
    }

    my %g;
    for my $grp (qw(base.group_system base.group_user base.group_portal)) {
        $g{$grp} = $self->_has_group( $client, $grp );
    }
    my $show = join ', ', map { ( $_ =~ s/^base\.group_//r ) . ' ' . ( !defined $g{$_} ? 'unknown' : $g{$_} ? 'yes' : 'no' ) } qw(base.group_system base.group_user base.group_portal);
    my $status = ( defined $g{'base.group_portal'} && $g{'base.group_portal'} ) || ( defined $g{'base.group_user'} && !$g{'base.group_user'} ) ? 'warn' : 'ok';
    push @c, _check( 'auth.groups', $status, $status eq 'warn' ? "$show: an operations login should be an internal user, not a portal user" : $show );
    return @c;
}

# core.report's render needs a web session; only a password credential opens one
sub _session_check ($self, $config) {
    my $n = 'transport.session';
    if ( ( $config->get('credential') // 'file' ) ne 'password' ) {
        return _check( $n, 'info', 'the credential is not a password: core.report render needs a web session (credential = password, login and password_file); source=attachment needs none' );
    }
    return _check( $n, 'ok', "login $self->{session_login}: a web session is open, so core.report can render" ) if defined $self->{session_login};
    return _check( $n, 'fail', 'the web session did not open: ' . $self->{session_error} ) if defined $self->{session_error};
    return _check( $n, 'skipped', 'the server is not reachable or the credential check failed' );
}

# what Odoo says of its pdf renderer; get_wkhtmltopdf_state is a public model method
sub _wkhtmltopdf_check ($self, $series) {
    my $n = 'server.wkhtmltopdf';
    my $state = eval { $self->client->execute_kw( 'ir.actions.report', 'get_wkhtmltopdf_state', [] ) };
    if ( !defined $state || ref $state ) {
        my $why = $@ ? _strip( _msg($@) ) : 'no state in the answer';
        return _check( $n, 'info', "series $series does not give the state of wkhtmltopdf ($why): whether core.report pdf can render is unknown" );
    }
    return _check( $n, 'ok', "wkhtmltopdf state $state" ) if $state =~ /^(?:ok|upgrade)\z/;
    return _check( $n, 'warn', "wkhtmltopdf state $state: core.report pdf will fail until it is ok" . ( {
        install => ' (no wkhtmltopdf binary is installed on the server)',
        workers => ' (the server runs too few workers for the pdf render)',
        broken  => ' (a binary is installed and does not answer)',
    }->{$state} // '' ) );
}

# has_group is a model method on 16 and a record method on later series
sub _has_group ($self, $client, $group) {
    for my $args ( [ [$group] ], [ [ [ $client->uid ], $group ] ] ) {
        my $r = eval { $client->execute_kw( 'res.users', 'has_group', $args->[0] ) };
        return $r ? 1 : 0 if defined $r && !$@;
    }
    return undef;
}

# --- profiles, behaviours, probes -------------------------------------------

# Whether a pack answers on the server's series is asked of the pack: a pack whose
# operations refuse a series by name (refused/series) does it in its own Common::ready,
# and that same function is asked here, so the two cannot disagree. A pack with no
# ready, or one that refuses for another reason (the profile does not match), is
# taken to cover the series: the profile and behaviour lines report the rest.
sub _covers ($self, $pack, $profile) {
    my $class = 'Odoo::Ops::' . ucfirst($pack) . '::Common';
    ( my $file = "$class.pm" ) =~ s{::}{/}g;
    return 1 if !eval { require $file; 1 };
    my $ready = $class->can('ready') or return 1;
    my $ask = bless { client => $self->client, profile => $profile }, 'Odoo::Ops::Core::Doctor::Ask';
    return eval { $ready->($ask); 1 } || !( blessed($@) && $@->isa('Odoo::Error') && ( $@->code // '' ) eq 'series' ) ? 1 : 0;
}

# what Common::ready reads of an operation: the client, the pack's profile and a name
package Odoo::Ops::Core::Doctor::Ask {
    sub client  { $_[0]{client} }
    sub profile { $_[0]{profile} }
    sub op_name { 'core.doctor' }
}

sub _pack_checks ($self, $config) {
    my @c;
    my %roots = map { $_ => 1 } Odoo::Ops::Profile->default_dirs( grep { defined } $config->get('profile_dir') );
    my %packs;
    for my $root ( sort keys %roots ) {
        opendir my $dh, $root or next;
        $packs{$_} = 1 for grep { !/^\./ && -d File::Spec->catdir( $root, $_ ) } readdir $dh;
        closedir $dh;
    }
    return _check( 'profile', 'warn', 'no profile packs found under ' . join( ', ', sort keys %roots ) ) if !%packs;

    my ( %probes, %seen, @unfiled );
    for my $pack ( sort keys %packs ) {
        my $p = eval { $self->ctx->profile($pack) };
        if ( !$p ) {
            push @c, _check( "profile.$pack", 'fail', _strip( _msg($@) ) );
            next;
        }
        # a pack whose own module is not installed is not applicable here, said before any series question
        if ( my $gone = Odoo::Ops::Modules->missing( $self->ctx, $p->module ) ) {
            push @c, _check( "profile.$pack", 'info', "not applicable here: $gone" );
            next;
        }
        # A pack its operations refuse by name on this series (refused/series) is not
        # broken here, so it is a fact and its behaviour lines are left out.
        if ( !$self->_covers( $pack, $p ) ) {
            push @c, _check( "profile.$pack", 'info', "not covered on " . $self->client->server_series
                    . ": the $pack pack has a profile for " . $p->series . " only; its operations are refused by name" );
            next;
        }
        my $v = eval { $p->validate( $self->client ) };
        if ( !$v ) {
            push @c, _check( "profile.$pack", 'fail', 'validation did not run: ' . _strip( _msg($@) ) );
            next;
        }
        my $na   = $v->{not_applicable} // [];
        my $base = "series " . $p->series . ", $v->{models} model(s), $v->{fields} field(s)" . ( @$na ? '; ' . scalar(@$na) . ' not applicable here' : '' );
        for my $line (@$na) {
            my ( $what ) = $line =~ /\A([^:]+):/;
            push @c, _check( "profile.$pack.$what", 'info', $line );
        }
        if ( !$v->{ok} ) {
            push @c, _check( "profile.$pack", 'fail', "$base; missing on the server: " . join( '; ', @{ $v->{missing} } ) );
        }
        elsif ( @{ $p->warnings } ) {
            push @c, _check( "profile.$pack", 'warn', "$base; " . join( '; ', @{ $p->warnings } ) );
        }
        else {
            push @c, _check( "profile.$pack", 'ok', "$base; every mapped field that applies here exists" );
        }
        for my $lm ( $p->models ) {
            my $model = $p->model_name($lm);
            next if $seen{$model}++;
            my $b = eval { $self->ctx->behaviour($model) };
            if ( !$b ) {
                push @c, _check( "behaviour.$model", 'fail', _strip( _msg($@) ) );
                next;
            }
            if ( !$b->known ) {
                push @unfiled, $model;
                next;
            }
            my $d = 'series ' . $b->series . ', ' . scalar( @{ $b->effects } ) . ' effect(s), ' . scalar( @{ $b->invariants } ) . ' invariant(s)';
            push @c, @{ $b->warnings }
                ? _check( "behaviour.$model", 'warn', "$d; " . join( '; ', @{ $b->warnings } ) )
                : _check( "behaviour.$model", 'ok', $d );
            $probes{$_} = 1 for @{ $b->probes };
        }
    }

    push @c, _check( 'behaviour.unfiled', 'ok', 'no behaviour file, so nothing is claimed, for: ' . join( ', ', sort @unfiled ) ) if @unfiled;

    if (%probes) {
        require Odoo::Ops::Core::Check;
        my $chk = Odoo::Ops::Core::Check->new( ctx => $self->ctx, params => {} );
        my $out = $chk->_probe( [ sort grep { !/\Amodule:/ } keys %probes ], undef );
        for my $name ( sort keys %$out ) {
            my $val = $out->{$name};
            if ( $name eq 'acting_user_email' ) {
                push @c, _check( "probe.$name", $val ? 'ok' : 'warn', $val ? 'the acting user has an email address' : 'the acting user has no email address (a behaviour file depends on it)' );
            }
            else {
                push @c, _check( "probe.$name", 'warn', $val );
            }
        }
    }
    return @c;
}

# One read probe per model doctor reads beyond the login. The line carries what Odoo
# answered: a refusal is a fact about this user (info), any other failure a warning.
my @PROBED = qw(ir.model.data ir.cron ir.mail_server ir.config_parameter);

sub _rights_checks ($self) {
    my @c;
    for my $model (@PROBED) {
        my $n   = eval { $self->client->execute_kw( $model, 'search_count', [ [] ] ) };
        my $err = $@;
        push @c, defined $n  ? _check( "probe.rights:$model", 'ok',   "$model is readable by this user" )
            : _denied($err) ? _check( "probe.rights:$model", 'info', "$model is not readable by this user: " . _strip( _msg($err) ) )
            :                 _check( "probe.rights:$model", 'warn', "$model could not be probed: " . _strip( _msg($err) ) );
    }
    return @c;
}

# --- modules, write readiness, runs -----------------------------------------

# A refused read is a fact about this user, so it is an info line carrying Odoo's refusal;
# a read that failed for another reason stays a warning.
sub _denied ($err) { return blessed($err) && $err->isa('Odoo::Error') && $err->is_access_denied }

# One line per module the behaviour files and the profiles name, installed or not: the
# modules come from those files and not from a list here. A module that is not there is a
# fact (info), and the line says what names it. A user who may not read ir.module.module
# gets one info line carrying Odoo's refusal, and no claim about any module.
sub _module_checks ($self) {
    my $set = Odoo::Ops::Modules->installed( $self->ctx );
    if ( !$set ) {
        my $err = Odoo::Ops::Modules->read_failure( $self->ctx );
        return _check( 'modules', 'info', 'ir.module.module is not readable by this user: the installed modules are not listed: ' . _strip( _msg($err) ) ) if $err && _denied($err);
        return _check( 'modules', 'warn', 'ir.module.module could not be read: ' . _strip( _msg($err) ) ) if $err;
        return _check( 'modules', 'info', 'ir.module.module lists no installed module: the installed modules are not listed' );
    }
    my $named = Odoo::Ops::Modules->named( $self->ctx );
    return map {
        my $by = join ', ', @{ $named->{$_} };
        $set->{$_}
            ? _check( "module.$_", 'ok', "module $_: installed" )
            : _check( "module.$_", 'info', "module $_: not installed; not applicable here: $by" )
    } sort keys %$named;
}

sub _write_checks ($self, $config) {
    my @c;
    my $rows = eval {
        $self->client->model('ir.config_parameter')->search_read( [ [ 'key', 'in', [ 'web.base.url', 'mail.catchall.domain' ] ] ], [ 'key', 'value' ] );
    };
    if ( !$rows ) {
        push @c, _denied($@)
            ? _check( 'write.base_url', 'info', 'ir.config_parameter is not readable by this user: web.base.url is not checked: ' . _strip( _msg($@) ) )
            : _check( 'write.base_url', 'warn', 'ir.config_parameter could not be read: ' . _strip( _msg($@) ) );
        push @c, _check( 'write.catchall', 'skipped', 'ir.config_parameter is not readable' );
    }
    else {
        my %p = map { $_->{key} => $_->{value} } @$rows;
        my $base = $p{'web.base.url'};
        if ( !defined $base || $base eq '' ) {
            push @c, _check( 'write.base_url', 'warn', 'web.base.url is not set: mails will carry no usable links' );
        }
        else {
            my ($bh) = lc($base) =~ m{^https?://(?:[^/@]*@)?([^/:?#]+)};
            my ($ch) = lc( $config->get('url') ) =~ m{^https?://(?:[^/@]*@)?([^/:?#]+)};
            push @c, ( $bh // '' ) eq ( $ch // '' )
                ? _check( 'write.base_url', 'ok', 'web.base.url ' . _scrub($base) . ' is this config\'s host' )
                : _check( 'write.base_url', 'warn', 'web.base.url is ' . _scrub($base) . ' but the config reaches ' . ( $ch // '?' ) . ': mails will carry the wrong links' );
        }
        my $cd = $p{'mail.catchall.domain'};
        push @c, defined $cd && length $cd
            ? _check( 'write.catchall', 'ok', "mail.catchall.domain $cd" )
            : _check( 'write.catchall', 'warn', 'mail.catchall.domain is not set: replies cannot be routed back into Odoo' );
    }
    my $n = eval { $self->client->execute_kw( q(ir.mail_server), q(search_count), [ [] ] ) };
    my $ms_err = $@;
    push @c, !defined $n && _denied($ms_err) ? _check( 'write.mail_server', 'info', 'ir.mail_server is not readable by this user: outgoing servers are not counted: ' . _strip( _msg($ms_err) ) )
        : !defined $n ? _check( 'write.mail_server', 'warn', 'ir.mail_server could not be read: ' . _strip( _msg($ms_err) ) )
        : $n ? _check( 'write.mail_server', 'ok', "$n outgoing mail server(s)" )
        :      _check( 'write.mail_server', 'warn', 'no outgoing mail server: a message the apply queues is not sent' );
    my $u = eval { $self->client->model('res.users')->read_one( $self->client->uid, ['notification_type'] ) };
    push @c, $u && defined $u->{notification_type}
        ? _check( 'write.notification_type', 'ok', "the acting user's notification_type is $u->{notification_type}" )
        : _check( 'write.notification_type', 'warn', 'the acting user\'s notification_type cannot be read' );
    return @c;
}

sub _runs_check ($self, $config) {
    my $root = $config->get('runs_dir');
    return _check( 'runs', 'skipped', 'runs_dir is not set' ) if !defined $root || $root eq '';
    return _check( 'runs', 'ok', 'no runs yet (runs_dir does not exist)' ) if !-d $root;
    opendir my $dh, $root or return _check( 'runs', 'warn', "$root cannot be listed: $!" );
    my ($newest) = sort { $b cmp $a } grep { /^\d{8}/ && -d File::Spec->catdir( $root, $_ ) } readdir $dh;
    closedir $dh;
    return _check( 'runs', 'ok', 'no runs yet' ) if !defined $newest;
    my $dir = File::Spec->catdir( $root, $newest );
    my $has = sub ($f) { -f File::Spec->catfile( $dir, $f ) };
    my ( $state, $warn );
    if ( $has->('result.json') ) {
        my $r = _json_file( File::Spec->catfile( $dir, 'result.json' ) );
        my $c = ref $r eq 'HASH' && ref $r->{counts} eq 'HASH' ? $r->{counts} : {};
        # the run's state in the registry's word (oom-ops runs): its record when it has one, else what the counts say
        my $rec = $has->('run.json') ? _json_file( File::Spec->catfile( $dir, 'run.json' ) ) : undef;
        my $word = ref $rec eq 'HASH' && length( $rec->{state} // '' ) ? $rec->{state} : Odoo::Ops::Runs::_apply_state($c);
        $warn  = $word =~ /\A(?:failed|partly)/ ? 1 : 0;
        $state = ( $c->{failed} || $c->{not_attempted} )
            ? "$word (done " . ( $c->{done} // 0 ) . ', failed ' . ( $c->{failed} // 0 ) . ', not attempted ' . ( $c->{not_attempted} // 0 ) . ')'
            : $word;
    }
    elsif ( $has->('plan.json') )    { $state = 'planned, not applied' }
    elsif ( $has->('journal.jsonl') ) { $state = 'journal without a result (an apply that stopped?)' }
    elsif ( $has->('report.json') )  { $state = 'report' }
    else                             { $state = 'empty' }
    $warn //= $state =~ /stopped/ ? 1 : 0;

    my $plan = $has->('plan.json') ? _json_file( File::Spec->catfile( $dir, 'plan.json' ) ) : undef;
    my $inst = ref $plan eq 'HASH' ? $plan->{instance} : undef;
    if ( ref $inst eq 'HASH' ) {
        my $mine = $config->instance;
        my @diff = grep { ( $inst->{$_} // '' ) ne ( $mine->{$_} // '' ) } qw(url db);
        return _check( 'runs', 'warn', "newest run $newest ($state) was made against " . _scrub( $inst->{url} // '?' ) . ' db ' . ( $inst->{db} // '?' ) . ', not this config\'s instance' ) if @diff;
        return _check( 'runs', $warn ? 'warn' : 'ok', "newest run $newest: $state; same instance as this config" );
    }
    return _check( 'runs', $warn ? 'warn' : 'ok', "newest run $newest: $state; no plan in it to compare the instance" );
}

sub _json_file ($path) {
    open my $fh, '<', $path or return undef;
    my $t = do { local $/; <$fh> };
    return eval { Odoo::JSON->new( utf8 => 0 )->decode($t) };
}

# --- report assembly and output ---------------------------------------------

sub _check ($name, $status, $detail) { return { name => $name, status => $status, detail => $detail } }

sub _finish ( $checks, $series, $uid, $config = undef ) {
    my %n = ( ok => 0, warn => 0, fail => 0, skipped => 0, info => 0 );
    $n{ $_->{status} }++ for @$checks;
    my $exit = $n{fail} ? 2 : $n{warn} ? 1 : 0;
    my $text = "$n{ok} ok, $n{warn} warn, $n{fail} fail, $n{skipped} skipped" . ( $n{info} ? ", $n{info} info" : '' );
    return {
        checks  => $checks,
        summary => { %n, exit => $exit, text => $text },
        series  => $series,
        uid     => $uid,
    };
}

=head2 format_text($report)

The human form: one line per check, C<ok>, C<warn>, C<fail> or
C<skipped> first, then the summary line.

=cut

sub format_text ($class, $report) {
    my $out = '';
    $out .= sprintf( "%-7s %-26s %s\n", $_->{status}, $_->{name}, $_->{detail} ) for @{ $report->{checks} };
    my $s = $report->{summary};
    $out .= "summary: $s->{text}"
        . ( defined $report->{series} ? ", series $report->{series}" : '' )
        . ( defined $report->{uid} ? ", uid $report->{uid}" : '' )
        . ", exit $s->{exit}\n";
    return $out;
}

sub _msg ($err) { return blessed($err) && $err->can('message') ? $err->message : "$err" }

# a message on one line, with any url's user info dropped
sub _strip ($m) {
    $m = _scrub( $m // '' );
    $m =~ s/\s+/ /g;
    $m =~ s/\s+\z//;
    return $m;
}

sub _scrub ($s) { return ( $s // '' ) =~ s{(\w+://)[^/@\s]*@}{$1}gr }

1;

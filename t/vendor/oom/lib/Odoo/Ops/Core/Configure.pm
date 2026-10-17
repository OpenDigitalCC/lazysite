package Odoo::Ops::Core::Configure;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use YAML::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Credential;
use Odoo::Commands qw(x2m_set);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Configure - bring an instance to a desired state

=head1 DESCRIPTION

C<core.configure>: C<file> is YAML (or JSON) describing what the
instance should look like; the plan is the difference from what it
is, applied once like any plan, so a new instance is reproducible
from the cluster inventory plus this file, and a drifted one is put
back. Everything here goes over the ordinary RPC surface as the
configured (administrator) user.

    modules:
      install: [crm, sale_management, hr_expense]
    params:
      web.base.url: https://erp.example
      mail.catchall.domain: example.com
    settings:                       # res.config.settings, as the Settings page
      group_multi_currency: true
    company:                        # the configured user's company
      name: ACME Ltd
      email: hello@acme.example
      country: GB                   # ISO code
      currency: GBP                 # code
      chart: generic                # load the generic chart if none (series-aware)
    users:
      - login: jane@acme.example
        name: Jane Doe
        groups: [base.group_system]   # xml ids; implied groups follow
      - login: old@acme.example
        active: false
    languages: [en_GB, fr_FR]
    ldap:                           # auth_ldap's server list (0.08)
      - name: corporate             # a label for the plan; Odoo stores none
        server: ldap.acme.example
        port: 389                   # default 389
        base: "OU=Users,DC=acme,DC=example"
        filter: "(sAMAccountName=%s)"   # default (objectClass=*)
        bind_user: "CN=odoo,OU=Service,DC=acme,DC=example"
        bind_password_file: /srv/secrets/odoo-ldap.pw   # owner-only; never a value
        create_user: true           # default true
        user_template: default.user # a login (archived included)
        company: ACME Ltd           # by name; default the first company

Sections are optional; each entry is one input row with one bucket:
C<unchanged>, or the change it needs. Modules install through
C<button_immediate_install> (the server reloads its registry; a
consumer's serving slot still needs its restart). Settings are applied
as one C<res.config.settings> record executed, after comparing with
C<default_get>. Parameters and company fields are plain writes with
before-images, so C<revert> can undo them; module installs, settings
and language installs are held as irreversible. Users are created
without a password (set one with the instance tool) and never deleted
here, only deactivated. Unknown modules, groups, countries, currencies
or languages refuse the plan by name.

Three additions in 0.08:

=over 4

=item modules

When a named module is not found, C<ir.module.module.update_list> is
called once and the search repeated, so an addon mounted since the last
update is seen; one still absent is C<unknown-module>. That call runs at
planning, so it is in the read scope: it refreshes the list only (it
installs and removes nothing) and is idempotent, but it is a call a
read-only configuration also makes.

=item params

A value of C<~> (null) means the parameter must not exist: a present one
is planned as C<param-unset> (an C<unlink> carrying the key and value as
its before-image; a deleted record is held as irreversible by C<revert>),
an absent one as C<unchanged>.

=item ldap

A list of servers for C<res.company.ldap> (Odoo's model; the module is
C<auth_ldap>). Odoo keeps no name on a server, so a server is recognised
by its company and C<server>; C<name> is only the label in the plan. The
bind password is read at apply from C<bind_password_file> (mode 0600) and
is neither in the plan nor in the journal; it is compared with the stored
one, so a second run plans C<unchanged>. Buckets: C<ldap-create>,
C<ldap-write>, C<unchanged>, and the holds C<module-missing> (C<auth_ldap>
neither installed nor in this file's C<modules.install>),
C<unknown-template> (no user with that login, archived ones included),
C<unknown-company> and C<ambiguous> (two records for that company and
host). A template user created by the same file is not yet there when
the file is planned: apply, then plan again. An unreachable host is not
an error; Odoo stores the record and checks the host at login.

=back

=cut

sub op_name ($class) { 'core.configure' }
sub summary ($class) { 'Bring modules, parameters, settings, company, users and languages to a desired state' }
sub pack    ($class) { undef }    # physical models only: no profile pack
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'settings', meaning => 'res.config.settings values are written, as the Settings page would' },
        { name => 'install', meaning => 'a module is installed' },
        { name => 'chart', meaning => 'the chart of accounts is loaded for the company' },
        { name => 'company', meaning => 'the company\'s name, email, country or other fields are written' },
        { name => 'company-currency', meaning => 'the company\'s currency is changed' },
        { name => 'param-create', meaning => 'a system parameter is made' },
        { name => 'param-write', meaning => 'a system parameter\'s value is changed' },
        { name => 'param-unset', meaning => 'a parameter given as ~ is removed' },
        { name => 'user-create', meaning => 'a user is made, without a password' },
        { name => 'user-write', meaning => 'a user\'s groups or active flag are written' },
        { name => 'language', meaning => 'a language is installed' },
        { name => 'ldap-create', meaning => 'an LDAP server entry is made' },
        { name => 'ldap-write', meaning => 'an LDAP server entry is changed' },
        { name => 'unchanged', meaning => 'the setting, parameter, user or entry already matches' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-module', meaning => 'the module is not in the instance\'s list, even after refreshing it' },
        { name => 'module-missing', meaning => 'auth_ldap is neither installed nor in this file\'s modules.install' },
        { name => 'unknown-template', meaning => 'the LDAP user template login does not exist (archived users included)' },
        { name => 'unknown-company', meaning => 'no single company has that name' },
        { name => 'ambiguous', meaning => 'two LDAP entries share the company and host' },
        { name => 'currency-locked', meaning => 'the company has accounting entries, so Odoo will not change its currency' },
    ];
}

sub params ($class) {
    {   file => { type => 'path', required => 1, help => 'desired state, YAML or JSON' } };
}
sub read_scope ($class) {
    {   'ir.module.module'    => [qw(search_read read update_list)],    # update_list: see "modules" above
        'res.company.ldap'    => [qw(search search_read read)],
        'ir.config_parameter' => [qw(search_read read)],
        'res.company'         => [qw(search_read read)],
        'res.users'           => [qw(search_read read)],
        'res.groups'          => ['search_read'],
        'ir.model.data'       => ['search_read'],
        'res.country'         => ['search_read'],
        'res.currency'        => [qw(search_read write)],
        'res.lang'            => [qw(search_read read)],
        'res.config.settings' => [qw(default_get fields_get)],
        'account.chart.template' => ['search_read'],
        'account.move.line'      => ['search_count'],
    };
}
sub write_scope ($class) {
    {   'ir.module.module'       => ['button_immediate_install'],
        'ir.config_parameter'    => [qw(create write unlink)],
        'res.company.ldap'       => [qw(create write)],
        'res.company'            => ['write'],
        'res.users'              => [qw(create write)],
        'res.config.settings'    => [qw(create execute)],
        'base.language.install'  => [qw(create lang_install)],
        'account.chart.template' => ['try_loading'],
    };
}

sub plan ($self) {
    my $want = $self->_load( $self->param('file') );
    my $plan = $self->new_plan;
    my $n    = 0;
    $n += $self->_plan_modules( $plan, $want->{modules} )  if $want->{modules};
    $n += $self->_plan_params( $plan, $want->{params} )    if $want->{params};
    $n += $self->_plan_settings( $plan, $want->{settings} ) if $want->{settings};
    $n += $self->_plan_company( $plan, $want->{company} )  if $want->{company};
    $n += $self->_plan_users( $plan, $want->{users} )      if $want->{users};
    $n += $self->_plan_languages( $plan, $want->{languages} ) if $want->{languages};
    if ( $want->{ldap} ) {
        my $installing = grep { $_ eq 'auth_ldap' } @{ $want->{modules}{install} // [] };
        $n += $self->_plan_ldap( $plan, $want->{ldap}, $installing );
    }
    $plan->set_input_count($n);
    return $plan;
}

sub _load ($self, $path) {
    my $data = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) }
        // Odoo::Error->throw( kind => 'usage', message => "cannot load $path: $@", fix => 'check the path exists and this user can read it' );
    Odoo::Error->throw( kind => 'usage', message => "$path: expected a map of sections", fix => 'correct the parameter or the file the message names, then plan again' ) if ref $data ne 'HASH';
    my %known = map { $_ => 1 } qw(modules params settings company users languages ldap);
    for my $k ( sort keys %$data ) {
        Odoo::Error->throw( kind => 'usage', message => "$path: unknown section '$k'", fix => 'correct the parameter or the file the message names, then plan again' ) if !$known{$k};
    }
    return $data;
}

# --- modules --------------------------------------------------------------

sub _plan_modules ($self, $plan, $spec) {
    my @names = @{ $spec->{install} // [] };
    return 0 if !@names;
    my $mods = $self->model('ir.module.module');
    my $rows = $mods->search_read( [ [ 'name', 'in', \@names ] ], [qw(name state)] );
    if ( @$rows < keys %{ { map { $_ => 1 } @names } } ) {
        # a freshly mounted addon is not in the list until the list is
        # updated (idempotent; the one call here that is not a read)
        $mods->call( 'update_list', [] );
        $rows = $mods->search_read( [ [ 'name', 'in', \@names ] ], [qw(name state)] );
    }
    my %m = map { $_->{name} => $_ } @$rows;
    for my $name (@names) {
        my $key = "module:$name";
        if ( !$m{$name} ) {
            $plan->add( bucket => 'unknown-module', action => 'hold', key => $key,
                reason => 'not in any addons path (update the list or add the addon)' );
        }
        elsif ( $m{$name}{state} eq 'installed' ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $m{$name}{id}, key => $key );
        }
        else {
            $plan->add( bucket => 'install', action => 'call', model => 'ir.module.module', id => $m{$name}{id},
                ids => [ 0 + $m{$name}{id} ], method => 'button_immediate_install', key => $key,
                before => { state => $m{$name}{state} },
                verify => { model => 'ir.module.module', ids => [ 0 + $m{$name}{id} ], fields => { state => 'installed' } } );
        }
    }
    return scalar @names;
}

# --- ldap servers (auth_ldap's res.company.ldap) ----------------------------

my %LDAP_KNOWN = map { $_ => 1 } qw(name server port base filter bind_user bind_password_file create_user user_template company);

# Odoo has no name on an LDAP server record: a server is recognised by its
# company and host. The password is never put in the plan (a plan is a file
# on disk): the change carries the path of the file, read at apply.
sub _plan_ldap ($self, $plan, $spec, $installing) {
    Odoo::Error->throw( kind => 'usage', message => 'ldap must be a list of servers', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'ARRAY';
    return 0 if !@$spec;
    my $mods  = $self->model('ir.module.module');
    my ($mod) = @{ $mods->search_read( [ [ 'name', '=', 'auth_ldap' ] ], [qw(name state)] ) };
    my $have  = $mod && $mod->{state} eq 'installed';
    my $ldap  = $have ? $self->model('res.company.ldap') : undef;
    my @ids;
    for my $w (@$spec) {
        Odoo::Error->throw( kind => 'usage', message => 'ldap: each entry is a map', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $w ne 'HASH';
        Odoo::Error->throw( kind => 'usage', message => "ldap: '" . ( $w->{server} // '?' ) . "': a bind password is never a value here; name bind_password_file", fix => 'correct the parameter or the file the message names, then plan again' )
            if exists $w->{bind_password} || exists $w->{password};
        my @bad = grep { !$LDAP_KNOWN{$_} } sort keys %$w;
        Odoo::Error->throw( kind => 'usage', message => "ldap: unknown field(s) " . join( ', ', @bad ) . ' (known: ' . join( ', ', sort keys %LDAP_KNOWN ) . ')', fix => 'correct the parameter or the file the message names, then plan again' ) if @bad;
        for my $req (qw(server base)) {
            Odoo::Error->throw( kind => 'usage', message => "ldap: each server needs '$req'", fix => 'correct the parameter or the file the message names, then plan again' ) if !defined $w->{$req} || $w->{$req} eq '';
        }
    }
    my $companies = $self->model('res.company');
    my $n = 0;
    for my $w (@$spec) {
        $n++;
        my $label = $w->{name} // $w->{server};
        my $key   = "ldap:$label";
        if ( !$have && !$installing ) {
            $plan->add( bucket => 'module-missing', action => 'hold', key => $key,
                reason => 'auth_ldap is not installed; add it to modules.install in this file (or install it) and plan again' );
            next;
        }
        # the password file is checked now so a plan never fails on it at apply
        Odoo::Ops::Credential->secret_file( $w->{bind_password_file}, 'bind_password_file' ) if defined $w->{bind_password_file};

        my $cid;
        if ( defined $w->{company} ) {
            my $rows = $companies->search_read( [ [ 'name', '=', $w->{company} ] ], ['id'] );
            if ( @$rows != 1 ) {
                $plan->add( bucket => 'unknown-company', action => 'hold', key => $key, reason => "no single company named '$w->{company}'" );
                next;
            }
            $cid = $rows->[0]{id};
        }
        else {
            $cid = $companies->search_read( [], ['id'], limit => 1, order => 'id' )->[0]{id};
        }
        my $uid;
        if ( defined $w->{user_template} ) {
            my $rows = $self->model('res.users')->search_read(
                [ [ 'login', '=', $w->{user_template} ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ], ['id'] );
            if ( @$rows != 1 ) {
                $plan->add( bucket => 'unknown-template', action => 'hold', key => $key,
                    reason => "no user with login '$w->{user_template}' (archived users included) to use as the template" );
                next;
            }
            $uid = $rows->[0]{id};
        }
        my %want = (
            company => $cid, ldap_server => "$w->{server}", ldap_server_port => 0 + ( $w->{port} // 389 ),
            ldap_base => "$w->{base}", ldap_filter => $w->{filter} // '(objectClass=*)',
            ldap_binddn => $w->{bind_user} // '',
            create_user => ( $w->{create_user} // 1 ) ? JSON::PP::true : JSON::PP::false,
            ( defined $uid ? ( user => $uid ) : () ),
        );
        my $cur;
        if ($ldap) {
            my $found = $ldap->search_read( [ [ 'company', '=', $cid ], [ 'ldap_server', '=', "$w->{server}" ] ],
                [ keys %want, 'ldap_password' ] );
            if ( @$found > 1 ) {
                $plan->add( bucket => 'ambiguous', action => 'hold', key => $key,
                    reason => scalar(@$found) . " LDAP servers for $w->{server} on that company already; remove the duplicates first" );
                next;
            }
            $cur = $found->[0];
        }
        my $pw_differs = 0;
        if ( defined $w->{bind_password_file} ) {
            my $pw = Odoo::Ops::Credential->secret_file( $w->{bind_password_file}, 'bind_password_file' );
            $pw_differs = !$cur || ( $cur->{ldap_password} // '' ) ne $pw;
        }
        if ( !$cur ) {
            $plan->add( bucket => 'ldap-create', action => 'custom', model => 'res.company.ldap', handler => $self->op_name,
                kind => 'ldap', key => $key, vals => \%want, password_file => $w->{bind_password_file},
                reason => 'creates the server record; not revertable here (the password is read from its file at apply)' );
            next;
        }
        my ( %set, %before );
        for my $f ( sort keys %want ) {
            if ( !_same( $cur->{$f}, $want{$f} ) ) { $set{$f} = $want{$f}; $before{$f} = $cur->{$f} }
        }
        if ( !%set && !$pw_differs ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key );
            next;
        }
        $plan->add( bucket => 'ldap-write', action => 'custom', model => 'res.company.ldap', id => $cur->{id}, handler => $self->op_name,
            kind => 'ldap', key => $key, vals => \%set, before => \%before, password_file => ( $pw_differs ? $w->{bind_password_file} : undef ),
            reason => 'changes the server record' . ( $pw_differs ? ' (the bind password differs from its file)' : '' ) . '; not revertable here' );
    }
    return $n;
}

# --- system parameters ----------------------------------------------------

sub _plan_params ($self, $plan, $spec) {
    Odoo::Error->throw( kind => 'usage', message => 'params must be a map of key: value', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'HASH';
    my @keys = sort keys %$spec;
    return 0 if !@keys;
    my $rows = $self->model('ir.config_parameter')->search_read( [ [ 'key', 'in', \@keys ] ], [qw(key value)] );
    my %p = map { $_->{key} => $_ } @$rows;
    for my $k (@keys) {
        my $key = "param:$k";
        if ( !defined $spec->{$k} ) {
            # ~ means "this parameter is not set": a present one is removed
            # (the before-image keeps the value), an absent one is done
            if ( $p{$k} ) {
                $plan->add( bucket => 'param-unset', action => 'unlink', model => 'ir.config_parameter', id => $p{$k}{id}, key => $key,
                    before => { key => $k, value => $p{$k}{value} } );
            }
            else { $plan->add( bucket => 'unchanged', action => 'skip', key => $key, reason => 'absent and wanted unset' ) }
            next;
        }
        my $v = "$spec->{$k}";
        if ( !$p{$k} ) {
            $plan->add( bucket => 'param-create', action => 'create', model => 'ir.config_parameter', key => $key,
                vals => { key => $k, value => $v }, unique_by => 'key' );
        }
        elsif ( ( $p{$k}{value} // '' ) eq $v ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $p{$k}{id}, key => $key );
        }
        else {
            $plan->add( bucket => 'param-write', action => 'write', model => 'ir.config_parameter', id => $p{$k}{id}, key => $key,
                vals => { value => $v }, before => { value => $p{$k}{value} } );
        }
    }
    return scalar @keys;
}

# --- settings (res.config.settings) ----------------------------------------

sub _plan_settings ($self, $plan, $spec) {
    Odoo::Error->throw( kind => 'usage', message => 'settings must be a map of field: value', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'HASH';
    my @fields = sort keys %$spec;
    return 0 if !@fields;
    my $s       = $self->model('res.config.settings');
    my $known   = $s->fields;
    my @unknown = grep { !$known->{$_} } @fields;
    Odoo::Error->throw( kind => 'usage', message => 'unknown settings field(s): ' . join( ', ', @unknown ) ) if @unknown;
    my $current = $s->call( 'default_get', [ \@fields ] );
    my ( %set, %before );
    for my $f (@fields) {
        my $want = _settings_value( $known->{$f}{type}, $spec->{$f} );
        if ( !_same( $current->{$f}, $want ) ) { $set{$f} = $want; $before{$f} = $current->{$f} }
    }
    if ( !%set ) {
        $plan->add( bucket => 'unchanged', action => 'skip', key => 'settings' );
        return 1;
    }
    $plan->add( bucket => 'settings', action => 'custom', model => 'res.config.settings', handler => $self->op_name,
        kind => 'settings', key => 'settings', vals => \%set, before => \%before,
        reason => 'applied as one settings record (Settings page semantics); not revertable here' );
    return 1;
}

sub _settings_value ($type, $v) {
    return $v ? JSON::PP::true : JSON::PP::false if ( $type // '' ) eq 'boolean';
    return $v;
}

# --- company --------------------------------------------------------------

my %COMPANY_PLAIN = map { $_ => 1 } qw(name email phone website vat street street2 city zip);

sub _plan_company ($self, $plan, $spec) {
    Odoo::Error->throw( kind => 'usage', message => 'company must be a map', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'HASH';
    my $client  = $self->client;
    my $cmp     = $client->model('res.users')->read_one( $client->uid, ['company_id'] )->{company_id};
    my $cid     = ref $cmp eq 'ARRAY' ? $cmp->[0] : $client->model('res.company')->search_read( [], ['id'], limit => 1 )->[0]{id};
    my $company = $self->model('res.company');
    my $cf      = $company->fields;
    my @read    = ( keys %COMPANY_PLAIN, 'country_id', 'currency_id', ( $cf->{chart_template} ? 'chart_template' : 'chart_template_id' ) );
    my $cur     = $company->read_one( $cid, [ grep { $cf->{$_} } @read ] );
    my ( %set, %before, $n );
    for my $k ( sort keys %$spec ) {
        $n++;
        my $v = $spec->{$k};
        if ( $COMPANY_PLAIN{$k} ) {
            if ( !_same( $cur->{$k}, $v ) ) { $set{$k} = $v; $before{$k} = $cur->{$k} }
        }
        elsif ( $k eq 'country' ) {
            my $id = $self->_lookup( 'res.country', 'code', uc $v, 'country' );
            if ( !_same( $cur->{country_id}, $id ) ) { $set{country_id} = $id; $before{country_id} = $cur->{country_id} }
        }
        elsif ( $k eq 'currency' ) {
            # its own row: Odoo refuses a currency change once journal
            # items exist, so that is held here rather than failed there
            my $id = $self->_lookup( 'res.currency', 'name', uc $v, 'currency' );
            if ( _same( $cur->{currency_id}, $id ) ) {
                $plan->add( bucket => 'unchanged', action => 'skip', id => $cid, key => 'company:currency' );
            }
            elsif ( $self->_journal_items($cid) ) {
                $plan->add( bucket => 'currency-locked', action => 'hold', key => 'company:currency',
                    reason => "journal items exist in the current currency; Odoo refuses the change to $v" );
            }
            else {
                $plan->add( bucket => 'company-currency', action => 'write', model => 'res.company', id => $cid, key => 'company:currency',
                    vals => { currency_id => $id }, before => { currency_id => $cur->{currency_id} } );
            }
        }
        elsif ( $k eq 'chart' ) {
            my $have = $cf->{chart_template} ? $cur->{chart_template} : $cur->{chart_template_id};
            if ( !$have ) {
                $plan->add( bucket => 'chart', action => 'custom', model => 'account.chart.template', handler => $self->op_name,
                    kind => 'chart', key => 'company:chart', vals => { chart => $v, company_id => $cid, field => ( $cf->{chart_template} ? 'chart_template' : 'chart_template_id' ) },
                    reason => 'loads the chart of accounts for a company without one; not revertable' );
            }
            else { $plan->add( bucket => 'unchanged', action => 'skip', id => $cid, key => 'company:chart' ) }
            $n--;    # counted below as its own row
            $n++;
            next;
        }
        else { Odoo::Error->throw( kind => 'usage', message => "company: unknown field '$k'" ) }
    }
    my $rows = grep { $_ ne 'chart' && $_ ne 'currency' } keys %$spec;
    if ($rows) {
        if (%set) {
            $plan->add( bucket => 'company', action => 'write', model => 'res.company', id => $cid, key => 'company',
                vals => \%set, before => \%before );
        }
        else { $plan->add( bucket => 'unchanged', action => 'skip', id => $cid, key => 'company' ) }
    }
    # one row for the company fields together, one each for chart and currency
    return ( $rows ? 1 : 0 ) + ( exists $spec->{chart} ? 1 : 0 ) + ( exists $spec->{currency} ? 1 : 0 );
}

# journal items of the company, or 0 when accounting is not installed
sub _journal_items ($self, $cid) {
    my $n = eval { $self->model('account.move.line')->count( [ [ 'company_id', '=', $cid ] ] ) };
    return $n // 0;
}

# a record by one field, inactive ones included (a currency is usually
# inactive until used); the domain says so, which every server honours
sub _lookup ($self, $model, $field, $value, $what, %opts) {
    my $m      = $self->model($model);
    my @domain = ( [ $field, '=', $value ] );
    push @domain, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] if $m->fields->{active};
    my $rows = $m->search_read( \@domain, ['id'] );
    Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "unknown $what '$value'", fix => "name a $what that exists on the instance" ) if !@$rows;
    Odoo::Error->throw( kind => 'usage', message => "$what '$value' matches " . scalar(@$rows) . ' records; name it exactly' ) if @$rows > 1;
    return $rows->[0]{id};
}

# --- users ----------------------------------------------------------------

sub _plan_users ($self, $plan, $spec) {
    Odoo::Error->throw( kind => 'usage', message => 'users must be a list', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'ARRAY';
    return 0 if !@$spec;
    my $users  = $self->model('res.users');
    my $uf     = $users->fields;
    my $gfield = $uf->{group_ids} ? 'group_ids' : 'groups_id';
    my @logins = map { $_->{login} // Odoo::Error->throw( kind => 'usage', message => 'users: each entry needs a login', fix => 'add a login to each entry of users in the spec file' ) } @$spec;
    my $rows   = $users->search_read( [ [ 'login', 'in', \@logins ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
        [ 'login', 'name', 'active', $gfield ] );
    my %u = map { $_->{login} => $_ } @$rows;
    for my $w (@$spec) {
        my $key = "user:$w->{login}";
        my @gids = map { $self->_group_id($_) } @{ $w->{groups} // [] };
        my $cur  = $u{ $w->{login} };
        if ( !$cur ) {
            if ( exists $w->{active} && !$w->{active} ) {
                $plan->add( bucket => 'unchanged', action => 'skip', key => $key, reason => 'absent and wanted inactive' );
                next;
            }
            Odoo::Error->throw( kind => 'usage', message => "users: $w->{login} needs a name to be created", fix => 'correct the parameter or the file the message names, then plan again' ) if !$w->{name};
            $plan->add( bucket => 'user-create', action => 'create', model => 'res.users', key => $key, unique_by => { field => 'login', fold => 1 },
                vals => { login => $w->{login}, name => $w->{name}, ( @gids ? ( $gfield => [ x2m_set( \@gids ) ] ) : () ) },
                context => { no_reset_password => JSON::PP::true },
                readback => [ 'login', 'name' ] );
            next;
        }
        my ( %set, %before );
        if ( defined $w->{name} && $w->{name} ne $cur->{name} ) { $set{name} = $w->{name}; $before{name} = $cur->{name} }
        if ( exists $w->{active} ) {
            my $want = $w->{active} ? 1 : 0;
            if ( ( $cur->{active} ? 1 : 0 ) != $want ) { $set{active} = $want ? JSON::PP::true : JSON::PP::false; $before{active} = $cur->{active} }
        }
        if ( @{ $w->{groups} // [] } ) {
            # the wanted groups must be held; implied groups Odoo adds are kept
            my %have = map { $_ => 1 } @{ $cur->{$gfield} // [] };
            my @missing = grep { !$have{$_} } @gids;
            if (@missing) { $set{$gfield} = [ map { [ 4, $_, 0 ] } @missing ]; $before{$gfield} = $cur->{$gfield} }
        }
        if (%set) {
            $plan->add( bucket => 'user-write', action => 'write', model => 'res.users', id => $cur->{id}, key => $key,
                vals => \%set, before => \%before, readback => [ grep { $_ ne $gfield } keys %set ] );
        }
        else { $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key ) }
    }
    return scalar @$spec;
}

sub _group_id ($self, $xmlid) {
    my ( $module, $name ) = split /\./, $xmlid, 2;
    Odoo::Error->throw( kind => 'usage', message => "group '$xmlid' is not an xml id (module.name)" ) if !$name;
    my $rows = $self->model('ir.model.data')->search_read(
        [ [ 'module', '=', $module ], [ 'name', '=', $name ], [ 'model', '=', 'res.groups' ] ], ['res_id'] );
    Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "unknown group '$xmlid'", fix => 'name a group that exists on the instance (module.name)' ) if @$rows != 1;
    return 0 + $rows->[0]{res_id};
}

# --- languages ------------------------------------------------------------

sub _plan_languages ($self, $plan, $spec) {
    Odoo::Error->throw( kind => 'usage', message => 'languages must be a list of codes', fix => 'correct the parameter or the file the message names, then plan again' ) if ref $spec ne 'ARRAY';
    return 0 if !@$spec;
    my $rows = $self->model('res.lang')->search_read( [ [ 'code', 'in', $spec ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ], [qw(code active)] );
    my %l = map { $_->{code} => $_ } @$rows;
    for my $code (@$spec) {
        my $key = "lang:$code";
        if    ( !$l{$code} ) { Odoo::Error->throw( kind => 'usage', message => "unknown language code '$code'" ) }
        elsif ( $l{$code}{active} ) { $plan->add( bucket => 'unchanged', action => 'skip', id => $l{$code}{id}, key => $key ) }
        else {
            $plan->add( bucket => 'language', action => 'custom', model => 'base.language.install', handler => $self->op_name,
                kind => 'lang', key => $key, vals => { code => $code, lang_id => $l{$code}{id} },
                reason => 'installs the language and loads its translations; not revertable here' );
        }
    }
    return scalar @$spec;
}

# --- apply of the custom changes --------------------------------------------

# settings, chart and lang are irreversible: a saved setting, a loaded chart
# and an installed language have no inverse the server offers
sub undo_custom ($class, $entry) {
    my $kind = $entry->{kind} // 'change';
    return ( undef, "core.configure $kind has no inverse (settings, chart of accounts and language installs are not undone)" );
}

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    if ( $kind eq 'settings' ) {
        my $s  = $client->model('res.config.settings');
        my $id = $s->create( $c->{vals} );
        $s->call( 'execute', [ [$id] ] );
        my $after = $s->call( 'default_get', [ [ sort keys %{ $c->{vals} } ] ] );
        my $ok = 1;
        for my $f ( keys %{ $c->{vals} } ) { $ok = 0 if !_same( $after->{$f}, $c->{vals}{$f} ) }
        return { id => $id, after => ( $ok ? $after : undef ) };
    }
    if ( $kind eq 'chart' ) {
        my $v = $c->{vals};
        if ( $v->{field} eq 'chart_template' ) {
            $client->model('account.chart.template')->call( 'try_loading', [ $v->{chart} eq 'generic' ? 'generic_coa' : $v->{chart} ],
                company => $v->{company_id}, install_demo => JSON::PP::false );
        }
        else {
            # 16: the generic chart is a module; installing it loads the chart
            my $mod = $client->model('ir.module.module')->search( [ [ 'name', '=', 'l10n_generic_coa' ], [ 'state', '!=', 'installed' ] ], limit => 1 );
            $client->model('ir.module.module')->call( 'button_immediate_install', [$mod] ) if @$mod;
        }
        my $after = $client->model('res.company')->read_one( $v->{company_id}, [ $v->{field} ] );
        return { id => $v->{company_id}, after => ( $after->{ $v->{field} } ? $after : undef ) };
    }
    if ( $kind eq 'lang' ) {
        my $w  = $client->model('base.language.install');
        my $id = $w->create( { lang_ids => [ x2m_set( [ $c->{vals}{lang_id} ] ) ] } );
        $w->call( 'lang_install', [ [$id] ] );
        my $after = $client->model('res.lang')->read_one( $c->{vals}{lang_id}, ['active'] );
        return { id => $c->{vals}{lang_id}, after => ( $after->{active} ? $after : undef ) };
    }
    if ( $kind eq 'ldap' ) {
        my $ldap = $client->model('res.company.ldap');
        my %vals = %{ $c->{vals} };
        $vals{ldap_password} = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'bind_password_file' ) if defined $c->{password_file};
        my $id = $c->{id};
        if ( !$id ) {
            # planned as a create: a record made since planning is reused, not doubled
            my $co = $vals{company};
            my $dup = $ldap->search( [ [ 'company', '=', $co ], [ 'ldap_server', '=', $vals{ldap_server} ] ], limit => 1 );
            $id = $dup->[0] if @$dup;
        }
        if ($id) { $ldap->write( [$id], \%vals ) if %vals }
        else     { $id = $ldap->create( \%vals ) }
        my $after = $ldap->read_one( $id, [ grep { $_ ne 'ldap_password' } keys %vals ] );
        my $ok = 1;
        for my $f ( keys %$after ) { $ok = 0 if exists $c->{vals}{$f} && !_same( $after->{$f}, $c->{vals}{$f} ) }
        return { id => $id, after => ( $ok ? $after : undef ) };
    }
    Odoo::Error->throw( kind => 'usage', message => "core.configure cannot apply kind '$kind'" );
}

sub _same ($got, $want) {
    $got = $got->[0] if ref $got eq 'ARRAY' && @$got == 2 && !ref $want;
    return 1 if !defined $got && !defined $want;
    if ( JSON::PP::is_bool($want) || JSON::PP::is_bool($got) ) { return ( $got ? 1 : 0 ) == ( $want ? 1 : 0 ) }
    return 1 if !defined $got && ( $want eq '' );
    return 0 if !defined $got || !defined $want;
    return "$got" eq "$want";
}

1;

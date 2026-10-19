package Odoo::Ops::Core::User;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use JSON::PP ();

use Odoo::Client;
use Odoo::Commands qw(x2m_set);
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Credential;
use Odoo::Ops::ResetForm;
use Odoo::Ops::Rows;
use Odoo::Transport::Session ();
use Odoo::Ops::Totp;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::User - users and portal users through Odoo's own flows

=head1 SYNOPSIS

    # a file of users, one row each with an action
    oom-ops run core.user --conf C --set rows=users.jsonl

    # in-process
    Odoo::Ops::Core::User->new( ctx => $ctx, params => { records => [
        { action => 'create', login => 'ana@acme.example', name => 'Ana', kind => 'portal', partner => 'ref=C001' },
        { action => 'password', login => 'ana@acme.example', password_file => '/run/keys/ana.pw' },
    ] } )->run;

=head1 DESCRIPTION

C<core.user>: one row per user and an C<action>. Matching is by
C<login>, case-insensitively.

    create       login, name, kind (internal | portal, default internal),
                 groups (xml ids; internal only), partner (an existing
                 partner, "ref=C001" or "email=a@b.example", for a portal
                 user; absent: a partner is made from name and email),
                 email, company (name), lang, tz.
                 A portal user is made the way Odoo's portal wizard
                 makes one (portal.wizard + portal.wizard.user
                 action_grant_access), so its invitation rules apply
                 and its invitation email is sent; where the instance
                 has no wizard, res.users is created with the portal
                 group and no_reset_password. A portal login is the
                 partner's email address.
    password     password_file: a file (mode 0600) holding the
                 password. The value is read at apply; it is never in
                 the plan or the journal. The journal records the file
                 name and whether the password then authenticated.
    reset        Odoo's own reset email (action_reset_password).
    api-key      mint an API key as the user: password_file (the
                 user's password, which Odoo's identity check asks
                 for), key_file (a new 0600 file for the key), name
                 (the key's description) and duration (days, where the
                 series offers the choice). Internal users only.
    totp         two_factor: on | off. On: Odoo's own flow as the user
                 (password_file: the user's password, for the identity
                 check): auth_totp's enable wizard is opened over the
                 user's web session, its secret is read, the code for
                 it is computed here (RFC 6238, see L<Odoo::Ops::Totp>)
                 and the wizard's enable is called, so the account ends
                 as one a person has set up. The secret is then
                 forgotten: it is in no file, plan or journal, and the
                 account can be refused a password-only sign-in but
                 cannot be signed in to by this tool again. Off:
                 action_totp_disable, called over the connection's own
                 web session with the connection's secret as the
                 password (so the connection must be an administrator
                 whose secret is a password; a real API key does not
                 open a web session), because a user with two-factor on
                 cannot open a password session. Internal, active users
                 only; needs the auth_totp module.
    api-key-revoke
                 revoke the user's keys of one description (name)
                 except the newest, as the user over a web session
                 (password_file): what rotating a key finishes with.
                 Odoo lets the owner remove a key; an administrator's
                 unlink of another user's key is refused by the
                 model's access list (read live on 16, 18 and 19);
                 one key of that name is unchanged. Internal users without two-factor.
    reset-take   take a password-reset link: link (the whole URL Odoo
                 mailed or showed, https://host/web/reset_password?
                 db=...&token=...) or token (the instance and database
                 are then the config's), password_file (a 0600 file
                 holding the password, or the path of one to make), and
                 optionally login (it must be the one the form names).
                 It is what a person's "forgot password" page does, so
                 it holds on every series: the form is read (GET), the
                 password is made (24 characters of a safe alphabet)
                 and written to password_file first, the form is
                 submitted (POST) and the password is proved by
                 signing in with it. The route is public: the row
                 needs no login of an administrator, only the
                 instance's url (and CA) in the config, and a plan or
                 apply of it makes no authenticated call. The token is
                 consumed by Odoo (the link stops working); the plan
                 is therefore irreversible, and a second use of the
                 same link is held C<invalid-token>. The journal
                 carries the login, the database, the file's path,
                 the uid read back and the first six characters of the
                 token; the plan file carries the link, because the
                 apply needs it, so a runs directory is as private as
                 the password file is. A signup link
                 (C</web/signup>) makes a user: it is held
                 C<not-a-reset-form>. C<oom-accounts take-reset> is
                 the workflow around this row.
    deactivate / activate
    groups       add and remove: lists of group xml ids.

A row is a flat map (as for L<Odoo::Ops::Core::Import>): C<records>
in-process, or C<rows> as a C<.jsonl>, C<.json> or C<.csv> file (lists
in a cell are separated by C<;> or C<,>). No password is ever a row
value.

Every row lands in one bucket: C<create>, C<password>, C<reset>,
C<api-key>, C<api-key-revoke>, C<totp>, C<reset-take>, C<deactivate>, C<activate>, C<groups>, C<unchanged>, or a
hold named for the reason: C<unknown-user>, C<exists>,
C<unknown-group>, C<unknown-partner>, C<ambiguous-partner>,
C<unknown-company>, C<no-email>, C<login-not-email>,
C<password-file-missing>, C<not-internal>, C<key-file-exists>,
C<no-totp>, C<inactive-user>, C<two-factor-on>, C<invalid-token>, C<not-a-reset-form>,
C<url-mismatch>, C<db-mismatch>, C<login-mismatch>, C<needs-login>, C<invalid>, C<held-flag>.

A re-run is quiet: a password that already authenticates and a key file
whose key already authenticates are C<unchanged>.

A password row may follow the create row of the same login in one file:
the password change depends on the create, as a line depends on its
header in C<core.import>, and the user's id is bound at apply. Every
other action on a user an earlier row of the file creates is held
C<unknown-user> (the reason says so): plan it after the apply. A
password row is planned without the "already authenticates" test for
such a user, which cannot be made before the user exists.

=cut

sub op_name ($class) { 'core.user' }
sub summary ($class) { 'Create, secure and manage users and portal users through Odoo\'s own flows' }
sub pack    ($class) { undef }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'create', meaning => 'a user is made (internal, or a portal user for an existing partner)' },
        { name => 'new-partner', meaning => 'the partner a portal user needs is made first' },
        { name => 'password', meaning => 'a password is set from a 0600 file; its value is never in the plan' },
        { name => 'reset', meaning => 'Odoo\'s own password-reset email is sent' },
        { name => 'api-key', meaning => 'an API key is made and written to a 0600 file' },
        { name => 'api-key-revoke', meaning => 'the user\'s API keys are removed' },
        { name => 'totp', meaning => 'two-factor is turned on or off for the user' },
        { name => 'reset-take', meaning => 'a password-reset link is taken: the password is set through Odoo\'s own reset page, from a file; the link is consumed' },
        { name => 'deactivate', meaning => 'the user is archived (row: {"action":"deactivate","login":"ana@acme.example"})' },
        { name => 'activate', meaning => 'the user is restored' },
        { name => 'groups', meaning => 'the user\'s groups are written' },
        { name => 'unchanged', meaning => 'the user already matches' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-user', meaning => 'the login names no user' },
        { name => 'exists', meaning => 'a user with this login (or for this partner) exists already, or an earlier row of the file creates it' },
        { name => 'unknown-group', meaning => 'a group does not exist' },
        { name => 'unknown-partner', meaning => 'the partner a portal user is for is not found' },
        { name => 'ambiguous-partner', meaning => 'the partner key matches more than one partner' },
        { name => 'unknown-company', meaning => 'no company has that name' },
        { name => 'no-email', meaning => 'the user (a reset) or the portal partner has no email address' },
        { name => 'login-not-email', meaning => 'a portal login must be the partner\'s email address' },
        { name => 'password-file-missing', meaning => 'the password file the row names cannot be read' },
        { name => 'not-internal', meaning => 'the user is a portal user; API keys and two-factor are for internal users' },
        { name => 'key-file-exists', meaning => 'key_file exists and its key does not authenticate the user; remove it to mint a new one' },
        { name => 'no-totp', meaning => 'this instance has no two-factor (auth_totp is not installed)' },
        { name => 'inactive-user', meaning => 'the user is archived and cannot sign in to set two-factor up; activate it first' },
        { name => 'two-factor-on', meaning => 'two-factor is on, so the password session an API key is made or removed in cannot open; turn it off first' },
        { name => 'invalid-token', meaning => 'reset-take: Odoo says the signup token is invalid (unknown, used already or expired: the page does not say which)' },
        { name => 'not-a-reset-form', meaning => 'reset-take: the URL answers but is not the password-reset form (a signup link, a 404, a login page)' },
        { name => 'url-mismatch', meaning => 'reset-take: the link names another instance than the config\'s url' },
        { name => 'db-mismatch', meaning => 'reset-take: the link names another database than the config\'s' },
        { name => 'needs-login', meaning => 'reset-take: the series\' reset form does not name the user (19), and the row gives no login' },
        { name => 'login-mismatch', meaning => 'reset-take: the login the row gives is not the one the form names' },
        { name => 'invalid', meaning => 'the row is malformed: no action or login, an unknown action, a secret in the row, a value that does not fit' },
        { name => 'held-flag', meaning => 'the source flagged the row as held' },
    ];
}

sub params ($class) {
    {   records => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
        rows    => { type => 'path', help => 'rows file: .jsonl, .json (a list) or .csv; one row per user with an action, for example {"action":"deactivate","login":"ana@acme.example"} (archives the user), or {"action":"create","login":"ana@acme.example","name":"Ana","groups":["base.group_user"]} then {"action":"password","login":"ana@acme.example","password_file":"/run/keys/ana.pw"} in the same file' },
    };
}

# the models a row can touch are known; the apply scope is therefore fixed
sub read_scope ($class) {
    {   'res.users'       => [qw(search search_read)],
        'res.partner'     => ['search_read'],
        'res.company'     => ['search_read'],
        'ir.model.data'   => ['search_read'],
        'res.users.apikeys' => ['search_read'],
    };
}

sub write_scope ($class) {
    {   'res.users'      => [qw(create write search action_reset_password action_totp_enable_wizard action_totp_disable)],
        'res.partner'    => [qw(create search_read)],
        'portal.wizard'      => [qw(create)],
        'portal.wizard.user' => [qw(search_read write action_grant_access)],
        'res.users.apikeys.description' => [qw(create make_key)],
        'res.users.apikeys'             => [qw(search_read remove)],
        'res.users.identitycheck'       => [qw(write run_check)],
        'auth_totp.wizard'              => [qw(read write enable)],
    };
}

my %ACTION = map { $_ => 1 } qw(create password reset api-key api-key-revoke totp reset-take deactivate activate groups);

sub plan ($self) {
    my @in = grep { defined $self->param($_) } qw(records rows);
    Odoo::Error->throw( kind => 'usage', message => 'core.user: give exactly one of records, rows (got ' . ( @in ? "@in" : 'none' ) . ')' )
        if @in != 1;
    my $rows = Odoo::Ops::Rows->load( 'core.user', map { $_ => $self->param($_) } @in );

    # a reset-take row is the public reset page and needs no authenticated call:
    # the users are read only when some row is about a user
    my @about = grep { lc( _s( ref $_->{values} eq 'HASH' ? $_->{values}{action} : undef ) // '' ) ne 'reset-take' } @$rows;
    my ( $users, $gfield );
    if (@about) {
        $users  = $self->model('res.users');
        $gfield = $users->fields->{group_ids} ? 'group_ids' : 'groups_id';
        $self->{gfield} = $gfield;
        $self->{portal_wizard} = eval { $self->model('portal.wizard')->fields; $self->model('portal.wizard.user')->fields; 1 } ? 1 : 0;
    }

    # one read of every login named, archived included; matched exactly (no case) here
    my %logins = map { lc( _s( $_->{values}{login} ) // '' ) => 1 } @about;
    delete $logins{''};
    my %have;
    if (%logins) {
        my @terms  = map { [ 'login', '=ilike', $_ ] } sort keys %logins;
        my @domain = ( ('|') x ( @terms - 1 ), @terms );
        my $found  = $users->search_read( [ @domain, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [ 'login', 'name', 'active', 'share', 'email', 'partner_id', $gfield, ( $users->fields->{totp_enabled} ? 'totp_enabled' : () ) ] );
        $have{ lc $_->{login} } = $_ for @$found;
    }

    my $plan = $self->new_plan( input_count => scalar @$rows );
    $plan->note( 'core.user: ' . scalar(@$rows) . ' rows' . ( @about ? '; ' . ( $self->{portal_wizard} ? 'portal users through the portal wizard' : 'no portal wizard on this instance: portal users are created directly with the portal group' ) : '' ) );
    $plan->note('reset-take: Odoo\'s public reset page, so no administrator credential is used; the signup token is consumed and the link stops working')
        if @about < @$rows;
    for my $row (@$rows) {
        $self->_plan_row( $plan, $row, \%have );
    }
    return $plan;
}

sub _hold ($plan, $bucket, $row, $reason) {
    $plan->add( bucket => $bucket, action => 'hold', key => "src:$row->{key}", reason => $reason );
}

# a string, trimmed; undef for what Odoo calls empty (false arrives as 0)
sub _s ($v) {
    return undef if !defined $v || ref $v;
    my $t = $v =~ s/^\s+|\s+\z//gr;
    return $t eq '0' ? undef : $t;
}

sub _list ($v) {
    return [] if !defined $v;
    return [ grep { defined && length } map { _s($_) } @$v ] if ref $v eq 'ARRAY';
    return [ grep { length } map { _s($_) } split /\s*[;,]\s*/, $v ];
}

sub _plan_row ($self, $plan, $row, $have) {
    return _hold( $plan, 'invalid', $row, $row->{error} ) if defined $row->{error};
    if ( my $h = $row->{held} ) { return _hold( $plan, 'held-flag', $row, $h ) }
    my $v = $row->{values};
    return _hold( $plan, 'invalid', $row, 'no values' ) if ref $v ne 'HASH';
    for my $secret (qw(password passwd)) {
        return _hold( $plan, 'invalid', $row, "a row never carries '$secret'; name a password_file" ) if exists $v->{$secret};
    }
    my $action = lc( _s( $v->{action} ) // '' );
    return _hold( $plan, 'invalid', $row, 'row has no action (' . join( ', ', sort keys %ACTION ) . ')' ) if $action eq '';
    return _hold( $plan, 'invalid', $row, "unknown action '$action' (" . join( ', ', sort keys %ACTION ) . ')' ) if !$ACTION{$action};
    return $self->_plan_reset_take( $plan, $row, $v ) if $action eq 'reset-take';
    my $login = _s( $v->{login} );
    return _hold( $plan, 'invalid', $row, 'row has no login' ) if !defined $login || $login eq '';

    my $cur = $have->{ lc $login };
    if ( $action eq 'create' ) {
        return _hold( $plan, 'exists', $row, "an earlier row of this file creates '$login'" ) if !$cur && $self->{creating}{ lc $login }++;
        my $n = @{ $plan->changes };
        my $r = $self->_plan_create( $plan, $row, $v, $login, $cur );
        # only a create row that was planned, not held, makes the user a later row cannot yet name
        $self->{created}{ lc $login } = 1 if !$cur && @{ $plan->changes } > $n && $plan->changes->[-1]{action} ne 'hold';
        return $r;
    }

    # A user an earlier create row of this file makes is not there at plan time. A password row for it is
    # planned to depend on that create (resolved at apply, as a line depends on its header in core.import);
    # any other action waits for a second plan, and its hold says so.
    if ( !$cur && $self->{created}{ lc $login } ) {
        return $self->_plan_password_after_create( $plan, $row, $v, $login ) if $action eq 'password';
        return _hold( $plan, 'unknown-user', $row, "no user '$login' yet: an earlier row of this file creates it; plan the $action row after the apply" );
    }
    return _hold( $plan, 'unknown-user', $row, "no user '$login'" ) if !$cur;

    my $key = "user:$login";
    if ( $action eq 'deactivate' || $action eq 'activate' ) {
        my $want = $action eq 'activate' ? 1 : 0;
        return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => $want ? 'already active' : 'already inactive' )
            if ( $cur->{active} ? 1 : 0 ) == $want;
        return $plan->add( bucket => $action, action => 'write', model => 'res.users', id => $cur->{id}, key => $key,
            vals => { active => $want ? JSON::PP::true : JSON::PP::false }, before => { active => $cur->{active} },
            readback => ['active'] );
    }
    if ( $action eq 'groups' ) {
        my ( @add, @rm, @unknown );
        for my $x ( @{ _list( $v->{add} ) } ) {
            my $id = $self->_group_id($x);
            defined $id ? push @add, $id : push @unknown, $x;
        }
        for my $x ( @{ _list( $v->{remove} ) } ) {
            my $id = $self->_group_id($x);
            defined $id ? push @rm, $id : push @unknown, $x;
        }
        return _hold( $plan, 'unknown-group', $row, 'unknown group ' . join( ', ', @unknown ) ) if @unknown;
        return _hold( $plan, 'invalid', $row, 'groups needs add or remove' ) if !@add && !@rm;
        my $gf   = $self->{gfield};
        my %held = map { $_ => 1 } @{ $cur->{$gf} // [] };
        my @cmd  = ( ( map { [ 4, $_, 0 ] } grep { !$held{$_} } @add ), ( map { [ 3, $_, 0 ] } grep { $held{$_} } @rm ) );
        return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => 'groups already as asked' ) if !@cmd;
        return $plan->add( bucket => 'groups', action => 'write', model => 'res.users', id => $cur->{id}, key => $key,
            vals => { $gf => \@cmd }, before => { $gf => $cur->{$gf} }, readback => [] );
    }
    if ( $action eq 'reset' ) {
        my $email = _s( $cur->{email} );
        return _hold( $plan, 'no-email', $row, "user '$login' has no email address for the reset message" ) if !defined $email || $email eq '';
        return $plan->add( bucket => 'reset', action => 'call', model => 'res.users', method => 'action_reset_password', ids => [ $cur->{id} ],
            key => $key, reason => "Odoo's reset email to $email" );
    }
    if ( $action eq 'password' ) {
        my $pw = $self->_secret( $v->{password_file}, 'password_file' );
        return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
        return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => 'the password in the file already authenticates' )
            if _password_authenticates( $self->client, $login, $pw->{secret}, $cur->{id} );
        return $plan->add( bucket => 'password', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
            kind => 'password', key => $key, login => $cur->{login}, password_file => $v->{password_file}, calls => [ [ 'res.users', 'write' ] ],
            reason => 'sets the password from the file; the value is not in the plan' );
    }
    return $self->_plan_totp( $plan, $row, $v, $login, $cur ) if $action eq 'totp';
    return $self->_plan_revoke( $plan, $row, $v, $login, $cur ) if $action eq 'api-key-revoke';
    # api-key
    return _hold( $plan, 'not-internal', $row, "user '$login' is a portal user; Odoo gives API keys to internal users only" ) if $cur->{share};
    return _hold( $plan, 'invalid', $row, 'api-key needs key_file' ) if !defined _s( $v->{key_file} ) || _s( $v->{key_file} ) eq '';
    my $pw = $self->_secret( $v->{password_file}, 'password_file' );
    return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
    my $kf = _s( $v->{key_file} );
    if ( -e $kf ) {
        my $k = $self->_secret( $kf, 'key_file' );
        return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => 'key_file already holds a key that authenticates' )
            if defined $k->{secret} && _authenticates( $self->client, $login, $k->{secret}, $cur->{id} );
        return _hold( $plan, 'key-file-exists', $row, "key_file $kf exists and its key does not authenticate '$login'; remove it to mint a new key" );
    }
    return _hold( $plan, 'two-factor-on', $row, "user '$login' has two-factor on and cannot open the password session a key is minted in; turn it off first" ) if $cur->{totp_enabled};
    my $dur = _s( $v->{duration} );
    return _hold( $plan, 'invalid', $row, "duration '$dur' is not a number of days" ) if defined $dur && $dur ne '' && $dur !~ /^-?\d+\z/;
    return $plan->add( bucket => 'api-key', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
        kind => 'api-key', key => $key, login => $cur->{login}, password_file => $v->{password_file}, key_file => $kf,
        calls => [ [ 'res.users.apikeys.description', 'create' ], [ 'res.users.apikeys.description', 'make_key' ], _identity_calls( $self->client->server_series ) ],
        description => _s( $v->{name} ) // 'oom', ( defined $dur && $dur ne '' ? ( duration => $dur ) : () ),
        reason => 'mints a key as the user over a web session; the key goes to key_file only' );
}

# --- api-key-revoke ----------------------------------------------------------

# the identity check Odoo asks for before a key or two-factor change: 16 to 18 write the password to the wizard, 19 sends it in the context
sub _identity_calls ($series) {
    return ( [ 'res.users.identitycheck', 'run_check' ], ( $series < 19 ? ( [ 'res.users.identitycheck', 'write' ] ) : () ) );
}

sub _plan_revoke ($self, $plan, $row, $v, $login, $cur) {
    my $key  = "user:$login";
    my $name = _s( $v->{name} );
    return _hold( $plan, 'invalid', $row, 'api-key-revoke needs name (the keys\' description)' ) if !defined $name || $name eq '';
    return _hold( $plan, 'not-internal', $row, "user '$login' is a portal user; Odoo gives API keys to internal users only" ) if $cur->{share};
    return _hold( $plan, 'two-factor-on', $row, "user '$login' has two-factor on and cannot open the password session a key is removed in" ) if $cur->{totp_enabled};
    my $pw = $self->_secret( $v->{password_file}, 'password_file' );
    return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
    my $keys = $self->model('res.users.apikeys')->search_read( [ [ 'user_id', '=', $cur->{id} ], [ 'name', '=', $name ] ], ['name'] );
    my @ids = sort { $a <=> $b } map { $_->{id} } @$keys;
    return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => scalar(@ids) . " key(s) named '$name'; none to revoke" )
        if @ids < 2;
    pop @ids;    # the newest stays
    return $plan->add( bucket => 'api-key-revoke', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
        kind => 'api-key-revoke', key => $key, login => $cur->{login}, password_file => $v->{password_file}, key_ids => \@ids, description => $name,
        calls => [ [ 'res.users.apikeys', 'remove' ], [ 'res.users.apikeys', 'search_read' ], _identity_calls( $self->client->server_series ) ],
        reason => "removes key(s) @ids named '$name' as the user; the newest stays" );
}

# --- totp ------------------------------------------------------------------

sub _plan_totp ($self, $plan, $row, $v, $login, $cur) {
    my $key = "user:$login";
    my $raw = lc( _s( $v->{two_factor} ) // '' );
    my $want = $raw =~ /^(on|1|yes|true)\z/ ? 1 : $raw =~ /^(off|0|no|false)\z/ ? 0 : undef;
    return _hold( $plan, 'invalid', $row, "totp needs two_factor on or off, got '$raw'" ) if !defined $want;
    return _hold( $plan, 'no-totp', $row, 'this instance has no two-factor (the auth_totp module is not installed)' )
        if !$self->model('res.users')->fields->{totp_enabled};
    return _hold( $plan, 'not-internal', $row, "user '$login' is a portal user; two-factor is set up here for internal users only" ) if $cur->{share};
    my $now = $cur->{totp_enabled} ? 1 : 0;
    return $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key, reason => $want ? 'two-factor already on' : 'two-factor already off' )
        if $now == $want;
    if ( !$want ) {
        return $plan->add( bucket => 'totp', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
            kind => 'totp', two_factor => 'off', key => $key, login => $cur->{login},
            calls => [ [ 'res.users', 'action_totp_disable' ], [ 'res.users', 'read' ], _identity_calls( $self->client->server_series ) ],
            reason => 'turns two-factor off through action_totp_disable over the connection\'s own web session' );
    }
    return _hold( $plan, 'inactive-user', $row, "user '$login' is inactive and cannot sign in to set two-factor up; activate it first" ) if !$cur->{active};
    my $pw = $self->_secret( $v->{password_file}, 'password_file' );
    return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
    return $plan->add( bucket => 'totp', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
        kind => 'totp', two_factor => 'on', key => $key, login => $cur->{login}, password_file => $v->{password_file},
        calls => [ [ 'res.users', 'action_totp_enable_wizard' ], [ 'res.users', 'read' ], [ 'auth_totp.wizard', 'read' ], [ 'auth_totp.wizard', 'enable' ],
            ( $self->client->server_series < 19 ? ( [ 'auth_totp.wizard', 'write' ] ) : () ), _identity_calls( $self->client->server_series ) ],
        reason => 'turns two-factor on through auth_totp\'s own wizard as the user; the secret is not kept' );
}

# --- create ---------------------------------------------------------------

# A password row for a user an earlier row of this file creates: the user's id is the create's, bound at apply.
# The "already authenticates" test cannot be made for a user that does not exist yet, so the change is planned
# and the apply sets the password and proves it by signing in.
sub _plan_password_after_create ($self, $plan, $row, $v, $login) {
    my $pw = $self->_secret( $v->{password_file}, 'password_file' );
    return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
    return $plan->add( bucket => 'password', action => 'custom', model => 'res.users', id_ref => 'user:' . lc $login, handler => $self->op_name,
        kind => 'password', key => "user:$login", login => $login, password_file => $v->{password_file}, calls => [ [ 'res.users', 'write' ] ],
        reason => 'sets the password from the file once the create row above has made the user; the value is not in the plan' );
}

sub _plan_create ($self, $plan, $row, $v, $login, $cur) {
    my $key  = "user:$login";
    my $kind = lc( _s( $v->{kind} ) // 'internal' );
    return _hold( $plan, 'invalid', $row, "kind must be internal or portal, got '$kind'" ) if $kind !~ /^(internal|portal)\z/;
    return _hold( $plan, 'exists', $row, "user '$cur->{login}' already exists (id $cur->{id})" ) if $cur;
    my $name = _s( $v->{name} );
    my @gx   = @{ _list( $v->{groups} ) };
    return _hold( $plan, 'invalid', $row, 'groups apply to internal users; a portal user is in the portal group' ) if $kind eq 'portal' && @gx;
    return _hold( $plan, 'invalid', $row, 'partner applies to a portal user' ) if $kind eq 'internal' && defined _s( $v->{partner} ) && _s( $v->{partner} ) ne '';

    my ( @gids, @unknown );
    for my $x (@gx) {
        my $id = $self->_group_id($x);
        defined $id ? push @gids, $id : push @unknown, $x;
    }
    return _hold( $plan, 'unknown-group', $row, 'unknown group ' . join( ', ', @unknown ) ) if @unknown;

    my $company;
    if ( defined( my $cn = _s( $v->{company} ) ) ) {
        if ( $cn ne '' ) {
            my $rows = $self->model('res.company')->search_read( [ [ 'name', '=', $cn ] ], ['id'] );
            return _hold( $plan, 'unknown-company', $row, "no company named '$cn'" ) if @$rows != 1;
            $company = $rows->[0]{id};
        }
    }
    my %extra = ( map { defined _s( $v->{$_} ) && _s( $v->{$_} ) ne '' ? ( $_ => _s( $v->{$_} ) ) : () } qw(lang tz) );

    if ( $kind eq 'internal' ) {
        return _hold( $plan, 'invalid', $row, 'create needs a name' ) if !defined $name || $name eq '';
        my $email = _s( $v->{email} );
        my $gf    = $self->{gfield};
        return $plan->add( bucket => 'create', action => 'create', model => 'res.users', key => $key, ref => 'user:' . lc $login, unique_by => { field => 'login', fold => 1 },
            vals => { login => $login, name => $name, %extra,
                ( defined $email && $email ne '' ? ( email => $email ) : () ),
                ( defined $company ? ( company_id => $company, company_ids => [ x2m_set( [$company] ) ] ) : () ),
                ( @gids ? ( $gf => [ x2m_set( \@gids ) ] ) : () ) },
            context  => { no_reset_password => JSON::PP::true },
            readback => [ 'login', 'name', 'share', $gf ] );
    }
    return $self->_plan_portal( $plan, $row, $v, $login, $name, $company, \%extra );
}

sub _plan_portal ($self, $plan, $row, $v, $login, $name, $company, $extra) {
    my $key = "user:$login";
    my ( $pid, $pemail, $pname );
    my $ps = _s( $v->{partner} );
    if ( defined $ps && $ps ne '' ) {
        my ( $f, $val ) = $ps =~ /^(\w+)=(.*)\z/s ? ( $1, $2 ) : $ps =~ /\@/ ? ( 'email', $ps ) : ( 'ref', $ps );
        my $pf = $self->model('res.partner')->fields;
        return _hold( $plan, 'unknown-partner', $row, "res.partner has no field '$f' to find '$ps' by" ) if !$pf->{$f};
        my $found = $self->model('res.partner')->search_read( [ [ $f, $f eq 'email' ? '=ilike' : '=', $val ] ], [ 'name', 'email' ] );
        return _hold( $plan, 'unknown-partner', $row, "no partner with $f '$val'" ) if !@$found;
        return _hold( $plan, 'ambiguous-partner', $row, "$f '$val' matches partners " . join( ', ', map { $_->{id} } @$found ) ) if @$found > 1;
        ( $pid, $pemail, $pname ) = ( $found->[0]{id}, _s( $found->[0]{email} ), $found->[0]{name} );
        my $uex = $self->model('res.users')->search( [ [ 'partner_id', '=', $pid ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ], limit => 1 );
        return _hold( $plan, 'exists', $row, "partner $pid already has a user (id $uex->[0])" ) if @$uex;
    }
    my $email = lc( ( defined $pemail && $pemail ne '' ? $pemail : undef ) // _s( $v->{email} ) // $login );
    $email =~ s/^.*<([^>]+)>.*\z/$1/;
    return _hold( $plan, 'no-email', $row, 'a portal user needs an email address (the partner\'s, the row\'s email, or a login that is one)' )
        if $email !~ /^[^@\s]+@[^@\s]+\.[^@\s]+\z/;
    return _hold( $plan, 'login-not-email', $row, "a portal login is the partner's email address; login '$login' is not '$email'" )
        if lc $login ne $email;
    my $pname_use = $name // $pname;
    return _hold( $plan, 'invalid', $row, 'create needs a name' ) if !defined $pid && ( !defined $pname_use || $pname_use eq '' );

    my $pref;
    if ( !defined $pid ) {
        $pref = 'partner:' . lc $login;
        $plan->add( bucket => 'new-partner', action => 'create', model => 'res.partner', key => $key, ref => $pref, support => 1,
            vals => { name => $pname_use, email => $email, ( defined $company ? ( company_id => $company ) : () ),
                ( $extra->{lang} ? ( lang => $extra->{lang} ) : () ) },
            context => { tracking_disable => JSON::PP::true, mail_create_nosubscribe => JSON::PP::true } );
    }
    my $partner = defined $pid ? $pid : { '$ref' => $pref };
    if ( !$self->{portal_wizard} ) {
        my $gid = $self->_group_id('base.group_portal');
        return _hold( $plan, 'unknown-group', $row, 'base.group_portal not found' ) if !defined $gid;
        return $plan->add( bucket => 'create', action => 'create', model => 'res.users', key => $key, ref => 'user:' . lc $login, unique_by => { field => 'login', fold => 1 },
            vals => { login => $login, name => $pname_use, partner_id => $partner, %$extra,
                ( defined $company ? ( company_id => $company, company_ids => [ x2m_set( [$company] ) ] ) : () ),
                $self->{gfield} => [ x2m_set( [$gid] ) ] },
            context  => { no_reset_password => JSON::PP::true },
            readback => [ 'login', 'name', 'share', $self->{gfield} ] );
    }
    return $plan->add( bucket => 'create', action => 'custom', model => 'res.users', handler => $self->op_name, kind => 'portal', key => $key, ref => 'user:' . lc $login,
        calls => [ ( map { [ 'res.users', $_ ] } qw(search write read) ), [ 'portal.wizard', 'create' ],
            ( map { [ 'portal.wizard.user', $_ ] } qw(search_read write action_grant_access) ) ],
        vals => { login => $login, email => $email, partner_id => $partner, %$extra },
        reason => 'portal.wizard grant access; Odoo sends the invitation email' );
}

# --- reset-take ---------------------------------------------------------------

# The default would name res.users, whose invariants are read around an apply
# with an authenticated call; this change makes none.
sub models_touched ($class, $change) {
    return () if ( $change->{kind} // '' ) eq 'reset-take';
    return grep { defined } $change->{model};
}

sub _plan_reset_take ($self, $plan, $row, $v) {
    my $key = 'reset-take';
    my ( $link, $token ) = ( _s( $v->{link} ), _s( $v->{token} ) );
    return _hold( $plan, 'invalid', $row, 'reset-take takes link (the URL) or token, not both and not neither' ) if defined $link == defined $token;
    my $pf = _s( $v->{password_file} );
    return _hold( $plan, 'invalid', $row, 'reset-take needs password_file (a 0600 file, or the path of one to make)' ) if !defined $pf || $pf eq '';

    my $config = $self->ctx->config;
    my ( $cfg_url, $cfg_db ) = ( $config->get('url') =~ s{/+\z}{}r, $config->get('db') );
    my ( $db, $tok ) = ( $cfg_db, $token );
    if ( defined $link ) {
        my $l = eval { Odoo::Ops::ResetForm->parse_link($link) };
        return _hold( $plan, 'invalid', $row, 'the link is not an http(s) URL (https://host/web/reset_password?db=...&token=...)' ) if !$l;
        return _hold( $plan, 'not-a-reset-form', $row, "the link is $l->{path}, not /web/reset_password"
                . ( $l->{path} =~ m{\A/web/signup} ? ': a signup link makes a user, a reset link sets a password for one that exists' : '' ) )
            if $l->{path} ne '/web/reset_password';
        return _hold( $plan, 'invalid', $row, 'the link carries no token' ) if !defined $l->{token} || $l->{token} eq '';
        return _hold( $plan, 'url-mismatch', $row, "the link is for $l->{url} and this config's url is $cfg_url" )
            if !Odoo::Ops::ResetForm->same_origin( $l->{url}, $cfg_url );
        $tok = $l->{token};
        $db  = $l->{db} if defined $l->{db} && $l->{db} ne '';
    }
    return _hold( $plan, 'db-mismatch', $row, "the link is for database $db and this config's database is $cfg_db" ) if $db ne $cfg_db;

    my $who = _s( $v->{login} );
    if ( -e $pf ) {
        my $pw = $self->_secret( $pf, 'password_file' );
        return _hold( $plan, 'password-file-missing', $row, $pw->{why} ) if !defined $pw->{secret};
    }
    else {
        ( my $dir = $pf ) =~ s{[^/]*\z}{};
        $dir = '.' if $dir eq '';
        return _hold( $plan, 'password-file-missing', $row, "password_file $pf does not exist and its directory $dir cannot be written" ) if !-d $dir || !-w $dir;
    }

    my $page = Odoo::Ops::ResetForm->read( $self->client->web_session, db => $db, token => $tok );
    my $p6   = Odoo::Ops::ResetForm->prefix($tok);
    return _hold( $plan, 'invalid-token', $row, 'Odoo says: ' . Odoo::Ops::ResetForm->scrub( $page->{error}, $tok )
            . " (token $p6): a link already used, expired or unknown reads this way; ask for a new one (core.user action=reset)" )
        if $page->{kind} eq 'invalid-token';
    return _hold( $plan, 'not-a-reset-form', $row, "the link does not open the password-reset form: $page->{what}" ) if $page->{kind} ne 'form';
    if ( !defined $page->{login} ) {
        # 19's reset form asks for the passwords alone; the login is the row's, and the sign-in after the post proves it
        return _hold( $plan, 'needs-login', $row, 'this form does not name the user (Odoo 19 asks for the passwords alone): give the login' ) if !defined $who;
        $page->{login} = $who;
        $page->{from_row} = 1;
    }
    return _hold( $plan, 'login-mismatch', $row, "the form names '$page->{login}' and the row says '$who'" ) if defined $who && lc $who ne lc $page->{login};

    my $series = $self->client->server_series;
    return $plan->add( bucket => 'reset-take', action => 'custom', model => 'res.users', handler => $self->op_name, kind => 'reset-take',
        calls => [],    # the reset page and a sign-in: no model call
        key => "reset-take:$page->{login}", login => $page->{login}, name => $page->{name}, db => $db, series => $series, login_from_row => $page->{from_row} ? 1 : 0,
        link => defined $link ? $link : undef, token => $tok, password_file => $pf,
        reason => "sets the password of '$page->{login}' ($page->{name}) on database $db (Odoo $series) through the reset page" . ( $page->{from_row} ? ' (the form does not name the user: the login is the row\'s)' : '' ) . ", token $p6; the password goes to $pf only and the link is consumed" );
}

sub _apply_reset_take ($class, $client, $c) {
    my ( $pf, $tok, $db, $login ) = @{$c}{qw(password_file token db login)};
    my $p6 = Odoo::Ops::ResetForm->prefix($tok);
    my $pw;
    if ( -e $pf ) { $pw = Odoo::Ops::Credential->secret_file( $pf, 'password_file' ) }
    else {
        # the file first: a password set with nowhere to keep it would lock the account
        $pw = _generate_password();
        sysopen( my $fh, $pf, O_WRONLY | O_CREAT | O_EXCL, 0600 )
            or Odoo::Error->throw( kind => 'usage', message => "cannot create password_file $pf: $!", fix => 'give a path this user can write, then plan again' );
        print {$fh} "$pw\n";
        close $fh or Odoo::Error->throw( kind => 'usage', message => "cannot write password_file $pf: $!" );
        my $back = Odoo::Ops::Credential->secret_file( $pf, 'password_file' );
        Odoo::Error->throw( kind => 'fault', message => "password_file $pf does not hold what was written" ) if $back ne $pw;
    }
    my $kept = "the password is in $pf, which stays; plan again to use it";

    my $web  = $client->web_session;
    my $page = Odoo::Ops::ResetForm->read( $web, db => $db, token => $tok );
    Odoo::Error->throw( kind => 'fault', message => 'Odoo says: ' . Odoo::Ops::ResetForm->scrub( $page->{error}, $tok ) . " (token $p6); $kept" )
        if $page->{kind} eq 'invalid-token';
    Odoo::Error->throw( kind => 'fault', message => "the link no longer opens the reset form: " . ( $page->{what} // $page->{kind} ) . "; $kept" ) if $page->{kind} ne 'form';
    Odoo::Error->throw( kind => 'fault', message => "the form now names '$page->{login}', not '$login'; $kept" ) if defined $page->{login} && lc $page->{login} ne lc $login;

    my $r = Odoo::Ops::ResetForm->submit( $web, $page, password => $pw, login => $login );
    Odoo::Error->throw( kind => 'fault', message => 'Odoo refused the reset: ' . Odoo::Ops::ResetForm->scrub( $r->{error}, $tok ) . " (token $p6); $kept" ) if !$r->{ok};

    # proved from a fresh client, as the consumer will use it
    my $as = $client->web_session;
    my $id = eval { Odoo::Transport::Session::require_signed_in( $as, $as->authenticate( $db, $login, $pw ) ) };
    if ( my $err = $@ ) {
        my $why = ref $err && $err->can('message') ? $err->message : "$err";
        $why = 'the password is right but the account has two-factor on, which opens no web session' if ref $err && $err->can('is_no_session') && $err->is_no_session;
        Odoo::Error->throw( kind => 'fault', message => "the reset was submitted and '$login' cannot sign in with the new password: $why; $kept" );
    }
    my $uid = $id->{uid};
    eval { $as->destroy };
    return { id => $uid, returned => { login => $login, db => $db, password_file => $pf, uid => $uid, token => $p6, verified => 1 },
        after => { verified => 1, uid => $uid } };
}

# 24 characters from a 64-character alphabet (a byte's low six bits, so no bias)
sub _generate_password () {
    open my $r, '<:raw', '/dev/urandom' or Odoo::Error->throw( kind => 'config', message => "cannot read /dev/urandom: $!" );
    read( $r, my $bytes, 24 ) == 24 or Odoo::Error->throw( kind => 'config', message => 'short read from /dev/urandom' );
    close $r;
    my @a = ( 'A' .. 'Z', 'a' .. 'z', 0 .. 9, '-', '_' );
    return join '', map { $a[ ord($_) & 63 ] } split //, $bytes;
}

# --- helpers --------------------------------------------------------------

# { secret } or { why }: a 0600 file's first line, said as a hold reason when unusable
sub _secret ($self, $path, $what) {
    return { why => "row names no $what" } if !defined $path || $path eq '';
    return { why => "$what $path does not exist" } if !-e $path;
    my $s = eval { Odoo::Ops::Credential->secret_file( $path, $what ) };
    return { why => ref $@ && $@->can('message') ? $@->message : "$@" } if !defined $s;
    return { secret => $s };
}

# does this secret authenticate this login as this user? a transport that
# cannot answer for another login (a web session) says no, never yes
sub _authenticates ($client, $login, $secret, $uid) {
    my $got = eval { $client->verify_credentials( $login, $secret ) };
    if ( my $err = $@ ) {
        die $err if ref $err && $err->isa('Odoo::Error') && $err->kind eq 'transport';
        return 0;
    }
    return defined $got && $got == $uid ? 1 : 0;
}

# Is this the user's password? RPC first; where that says no, the web login
# route, which is the only place a user with two-factor can be asked: it
# answers "accepted, no session" (Odoo::Error::is_no_session) for the right
# password and a credential fault for a wrong one, so the right password of
# a two-factor user is told from a wrong one.
sub _password_authenticates ($client, $login, $secret, $uid) {
    return 1 if _authenticates( $client, $login, $secret, $uid );
    my $web = eval { $client->web_session } or return 0;
    my $id  = eval { $web->authenticate( $client->db, $login, $secret ) };
    if ( my $err = $@ ) {
        return 0 if !( ref $err && $err->isa('Odoo::Error') );
        die $err if $err->kind eq 'transport';
        return $err->is_no_session ? 1 : 0;
    }
    eval { $web->destroy };
    # right password, two-factor on: the sign-in waits for a code
    return 1 if $id && $id->{pending};
    return $id && $id->{uid} == $uid ? 1 : 0;
}

# a group's id from its xml id; undef when there is none
sub _group_id ($self, $xmlid) {
    return $self->{group_cache}{$xmlid} if exists $self->{group_cache}{$xmlid};
    my ( $module, $name ) = split /\./, $xmlid, 2;
    my $id;
    if ( defined $name ) {
        my $rows = $self->model('ir.model.data')->search_read(
            [ [ 'module', '=', $module ], [ 'name', '=', $name ], [ 'model', '=', 'res.groups' ] ], ['res_id'] );
        $id = 0 + $rows->[0]{res_id} if @$rows == 1;
    }
    return $self->{group_cache}{$xmlid} = $id;
}

# --- apply of the custom changes --------------------------------------------

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    return $class->_apply_password( $client, $c ) if $kind eq 'password';
    return $class->_apply_portal( $client, $c )   if $kind eq 'portal';
    return $class->_apply_api_key( $client, $c )  if $kind eq 'api-key';
    return $class->_apply_totp( $client, $c )     if $kind eq 'totp';
    return $class->_apply_revoke( $client, $c )   if $kind eq 'api-key-revoke';
    return $class->_apply_reset_take( $client, $c ) if $kind eq 'reset-take';
    Odoo::Error->throw( kind => 'usage', message => "core.user cannot apply kind '$kind'" );
}

sub _apply_password ($class, $client, $c) {
    my $pw = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'password_file' );
    $client->model('res.users')->write( $c->{id}, { password => $pw } );
    my $ok = _password_authenticates( $client, $c->{login}, $pw, $c->{id} );
    return { id => $c->{id}, returned => { password_file => $c->{password_file}, verified => $ok ? 1 : 0 },
        after => ( $ok ? { verified => 1 } : undef ) };
}

sub _apply_portal ($class, $client, $c) {
    my $v      = $c->{vals};
    my $pid    = $v->{partner_id};
    my $users  = $client->model('res.users');
    my $gfield = $users->fields->{group_ids} ? 'group_ids' : 'groups_id';
    my $any    = [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ];
    my $uid;
    my $have = $users->search( [ [ 'partner_id', '=', $pid ], $any ], limit => 1 );
    if (@$have) {
        # a user made since planning (or by an earlier try): reuse it, as unique_by does
        $uid = $have->[0];
    }
    else {
        my $wid   = $client->model('portal.wizard')->create( { partner_ids => [ x2m_set( [$pid] ) ] } );
        my $lines = $client->model('portal.wizard.user');
        my $found = $lines->search_read( [ [ 'wizard_id', '=', $wid ], [ 'partner_id', '=', $pid ] ], ['email'] );
        Odoo::Error->throw( kind => 'fault', message => "the portal wizard made no line for partner $pid" ) if @$found != 1;
        my $lid = $found->[0]{id};
        $lines->write( $lid, { email => $v->{email} } ) if lc( $found->[0]{email} || '' ) ne lc $v->{email};
        $lines->call( 'action_grant_access', [ [$lid] ] );
        my $made = $users->search( [ [ 'partner_id', '=', $pid ], $any ], limit => 1 );
        Odoo::Error->throw( kind => 'fault', message => "the portal wizard granted access but no user exists for partner $pid" ) if !@$made;
        $uid = $made->[0];
    }
    my %more = map { defined $v->{$_} ? ( $_ => $v->{$_} ) : () } qw(lang tz);
    $users->write( $uid, \%more ) if %more;
    my $after = $users->read_one( $uid, [ 'login', 'name', 'share', 'active', $gfield ] );
    my $ok = lc( $after->{login} // '' ) eq lc $v->{login} && $after->{share};
    return { id => $uid, after => ( $ok ? $after : undef ) };
}

sub _apply_api_key ($class, $client, $c) {
    my $pw     = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'password_file' );
    my $login  = $c->{login};
    my $series = $client->server_series;

    # the key file first: a key minted with nowhere to put it would be lost
    sysopen( my $fh, $c->{key_file}, O_WRONLY | O_CREAT | O_EXCL, 0600 )
        or Odoo::Error->throw( kind => 'usage', message => "cannot create key_file $c->{key_file}: $!", fix => 'give a path this user can write (dir, out or name), then plan again' );
    my $key = eval { $class->_mint( $client, $login, $pw, $series, $c ) };
    my $err = $@;
    if ( !defined $key ) {
        close $fh;
        unlink $c->{key_file};
        die $err if $err;
        Odoo::Error->throw( kind => 'fault', message => "Odoo made no key for '$login'" );
    }
    print {$fh} "$key\n";
    close $fh or Odoo::Error->throw( kind => 'usage', message => "cannot write key_file $c->{key_file}: $!", fix => 'give a path this user can write (dir, out or name), then plan again' );
    my $ok = _authenticates( $client, $login, $key, $c->{id} );
    return { id => $c->{id}, returned => { key_file => $c->{key_file}, verified => $ok ? 1 : 0 },
        after => ( $ok ? { verified => 1 } : undef ) };
}

# The key as Odoo's own screen mints it: the wizard res.users.apikeys.description
# and its make_key, which asks for the identity check (res.users.identitycheck,
# run_check) unless this session passed one in the last ten minutes. It runs over a
# web session as the user, because the check and the key belong to the session's user.
sub _mint ($class, $client, $login, $pw, $series, $c) {
    my $web = $client->web_session;
    Odoo::Transport::Session::require_signed_in( $web, $web->authenticate( $client->db, $login, $pw ) );
    my $guard = $client->transport;
    my $t     = $guard->can('derive') ? $guard->derive( $web, login => $login ) : $web;
    my $as    = Odoo::Client->new( url => $client->url, db => $client->db, transport => $t, retries => [0] );
    my $key   = eval {
        my $desc = $as->model('res.users.apikeys.description');
        my %vals = ( name => $c->{description} // 'oom' );
        $vals{duration} = $c->{duration} if defined $c->{duration} && $desc->fields->{duration};
        my $wid = $desc->create( \%vals );
        my $act = $desc->call( 'make_key', [ [$wid] ] );
        my $k   = _key_of($act);
        if ( !defined $k ) {
            Odoo::Error->throw( kind => 'fault', message => 'make_key did not ask for the identity check or give a key' )
                if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'res.users.identitycheck';
            my $chk = $as->model('res.users.identitycheck');
            # 16, 17, 18 read the password from the wizard's field; 19 from the context
            $chk->write( $act->{res_id}, { password => $pw } ) if $series < 19;
            $act = $chk->call( 'run_check', [ [ $act->{res_id} ] ], ( $series >= 19 ? ( context => { password => $pw } ) : () ) );
            $k = _key_of($act);
        }
        $k;
    };
    my $err = $@;
    eval { $web->destroy };
    die $err if $err;
    return $key;
}

# --- revoking keys ------------------------------------------------------------

sub _apply_revoke ($class, $client, $c) {
    my $pw     = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'password_file' );
    my $series = $client->server_series;
    my ( $as, $web ) = $class->_as_user( $client, $c->{login}, $pw );
    eval {
        my $keys = $as->model('res.users.apikeys');
        my $act  = $keys->call( 'remove', [ $c->{key_ids} ] );
        $class->_identity_check( $as, $act, $pw, $series );
    };
    my $err = $@;
    eval { $web->destroy };
    die $err if $err;
    my $left = $client->model('res.users.apikeys')->search_read( [ [ 'id', 'in', $c->{key_ids} ] ], ['name'] );
    return { id => $c->{id}, returned => { revoked => $c->{key_ids}, verified => @$left ? 0 : 1 },
        after => ( @$left ? undef : { revoked => scalar @{ $c->{key_ids} } } ) };
}

# --- two-factor ---------------------------------------------------------------

sub _apply_totp ($class, $client, $c) {
    $c->{two_factor} eq 'on' ? $class->_totp_on( $client, $c ) : $class->_totp_off( $client, $c );
    my $now = $client->model('res.users')->read_one( $c->{id}, ['totp_enabled'] )->{totp_enabled} ? 1 : 0;
    my $want = $c->{two_factor} eq 'on' ? 1 : 0;
    return { id => $c->{id}, returned => { two_factor => $c->{two_factor}, verified => $now == $want ? 1 : 0 },
        after => ( $now == $want ? { totp_enabled => $now } : undef ) };
}

# On, as the user: the wizard a person opens from their preferences. The
# secret exists in this sub only.
sub _totp_on ($class, $client, $c) {
    my $pw     = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'password_file' );
    my $series = $client->server_series;
    my ( $as, $web ) = $class->_as_user( $client, $c->{login}, $pw );
    eval {
        my $act = $as->model('res.users')->call( 'action_totp_enable_wizard', [ [ $c->{id} ] ] );
        $act = $class->_identity_check( $as, $act, $pw, $series );
        Odoo::Error->throw( kind => 'fault', message => "Odoo gave no two-factor wizard for '$c->{login}'" )
            if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'auth_totp.wizard' || !$act->{res_id};
        my $wm     = $as->model('auth_totp.wizard');
        my $secret = $wm->read_one( $act->{res_id}, ['secret'] )->{secret};
        Odoo::Error->throw( kind => 'fault', message => 'the two-factor wizard showed no secret' ) if !$secret;
        my $code = Odoo::Ops::Totp->code($secret);
        # 16 to 18 read the code from the wizard's field; 19 from the context
        if ( $series < 19 ) {
            $wm->write( $act->{res_id}, { code => $code } );
            $wm->call( 'enable', [ [ $act->{res_id} ] ] );
        }
        else {
            $wm->call( 'enable', [ [ $act->{res_id} ] ], context => { code => $code } );
        }
    };
    my $err = $@;
    eval { $web->destroy };
    die $err if $err;
}

# Off, as the connection: a user with two-factor on cannot open a password
# session, and Odoo lets an administrator disable it. Over the administrator's
# own web session, with the connection's secret (its password) where the
# identity check asks for one.
sub _totp_off ($class, $client, $c) {
    my $series = $client->server_series;
    my $web    = eval { $client->own_web_session };
    if ( my $e = $@ ) {
        Odoo::Error->throw( kind => 'fault', fault_class => $e->fault_class,
            message => 'turning two-factor off needs a web session as the connection (its secret as the password); '
                . 'a real API key does not open one: ' . $e->message )
            if ref $e && $e->isa('Odoo::Error') && $e->is_invalid_credential;
        die $e;
    }
    my $guard  = $client->transport;
    my $t      = $guard->can('derive') ? $guard->derive( $web, login => $client->login ) : $web;
    my $as     = Odoo::Client->new( url => $client->url, db => $client->db, transport => $t, retries => [0] );
    eval {
        my $act = $as->model('res.users')->call( 'action_totp_disable', [ [ $c->{id} ] ] );
        $class->_identity_check( $as, $act, $client->own_secret, $series );
    };
    my $err = $@;
    eval { $web->destroy };
    die $err if $err;
}

# a session as the user, held to the same scope and audit as the connection
sub _as_user ($class, $client, $login, $pw) {
    my $web = $client->web_session;
    Odoo::Transport::Session::require_signed_in( $web, $web->authenticate( $client->db, $login, $pw ) );
    my $guard = $client->transport;
    my $t     = $guard->can('derive') ? $guard->derive( $web, login => $login ) : $web;
    return ( Odoo::Client->new( url => $client->url, db => $client->db, transport => $t, retries => [0] ), $web );
}

# Odoo answers a method that wants the identity checked with the check
# wizard; run it with the password and what it runs comes back. Any other
# answer is passed through (the check was already done on this session).
sub _identity_check ($class, $as, $act, $pw, $series) {
    return $act if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'res.users.identitycheck';
    my $chk = $as->model('res.users.identitycheck');
    # 16, 17, 18 read the password from the wizard's field; 19 from the context
    $chk->write( $act->{res_id}, { password => $pw } ) if $series < 19;
    return $chk->call( 'run_check', [ [ $act->{res_id} ] ], ( $series >= 19 ? ( context => { password => $pw } ) : () ) );
}

# the key out of the action Odoo answers with ("API Key Ready"), else undef
sub _key_of ($act) {
    return undef if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'res.users.apikeys.show';
    return $act->{context}{default_key};
}

1;

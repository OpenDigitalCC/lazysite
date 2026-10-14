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
use Odoo::Ops::Rows;

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
    deactivate / activate
    groups       add and remove: lists of group xml ids.

A row is a flat map (as for L<Odoo::Ops::Core::Import>): C<records>
in-process, or C<rows> as a C<.jsonl>, C<.json> or C<.csv> file (lists
in a cell are separated by C<;> or C<,>). No password is ever a row
value.

Every row lands in one bucket: C<create>, C<password>, C<reset>,
C<api-key>, C<deactivate>, C<activate>, C<groups>, C<unchanged>, or a
hold named for the reason: C<unknown-user>, C<exists>,
C<unknown-group>, C<unknown-partner>, C<ambiguous-partner>,
C<unknown-company>, C<no-email>, C<login-not-email>,
C<password-file-missing>, C<not-internal>, C<key-file-exists>,
C<invalid>, C<held-flag>.

A re-run is quiet: a password that already authenticates and a key file
whose key already authenticates are C<unchanged>.

Rows are planned independently of each other: a user created in this
file is not yet there for a later row of the same file to act on;
plan again after the apply.

=cut

sub op_name ($class) { 'core.user' }
sub summary ($class) { 'Create, secure and manage users and portal users through Odoo\'s own flows' }
sub pack    ($class) { undef }
sub params ($class) {
    {   records => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
        rows    => { type => 'path', help => 'rows file: .jsonl, .json (a list) or .csv; one row per user with an action' },
    };
}

# the models a row can touch are known; the apply scope is therefore fixed
sub read_scope ($class) {
    {   'res.users'       => [qw(search search_read)],
        'res.partner'     => ['search_read'],
        'res.company'     => ['search_read'],
        'ir.model.data'   => ['search_read'],
    };
}

sub write_scope ($class) {
    {   'res.users'      => [qw(create write search action_reset_password)],
        'res.partner'    => [qw(create search_read)],
        'portal.wizard'      => [qw(create)],
        'portal.wizard.user' => [qw(search_read write action_grant_access)],
        'res.users.apikeys.description' => [qw(create make_key)],
        'res.users.identitycheck'       => [qw(write run_check)],
    };
}

my %ACTION = map { $_ => 1 } qw(create password reset api-key deactivate activate groups);

sub plan ($self) {
    my @in = grep { defined $self->param($_) } qw(records rows);
    Odoo::Error->throw( kind => 'usage', message => 'core.user: give exactly one of records, rows (got ' . ( @in ? "@in" : 'none' ) . ')' )
        if @in != 1;
    my $rows = Odoo::Ops::Rows->load( 'core.user', map { $_ => $self->param($_) } @in );

    my $users  = $self->model('res.users');
    my $gfield = $users->fields->{group_ids} ? 'group_ids' : 'groups_id';
    $self->{gfield} = $gfield;
    $self->{portal_wizard} = eval { $self->model('portal.wizard')->fields; $self->model('portal.wizard.user')->fields; 1 } ? 1 : 0;

    # one read of every login named, archived included; matched exactly (no case) here
    my %logins = map { lc( _s( $_->{values}{login} ) // '' ) => 1 } @$rows;
    delete $logins{''};
    my %have;
    if (%logins) {
        my @terms  = map { [ 'login', '=ilike', $_ ] } sort keys %logins;
        my @domain = ( ('|') x ( @terms - 1 ), @terms );
        my $found  = $users->search_read( [ @domain, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [ 'login', 'name', 'active', 'share', 'email', 'partner_id', $gfield ] );
        $have{ lc $_->{login} } = $_ for @$found;
    }

    my $plan = $self->new_plan( input_count => scalar @$rows );
    $plan->note( 'core.user: ' . scalar(@$rows) . ' rows; ' . ( $self->{portal_wizard} ? 'portal users through the portal wizard' : 'no portal wizard on this instance: portal users are created directly with the portal group' ) );
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
    my $login = _s( $v->{login} );
    return _hold( $plan, 'invalid', $row, 'row has no login' ) if !defined $login || $login eq '';

    my $cur = $have->{ lc $login };
    if ( $action eq 'create' ) {
        return _hold( $plan, 'exists', $row, "an earlier row of this file creates '$login'" ) if !$cur && $self->{creating}{ lc $login }++;
        return $self->_plan_create( $plan, $row, $v, $login, $cur );
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
            if _authenticates( $self->client, $login, $pw->{secret}, $cur->{id} );
        return $plan->add( bucket => 'password', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
            kind => 'password', key => $key, login => $cur->{login}, password_file => $v->{password_file},
            reason => 'sets the password from the file; the value is not in the plan' );
    }
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
    my $dur = _s( $v->{duration} );
    return _hold( $plan, 'invalid', $row, "duration '$dur' is not a number of days" ) if defined $dur && $dur ne '' && $dur !~ /^-?\d+\z/;
    return $plan->add( bucket => 'api-key', action => 'custom', model => 'res.users', id => $cur->{id}, handler => $self->op_name,
        kind => 'api-key', key => $key, login => $cur->{login}, password_file => $v->{password_file}, key_file => $kf,
        description => _s( $v->{name} ) // 'oom', ( defined $dur && $dur ne '' ? ( duration => $dur ) : () ),
        reason => 'mints a key as the user over a web session; the key goes to key_file only' );
}

# --- create ---------------------------------------------------------------

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
        return $plan->add( bucket => 'create', action => 'create', model => 'res.users', key => $key, unique_by => 'login',
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
        return $plan->add( bucket => 'create', action => 'create', model => 'res.users', key => $key, unique_by => 'login',
            vals => { login => $login, name => $pname_use, partner_id => $partner, %$extra,
                ( defined $company ? ( company_id => $company, company_ids => [ x2m_set( [$company] ) ] ) : () ),
                $self->{gfield} => [ x2m_set( [$gid] ) ] },
            context  => { no_reset_password => JSON::PP::true },
            readback => [ 'login', 'name', 'share', $self->{gfield} ] );
    }
    return $plan->add( bucket => 'create', action => 'custom', model => 'res.users', handler => $self->op_name, kind => 'portal', key => $key,
        vals => { login => $login, email => $email, partner_id => $partner, %$extra },
        reason => 'portal.wizard grant access; Odoo sends the invitation email' );
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
    Odoo::Error->throw( kind => 'usage', message => "core.user cannot apply kind '$kind'" );
}

sub _apply_password ($class, $client, $c) {
    my $pw = Odoo::Ops::Credential->secret_file( $c->{password_file}, 'password_file' );
    $client->model('res.users')->write( $c->{id}, { password => $pw } );
    my $ok = _authenticates( $client, $c->{login}, $pw, $c->{id} );
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
        or Odoo::Error->throw( kind => 'config', message => "cannot create key_file $c->{key_file}: $!" );
    my $key = eval { $class->_mint( $client, $login, $pw, $series, $c ) };
    my $err = $@;
    if ( !defined $key ) {
        close $fh;
        unlink $c->{key_file};
        die $err if $err;
        Odoo::Error->throw( kind => 'fault', message => "Odoo made no key for '$login'" );
    }
    print {$fh} "$key\n";
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write key_file $c->{key_file}: $!" );
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
    $web->authenticate( $client->db, $login, $pw );
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

# the key out of the action Odoo answers with ("API Key Ready"), else undef
sub _key_of ($act) {
    return undef if ref $act ne 'HASH' || ( $act->{res_model} // '' ) ne 'res.users.apikeys.show';
    return $act->{context}{default_key};
}

1;

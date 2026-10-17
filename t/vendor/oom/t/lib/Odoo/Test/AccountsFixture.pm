package Odoo::Test::AccountsFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter 'import';
our @EXPORT_OK = qw(make_instance ctx_for);

use File::Temp qw(tempdir);
use JSON::PP ();

use Odoo::Client;
use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Totp;
use Odoo::Test::FakeOdoo;

# An instance for the accounts tests: users and groups, the portal wizard
# is left out (internal accounts only), the identity-check wizard that
# guards the sensitive methods, API keys as rows (with an expiry on 18 and
# up), and auth_totp's enable wizard and disable action. The administrator
# is login 'tester' with key 'k'. Secrets are checked the way Odoo checks
# them: a user with two-factor on opens no web session and cannot RPC by
# password, an archived user cannot authenticate at all.

my $c = sub { { type => 'char', store => 1 } };

sub fields_for ($series) {
    my $g = $series >= 19 ? 'group_ids' : 'groups_id';
    return (
        'res.users' => { login => $c->(), name => $c->(), email => $c->(), lang => $c->(), tz => $c->(), password => $c->(),
            active => { type => 'boolean' }, share => { type => 'boolean' }, totp_enabled => { type => 'boolean' },
            partner_id => { type => 'many2one', relation => 'res.partner' }, company_id => { type => 'many2one', relation => 'res.company' },
            company_ids => { type => 'many2many', relation => 'res.company' }, $g => { type => 'many2many', relation => 'res.groups' } },
        'res.groups'    => { name => $c->(), full_name => $c->(), display_name => $c->(), implied_ids => { type => 'many2many', relation => 'res.groups' },
            ( $series >= 19 ? ( privilege_id => { type => 'many2one', relation => 'res.groups.privilege' } )
                            : ( category_id => { type => 'many2one', relation => 'ir.module.category' } ) ) },
        'ir.module.category' => { name => $c->() },
        ( $series >= 19 ? ( 'res.groups.privilege' => { name => $c->(), category_id => { type => 'many2one', relation => 'ir.module.category' } } ) : () ),
        'ir.model'        => { model => $c->(), name => $c->() },
        'ir.model.access' => { name => $c->(), model_id => { type => 'many2one', relation => 'ir.model' }, group_id => { type => 'many2one', relation => 'res.groups' },
            active => { type => 'boolean' }, map { ( "perm_$_" => { type => 'boolean' } ) } qw(read create write unlink) },
        'ir.rule' => { name => $c->(), model_id => { type => 'many2one', relation => 'ir.model' }, domain_force => $c->(),
            groups => { type => 'many2many', relation => 'res.groups' }, active => { type => 'boolean' },
            map { ( "perm_$_" => { type => 'boolean' } ) } qw(read create write unlink) },
        'sale.order'      => { name => $c->(), state => $c->(), create_uid => { type => 'many2one', relation => 'res.users' } },
        'sale.order.line' => { name => $c->(), order_id => { type => 'many2one', relation => 'sale.order' } },
        'product.product' => { name => $c->() },
        'product.template' => { name => $c->() },
        'ir.model.data' => { module => $c->(), name => $c->(), model => $c->(), res_id => { type => 'integer' }, noupdate => { type => 'boolean' } },
        'res.partner'   => { name => $c->(), email => $c->() },
        'res.company'   => { name => $c->() },
        'res.users.apikeys' => { name => $c->(), scope => $c->(), create_date => $c->(), user_id => { type => 'many2one', relation => 'res.users' },
            ( $series >= 18 ? ( expiration_date => $c->() ) : () ) },
        'res.users.apikeys.description' => { name => $c->(), duration => $c->() },
        'res.users.identitycheck'       => { password => $c->() },
        'auth_totp.wizard' => { user_id => { type => 'many2one', relation => 'res.users' }, secret => $c->(), code => $c->() },
    );
}

my @B32 = ( 'A' .. 'Z', 2 .. 7 );

sub make_instance ($series = 16, %opt) {
    my $g = $series >= 19 ? 'group_ids' : 'groups_id';
    my $f = Odoo::Test::FakeOdoo->new(
        series  => $series,
        fields  => { fields_for($series) },
        secrets => { tester => 'k' },
        records => {
            'res.partner' => [ { id => 8, name => 'Tester', email => 'tester@acme.example' } ],
            'res.company' => [ { id => 1, name => 'My Company' } ],
            'res.groups'  => [
                { id => 10, name => 'Internal User', full_name => 'User types / Internal User' },
                { id => 11, name => 'Settings',      full_name => 'Administration / Settings' },
                { id => 12, name => 'Portal',        full_name => 'User types / Portal' },
                { id => 13, name => 'User: Own Documents Only', full_name => 'Sales / User: Own Documents Only' },
            ],
            'ir.model' => [ map { +{ id => $_->[0], model => $_->[1], name => $_->[1] } }
                [ 1, 'product.product' ], [ 2, 'product.template' ], [ 3, 'sale.order' ], [ 4, 'sale.order.line' ], [ 5, 'res.partner' ] ],
            'ir.model.data' => [
                { module => 'base',       name => 'group_user',   model => 'res.groups', res_id => 10 },
                { module => 'base',       name => 'group_system', model => 'res.groups', res_id => 11 },
                { module => 'base',       name => 'group_portal', model => 'res.groups', res_id => 12 },
                { module => 'sales_team', name => 'group_sale_salesman', model => 'res.groups', res_id => 13 },
            ],
            'res.users' => [
                { id => 2, login => 'tester', name => 'Tester', email => 'tester@acme.example', partner_id => 8, share => 0, $g => [ 10, 11 ] },
                ( $opt{portal} ? { id => 20, login => 'portal@acme.example', name => 'Portal Pia', partner_id => 8, share => 1, $g => [12] } : () ),
            ],
        },
    );
    $f->{pw}{'portal@acme.example'} = 'portal-pw' if $opt{portal};
    $f->{keys}{tester}{k} = 1;

    # a method Odoo guards with the identity check: asked without the check done on
    # this session, it answers the check wizard; run_check runs it
    my $guarded = sub ($impl) {
        return sub ( $fk, $args, $kw ) {
            my $user = $fk->{session_user};
            die "fake: this method can only be accessed over HTTP\n" if !defined $user;
            return $impl->( $fk, $args, $kw, $user ) if $fk->{idchecked}{$user};
            my $id = $fk->_create( 'res.users.identitycheck', {} );
            $fk->{pending}{$id} = [ $impl, $args, $kw ];
            return { type => 'ir.actions.act_window', res_model => 'res.users.identitycheck', res_id => $id };
        };
    };
    $f->{methods}{'res.users.identitycheck.run_check'} = sub ( $fk, $args, $kw ) {
        my $id   = $args->[0][0];
        my $pw   = $series >= 19 ? $kw->{context}{password} : $fk->record( 'res.users.identitycheck', $id )->{password};
        my $user = $fk->{session_user};
        die "wrong password\n" if ( $fk->password_of($user) // '' ) ne ( $pw // '' );
        $fk->{idchecked}{$user} = 1;
        my ( $impl, $pargs, $pkw ) = @{ delete $fk->{pending}{$id} };
        return $impl->( $fk, $pargs, $pkw, $user );
    };

    # API keys
    my $user_row = sub ( $fk, $login ) { ( grep { $_->{login} eq $login } map { $fk->record( 'res.users', $_ ) } @{ $fk->all_ids('res.users') } )[0] };
    $f->{methods}{'res.users.apikeys.description.make_key'} = $guarded->( sub ( $fk, $args, $kw, $user ) {
        my $d    = $fk->record( 'res.users.apikeys.description', $args->[0][0] );
        my $days = $d->{duration};
        die "fake: You cannot exceed 90.0 days\n" if $series >= 19 && defined $days && $days > 90;
        my $key = 'KEY-' . $user . '-' . ++$fk->{key_n};
        $fk->add_key( $user, $key );
        my $row = $fk->_create( 'res.users.apikeys', { name => $d->{name}, user_id => $user_row->( $fk, $user )->{id},
            ( $series >= 18 ? ( expiration_date => defined $days ? '2027-01-11 00:00:00' : 0 ) : () ) } );
        $fk->record( 'res.users.apikeys', $row )->{_key} = $key;
        return { type => 'ir.actions.act_window', res_model => 'res.users.apikeys.show', context => { default_key => $key } };
    } );
    $f->{methods}{'res.users.apikeys.remove'} = $guarded->( sub ( $fk, $args, $kw, $user ) {
        for my $id ( @{ $args->[0] } ) {
            my $row = $fk->record( 'res.users.apikeys', $id ) or next;
            my $owner = $fk->record( 'res.users', $row->{user_id} );
            die "fake: You can not remove API keys unless they're yours\n" if $owner->{login} ne $user;
            delete $fk->{keys}{ $owner->{login} }{ $row->{_key} };
            delete $fk->{data}{'res.users.apikeys'}{$id};
        }
        return { type => 'ir.actions.act_window_close' };
    } );

    # two-factor
    $f->{methods}{'res.users.action_totp_enable_wizard'} = $guarded->( sub ( $fk, $args, $kw, $user ) {
        my $me = $user_row->( $fk, $user );
        die "fake: Two-factor authentication can only be enabled for yourself\n" if $args->[0][0] != $me->{id};
        die "fake: Two-factor authentication already enabled\n" if $me->{totp_enabled};
        my $raw = join '', map { $B32[ int rand 32 ] } 1 .. 32;
        my $w = $fk->_create( 'auth_totp.wizard', { user_id => $me->{id}, secret => join( ' ', $raw =~ /(.{4})/g ) } );
        return { type => 'ir.actions.act_window', res_model => 'auth_totp.wizard', res_id => $w };
    } );
    $f->{methods}{'auth_totp.wizard.enable'} = $guarded->( sub ( $fk, $args, $kw, $user ) {
        my $w    = $fk->record( 'auth_totp.wizard', $args->[0][0] );
        my $code = $series >= 19 ? ( $kw->{context}{code} // '' ) : ( $w->{code} // '' );
        ( my $secret = $w->{secret} ) =~ s/\s//g;
        die "fake: Verification failed, please double-check the 6-digit code\n"
            if !grep { Odoo::Ops::Totp->code( $secret, offset => $_ ) eq $code } ( -1, 0, 1 );
        $user_row->( $fk, $user )->{totp_enabled} = 1;
        $fk->{totp_secret_for}{$user} = $secret;
        $w->{secret} = '';
        return { type => 'ir.actions.client', tag => 'display_notification' };
    } );
    $f->{methods}{'res.users.action_totp_disable'} = $guarded->( sub ( $fk, $args, $kw, $user ) {
        for my $id ( @{ $args->[0] } ) {
            my $row = $fk->record( 'res.users', $id );
            die "fake: not yours to disable\n" if $row->{login} ne $user && $user ne 'tester';
            $row->{totp_enabled} = 0;
        }
        return { type => 'ir.actions.client', tag => 'display_notification' };
    } );

    # rights: the sales group reads products and edits quotations; no group reads nothing
    my %table = (
        'product.product'  => { read => 1 },
        'sale.order'       => { read => 1, create => 1, write => 1 },
        'sale.order.line'  => { read => 1, create => 1, write => 1, unlink => 1 },
        'res.partner'      => { read => 1, create => 1, write => 1 },
    );
    # a user holding a role group (an __oom__ xml id) has what the access rows of its groups
    # and the groups they imply say; otherwise the table above
    my $role_groups = sub ($fk) { map { $_->{res_id} } grep { $_->{module} eq '__oom__' && $_->{model} eq 'res.groups' } map { $fk->record( 'ir.model.data', $_ ) } @{ $fk->all_ids('ir.model.data') } };
    my $closure = sub ($fk, @gids) {
        my %set = map { $_ => 1 } @gids;
        my @todo = @gids;
        while ( defined( my $x = shift @todo ) ) {
            my $grp = $fk->record( 'res.groups', $x ) or next;
            for my $i ( @{ $grp->{implied_ids} // [] } ) { push @todo, $i if !$set{$i}++ }
        }
        return %set;
    };
    for my $m ( keys %table, qw(res.users ir.rule product.template) ) {
        $f->{methods}{"$m.check_access_rights"} = sub ( $fk, $args, $kw ) {
            my $u = $fk->record( 'res.users', $fk->{caller_uid} // $fk->{session_user_id} // 0 );
            my $groups = $u ? $u->{$g} // [] : [];
            my %set = $closure->( $fk, @$groups );
            if ( grep { $set{$_} } $role_groups->($fk) ) {
                my ($mid) = map { $_->{id} } grep { $_->{model} eq $m } map { $fk->record( 'ir.model', $_ ) } @{ $fk->all_ids('ir.model') };
                return 0 if !$mid;
                for my $aid ( @{ $fk->all_ids('ir.model.access') } ) {
                    my $row = $fk->record( 'ir.model.access', $aid );
                    next if !$row->{active} || !$set{ $row->{group_id} // 0 } || ( $row->{model_id} // 0 ) != $mid;
                    return 1 if $row->{"perm_$kw->{operation}"};
                }
                return 0;
            }
            return 0 if !$table{$m} || !grep { $_ == 13 || $_ == 11 } @$groups;
            return $table{$m}{ $kw->{operation} } ? 1 : 0;
        };
    }
    # a deleted record takes its xml id with it, as Odoo does
    for my $m ( 'res.groups', 'ir.model.access', 'ir.rule', 'ir.module.category', 'res.groups.privilege' ) {
        next if !$f->{fields}{$m};
        $f->{methods}{"$m.unlink"} = sub ( $fk, $args, $kw ) {
            for my $id ( @{ $args->[0] } ) {
                delete $fk->{data}{$m}{$id};
                for my $d ( map { $fk->record( 'ir.model.data', $_ ) } @{ $fk->all_ids('ir.model.data') } ) {
                    delete $fk->{data}{'ir.model.data'}{ $d->{id} } if $d->{model} eq $m && $d->{res_id} == $id;
                }
            }
            return 1;
        };
    }
    $f->{methods}{'ir.module.category.check_access_rights'} = sub { $opt{deny_category} ? 0 : 1 };
    $f->{methods}{'res.users.has_group'} = sub ( $fk, $args, $kw ) {
        my $u = $fk->record( 'res.users', $fk->{caller_uid} // 0 );
        return ( $u && grep { $_ == 11 } @{ $u->{$g} // [] } ) ? 1 : 0;
    };
    return $f;
}

# a context for the accounts library: the administrator on the fake, writes
# allowed, the approval gate left on
sub ctx_for ($fake, $runs, %conf) {
    return Odoo::Ops::Context->new(
        config => Odoo::Ops::Config->new( url => 'https://odoo.example', db => 'd', login => 'tester', runs_dir => $runs, allow_writes => 1, %conf ),
        credential => { login => 'tester', api_key => 'k' }, transport => $fake, retries => [0] );
}

1;

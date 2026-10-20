package Odoo::Tools::Accounts;

use strict;
use warnings;
use feature qw(signatures say);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp ();
use File::Spec;
use JSON::PP ();
use Odoo::JSON ();
use MIME::Base64 ();
use Scalar::Util qw(blessed);
use YAML::PP ();

use Odoo::Client;
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Credential;
use Odoo::Ops::Core::Access;
use Odoo::Ops::Core::User;
use Odoo::Ops::Journal;
use Odoo::Ops::Plan;
use Odoo::Ops::ResetForm;
use Odoo::Ops::Runner;
use Odoo::Ops::Runs;

our $VERSION = '0.38';

=head1 NAME

Odoo::Tools::Accounts - the accounts an instance should hold, provisioned, proved, rotated and handed over

=head1 SYNOPSIS

    my $acc = Odoo::Tools::Accounts->new( conf => 'ops.conf', file => 'accounts.yaml' );
    $acc->provision;      # roles, then create, password, key, two-factor, active: each stage a plan, approved, applied
    $acc->upgrade;        # the same: the file applied again brings roles and accounts to it
    $acc->probe;          # what each account can do, from the consumer's side
    $acc->rotate( login => 'svc@oom.example', api_key => 1 );
    $acc->handover( for => 'lazysite', out => 'handover.md' );
    $acc->list;

=head1 DESCRIPTION

The library behind C<oom-accounts>. One YAML file describes the accounts
an instance should hold:

    secrets_dir: /srv/projects/oom/tmp/site      # 0700; <login>.<kind> files, 0600
    models: [product.product, sale.order]        # what probe checks rights on
    roles: [roles/]                              # role files (or directories of them): see Odoo::Ops::Core::Access
    accounts:
      - login: svc@oom.example
        name: Service connection
        kind: internal                           # internal (default) | portal
        role: lazysite-connection                # one role of the files above: its group joins the account's groups
        groups: [sales_team.group_sale_salesman]
        password: generate                       # generate | keep | file:<path>
        api_key: { name: connection key, duration: 90 }
        two_factor: on                           # on | off
        active: true                             # default true

Every change to Odoo is a L<Odoo::Ops::Core::Access> (the roles) or
L<Odoo::Ops::Core::User> (the accounts) plan. Each stage is
printed (buckets, held rows with their reasons) and confirmed before
anything is written (C<yes> skips the question), recorded as approved by
the actor in the runs registry with L<Odoo::Ops::Runs/approve_plan> and
applied by L<Odoo::Ops::Runner>; the config's C<approval = required>
gate is never turned off. No secret is printed or put in a plan or a
journal; secrets live in files under C<secrets_dir> named by login and
kind: C<< <login>.password >>, C<< <login>.key >>.

A generated password file is written when the stage is planned (the plan
names the file, never the value) and stays if the stage is declined;
the next run finds it and uses it.

=head1 METHODS

=head2 new(%args)

C<conf> (an ops config path) or C<config>; C<file> (the accounts file) or
C<spec> (the parsed file); C<yes> (do not ask); C<out> and C<err>
(handles, default STDOUT and STDERR); C<confirm> (a code ref given the
question, answering true to go on); C<context> (a code ref returning a
fresh L<Odoo::Ops::Context>, for a program or a test); C<client_for> (a
code ref given a login and a key file, returning a client connected by
that key).

=cut

sub new ($class, %a) {
    my $spec = $a{spec};
    if ( !$spec ) {
        my $file = $a{file} or Odoo::Error->throw( kind => 'usage', message => 'oom-accounts needs the accounts file (--accounts F)' );
        $spec = $class->load_file($file);
        $spec->{_file} = $file;
    }
    my $config = $a{config} // ( defined $a{conf} ? Odoo::Ops::Config->load( $a{conf} )
        : Odoo::Error->throw( kind => 'usage', message => 'oom-accounts needs the ops config (--conf C)' ) );
    my $self = bless {
        spec    => $spec,
        config  => $config,
        yes     => $a{yes},
        out     => $a{out} // \*STDOUT,
        err     => $a{err} // \*STDERR,
        confirm => $a{confirm},
        context => $a{context} // sub { Odoo::Ops::Context->new( config => $config ) },
        client_for => $a{client_for},
        now     => $a{now} // sub { time },
    }, $class;
    $self->_secrets_dir;    # refuse a loose directory before anything else
    return $self;
}

=head2 load_file($path)

Class method: the accounts file parsed and checked. Dies as C<config>
naming the file and the account at fault.

=cut

sub load_file ($class, $path) {
    Odoo::Error->throw( kind => 'config', message => "accounts file $path does not exist" ) if !-e $path;
    my $y = eval { YAML::PP->new->load_file($path) };
    Odoo::Error->throw( kind => 'config', message => "accounts file $path: $@" ) if !defined $y;
    return $class->check_spec( $y, $path, base => dirname($path) );
}

sub check_spec ($class, $y, $what = 'accounts file', %o) {
    my $bad = sub ($m) { Odoo::Error->throw( kind => 'config', message => "$what: $m" ) };
    $bad->('a map was expected') if ref $y ne 'HASH';
    my $dir = $y->{secrets_dir};
    $bad->('secrets_dir is required (a directory for the secret files, mode 0700)') if !defined $dir || $dir eq '';
    $bad->('accounts: a list was expected') if ref $y->{accounts} ne 'ARRAY' || !@{ $y->{accounts} };
    my @roles;
    if ( defined $y->{roles} ) {
        my @paths = ref $y->{roles} eq 'ARRAY' ? @{ $y->{roles} } : ( $y->{roles} );
        $bad->('roles: a list of role files or directories was expected') if grep { !defined || ref || $_ eq '' } @paths;
        my $base = $o{base};
        @roles = @{ Odoo::Ops::Core::Access->load_roles( paths => [ map { m{\A/} || !defined $base ? $_ : "$base/$_" } @paths ] ) };
    }
    my %role = map { $_->{role} => $_ } @roles;
    my ( %seen, @acc );
    for my $a ( @{ $y->{accounts} } ) {
        $bad->('an account is not a map') if ref $a ne 'HASH';
        my $login = $a->{login};
        $bad->('an account has no login') if !defined $login || $login eq '' || $login =~ m{[/\0\s]};
        $bad->("login '$login' appears twice") if $seen{ lc $login }++;
        my $kind = $a->{kind} // 'internal';
        $bad->("$login: kind must be internal or portal, got '$kind'") if $kind !~ /^(internal|portal)\z/;
        $bad->("$login: name is required") if !defined $a->{name} || $a->{name} eq '';
        my %c = ( login => $login, name => $a->{name}, kind => $kind, groups => $a->{groups} // [] );
        $bad->("$login: groups must be a list of group xml ids") if ref $c{groups} ne 'ARRAY';
        if ( defined $a->{role} ) {
            $bad->("$login: role is the id of one role") if ref $a->{role} || $a->{role} eq '';
            $bad->("$login: role is for internal users") if $kind ne 'internal';
            $bad->("$login: role '$a->{role}' is not in the roles the file lists (" . ( @roles ? join( ', ', map { $_->{role} } @roles ) : 'it lists none' ) . ')')
                if !$role{ $a->{role} };
            $c{role} = $a->{role};
        }
        $c{email} = $a->{email} if defined $a->{email};
        $c{partner} = $a->{partner} if defined $a->{partner};
        my $pw = $a->{password};
        if ( defined $pw ) {
            $bad->("$login: password must be generate, keep or file:<path>, got '$pw'") if $pw !~ /^(generate|keep|file:.+)\z/;
            $c{password} = $pw;
        }
        if ( defined $a->{api_key} ) {
            $bad->("$login: api_key is for internal users") if $kind ne 'internal';
            $bad->("$login: api_key needs a password (generate, keep or file:)") if !defined $pw;
            my $k = ref $a->{api_key} eq 'HASH' ? $a->{api_key} : {};
            $c{api_key} = { name => $k->{name} // "$login key", ( defined $k->{duration} ? ( duration => $k->{duration} ) : () ) };
            $bad->("$login: api_key duration is a number of days") if defined $k->{duration} && $k->{duration} !~ /^\d+\z/;
        }
        if ( defined $a->{two_factor} ) {
            my $tf = _flag( $a->{two_factor} );
            $bad->("$login: two_factor is on or off") if !defined $tf;
            $bad->("$login: two_factor applies to internal users") if $kind ne 'internal';
            $bad->("$login: two_factor on needs a password (generate, keep or file:)") if $tf && !defined $pw;
            $c{two_factor} = $tf;
        }
        my $act = defined $a->{active} ? _flag( $a->{active} ) : 1;
        $bad->("$login: active is true or false") if !defined $act;
        $c{active} = $act;
        $bad->("$login: an inactive account cannot sign in to mint a key or set two-factor up") if !$act && ( $c{api_key} || $c{two_factor} );
        push @acc, \%c;
    }
    my $models = $y->{models} // [qw(product.product sale.order sale.order.line res.partner)];
    $bad->('models: a list of model names was expected') if ref $models ne 'ARRAY';
    return { secrets_dir => $dir, models => $models, accounts => \@acc, roles => \@roles, role => \%role };
}

sub _flag ($v) {
    return undef if !defined $v;
    return $v ? 1 : 0 if ref $v;
    my $s = lc "$v";
    return 1 if $s =~ /^(on|yes|true|1)\z/;
    return 0 if $s =~ /^(off|no|false|0|)\z/;
    return undef;
}

# --- files ------------------------------------------------------------------

sub _secrets_dir ($self) {
    my $dir = $self->{spec}{secrets_dir};
    if ( !-d $dir ) {
        make_path( $dir, { mode => 0700 } );
    }
    my @st = stat $dir or Odoo::Error->throw( kind => 'config', message => "cannot use secrets_dir $dir: $!" );
    Odoo::Error->throw( kind => 'config',
        message => sprintf( 'secrets_dir %s is mode %04o; it must deny group and other (chmod 700)', $dir, $st[2] & 07777 ) )
        if $st[2] & 077;
    return $dir;
}

sub path_for ($self, $login, $kind) { File::Spec->catfile( $self->{spec}{secrets_dir}, "$login.$kind" ) }

# the file a password comes from, by the account's setting
sub _password_path ($self, $acc) {
    my $pw = $acc->{password} // return undef;
    return $pw =~ /^file:(.+)\z/ ? $1 : $self->path_for( $acc->{login}, 'password' );
}

sub _generate ($self) {
    open my $r, '<:raw', '/dev/urandom' or Odoo::Error->throw( kind => 'config', message => "cannot read /dev/urandom: $!" );
    read( $r, my $bytes, 18 ) == 18 or Odoo::Error->throw( kind => 'config', message => 'short read from /dev/urandom' );
    close $r;
    return MIME::Base64::encode_base64( $bytes, '' ) =~ tr{+/}{-_}r;
}

sub _write_new_secret ($self, $path, $value) {
    sysopen( my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600 )
        or Odoo::Error->throw( kind => 'config', message => "cannot create $path: $!" );
    print {$fh} "$value\n";
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write $path: $!" );
}

sub _p ($self, $text) { print { $self->{out} } "$text\n" }
sub _e ($self, $text) { print { $self->{err} } "$text\n" }
sub ctx ($self) { $self->{context}->() }

# --- reading Odoo (a read scope of its own) ------------------------------------------

sub _read ($self, $ctx, $label, $scope, $code) {
    return $ctx->guard->with_scope( $scope, "oom-accounts.$label", $code );
}

# login (lower case) => the user row, archived included
sub _users ($self, $ctx) {
    my $client = $ctx->client;
    return $self->_read( $ctx, 'list', { 'res.users' => ['search_read'] }, sub {
        my $users = $client->model('res.users');
        my @f     = ( qw(login name active share), ( $users->fields->{totp_enabled} ? ('totp_enabled') : () ) );
        my $rows  = $users->search_read( [ [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ], \@f );
        return { map { lc $_->{login} => $_ } @$rows };
    } );
}

sub _keys_of ($self, $ctx, $uid) {
    my $client = $ctx->client;
    return $self->_read( $ctx, 'list', { 'res.users.apikeys' => ['search_read'] }, sub {
        my $m = $client->model('res.users.apikeys');
        return $m->search_read( [ [ 'user_id', '=', $uid ] ], [ 'name', ( $m->fields->{expiration_date} ? ('expiration_date') : () ) ] );
    } );
}

# --- stages -------------------------------------------------------------------------------

# Plan the rows, show the plan, ask, approve, apply. Returns
# { applied, held, failed, nothing } for the caller to fold into an exit code.
sub _stage ($self, $label, $rows, %o) {
    my $ctx  = $o{ctx} // $self->ctx;
    my $class = $o{class} // 'Odoo::Ops::Core::User';
    my $op   = $class->new( ctx => $ctx, params => $o{params} // { records => $rows } );
    my $plan = $op->run;
    my $h    = $plan->to_hash;
    my @act  = grep { $_->{action} ne 'skip' && $_->{action} ne 'hold' } @{ $plan->changes };
    my @held = grep { $_->{action} eq 'hold' } @{ $plan->changes };
    my $unch = grep { $_->{bucket} eq 'unchanged' } @{ $plan->changes };
    $self->_p( "== $label: " . join( ', ', map { "$_ $h->{buckets}{$_}" } sort keys %{ $h->{buckets} } ) );
    my @shown = grep { !$_->{support} } @act;
    for my $c (@shown) { $self->_p( '   ' . $c->{bucket} . ' ' . ( $c->{key} // '' ) ) }
    $self->_p( '   (+' . ( @act - @shown ) . ' supporting row(s): the shared category, xml ids)' ) if @act > @shown;
    for my $c (@held) {
        my $key = $c->{key} // '';
        $key =~ s/^src:row(\d+)\z/row $1/;
        my $who = defined $c->{row_login} ? $c->{row_login} : ( $o{logins} && $key =~ /^row (\d+)\z/ ? $o{logins}[ $1 - 1 ] // '' : $key );
        $self->_p( "   HELD $c->{bucket} ($who): " . ( $c->{reason} // '' ) );
    }
    my $res = { applied => 0, held => scalar @held, failed => 0, nothing => !@shown };
    if ( !@shown ) {
        $self->_p( '   nothing to do' . ( $unch ? " ($unch unchanged)" : '' ) );
        return $res;
    }
    if ( !$self->_confirmed( "Apply $label (" . scalar(@shown) . ' change' . ( @shown == 1 ? '' : 's' ) . ')?' ) ) {
        $self->_p('   not confirmed; nothing was written');
        $res->{declined} = 1;
        return $res;
    }
    my $dir = $ctx->run_dir( $class->op_name );
    $plan->save( File::Spec->catfile( $dir, 'plan.json' ) );
    Odoo::Ops::Runs->index_plan( $dir, $plan, now => $ctx->now, ttl => $ctx->plan_ttl, by => $ctx->actor );
    Odoo::Ops::Runs->approve_plan( $dir, $plan, by => $ctx->actor, note => $o{note} // "oom-accounts $label", ttl => $ctx->plan_ttl );
    my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
    my $r = $result->to_hash;
    $self->_p( '   applied: ' . join( ', ', map { "$_ $r->{counts}{$_}" } sort grep { $r->{counts}{$_} } keys %{ $r->{counts} } )
        . "; verified $r->{verified}, not verified $r->{not_verified}" );
    $res->{applied} = 1;
    $res->{result}  = $result;
    $self->{journals}{$label} = $r->{journal};
    if ( !$result->ok ) {
        $res->{failed} = 1;
        my ( undef, $changes ) = Odoo::Ops::Journal->read( $r->{journal} );
        for my $c ( grep { $_->{error} } @$changes ) {
            $self->_p( "   FAILED $c->{bucket} " . ( $c->{key} // '' ) . ': ' . ( ref $c->{error} ? $c->{error}{message} : $c->{error} ) );
        }
    }
    return $res;
}

=head2 stage_journal($label)

The journal of the last applied stage with that label (for example
C<stage 0 (roles)>), so a program can plan its revert with
L<Odoo::Ops::Runner/revert_plan>. Undef when the stage applied nothing.

=cut

sub stage_journal ($self, $label) { $self->{journals}{$label} }

sub _confirmed ($self, $question) {
    return 1 if $self->{yes};
    return $self->{confirm}->($question) ? 1 : 0 if $self->{confirm};
    return 0 if !-t STDIN;
    print { $self->{out} } "$question [y/N] ";
    my $a = <STDIN>;
    return defined $a && $a =~ /^\s*y(es)?\s*$/i ? 1 : 0;
}

=head2 provision

Stage 0, when the file lists roles, brings the roles to their files
(L<Odoo::Ops::Core::Access>: the group, access rows and rules of each), so
that an account's group list resolves to C<__oom__.role_E<lt>roleE<gt>> once it
exists. Stage 1 creates the users the file names that Odoo lacks. Stage 2 brings
every account to the file: active again where it was archived, groups
added, the password from its file (generated where the setting is
C<generate> and no file exists), a key where C<api_key> is given and its
file is absent, two-factor on or off, archived where C<active> is false.
A stage with nothing to do is skipped; a re-run is every row unchanged.
Returns 0, or 1 when a row was held, an apply failed or a stage was
declined.

=cut

# the groups an account is created with and kept in: its own, and its role's
sub _groups_of ($self, $a) {
    return [ @{ $a->{groups} }, ( $a->{role} ? Odoo::Ops::Core::Access->role_xmlid( $a->{role} ) : () ) ];
}

=head2 upgrade

An alias of C<provision>: the same file applied again brings the roles and
the accounts to it. It is quiet when nothing changed, and that is the
upgrade path for an app whose role file changed.

=cut

sub upgrade ($self) { $self->provision }

sub provision ($self) {
    my $spec = $self->{spec};
    my @acc  = @{ $spec->{accounts} };
    my $bad  = 0;

    # stage 0: the roles
    if ( @{ $spec->{roles} } ) {
        my $r = $self->_stage( 'stage 0 (roles)', undef, class => 'Odoo::Ops::Core::Access', params => { roles => $spec->{roles} } );
        return 1 if $r->{declined} || $r->{failed};
        $bad ||= $r->{held};
    }

    # stage 1: the users that are missing
    my $have = $self->_users( $self->ctx );
    my ( @rows, @logins );
    for my $a (@acc) {
        next if $have->{ lc $a->{login} };
        push @rows, {
            action => 'create', login => $a->{login}, name => $a->{name}, kind => $a->{kind},
            ( @{ $self->_groups_of($a) } ? ( groups => $self->_groups_of($a) ) : () ),
            ( defined $a->{email} ? ( email => $a->{email} ) : () ),
            ( defined $a->{partner} ? ( partner => $a->{partner} ) : () ),
        };
        push @logins, $a->{login};
    }
    if (@rows) {
        my $r = $self->_stage( 'stage 1 (create users)', \@rows, logins => \@logins );
        return 1 if $r->{declined} || $r->{failed};
        $bad ||= $r->{held};
    }
    else {
        $self->_p('== stage 1 (create users): nothing to do (every account exists)');
    }

    # stage 2: everything about the accounts that exist
    my $ctx = $self->ctx;
    $have = $self->_users($ctx);
    ( @rows, @logins ) = ();
    for my $a (@acc) {
        my $cur = $have->{ lc $a->{login} };
        if ( !$cur ) {
            $self->_e("$a->{login}: not in Odoo after stage 1; skipped");
            $bad = 1;
            next;
        }
        my $pwf = $self->_password_path($a);
        my $row = sub (%r) { push @rows, { login => $a->{login}, %r }; push @logins, $a->{login} };
        $row->( action => 'activate' ) if $a->{active} && !$cur->{active};
        $row->( action => 'groups', add => $self->_groups_of($a) ) if $a->{kind} eq 'internal' && @{ $self->_groups_of($a) };
        if ( defined $pwf ) {
            my $mode = $a->{password};
            if ( $mode eq 'generate' ) {
                my $fresh = !-e $pwf;
                $self->_write_new_secret( $pwf, $self->_generate ) if $fresh;
                # an archived user cannot sign in, so its password cannot be proved: set it once
                $row->( action => 'password', password_file => $pwf ) if $fresh || $cur->{active} || $a->{active};
            }
            elsif ( $mode eq 'keep' ) {
                # keep leaves an existing file's password alone: no row; with no file there is nothing to keep
                if ( !-e $pwf ) {
                    $self->_e("$a->{login}: password: keep, and $pwf does not exist; the password is left alone");
                    $bad  = 1;
                    $pwf = undef;
                }
            }
            else { $row->( action => 'password', password_file => $pwf ) }
        }
        if ( $a->{api_key} && defined $pwf ) {
            $row->( action => 'api-key', password_file => $pwf, key_file => $self->path_for( $a->{login}, 'key' ),
                name => $a->{api_key}{name}, ( defined $a->{api_key}{duration} ? ( duration => $a->{api_key}{duration} ) : () ) );
        }
        $row->( action => 'totp', two_factor => $a->{two_factor} ? 'on' : 'off', ( defined $pwf ? ( password_file => $pwf ) : () ) )
            if defined $a->{two_factor};
        $row->( action => 'deactivate' ) if !$a->{active} && $cur->{active};
    }
    if (@rows) {
        my $r = $self->_stage( 'stage 2 (secure and set up)', \@rows, ctx => $ctx, logins => \@logins );
        return 1 if $r->{declined} || $r->{failed};
        $bad ||= $r->{held};
    }
    else {
        $self->_p('== stage 2 (secure and set up): nothing to do');
    }
    return $bad ? 1 : 0;
}

=head2 rotate(login => L, password => 1, api_key => 1, forget => 1)

A new password and/or key for one account, into new files; the old file
is kept as C<< <file>.previous >> until C<forget> removes the
C<.previous> files. A password: the new secret goes to
C<< <login>.password.new >>, the stage sets it and proves it, then the
files swap. A key: the key is minted into C<< <login>.key.new >> (as the
user, over the web session), proved, the files swap, and a final stage
revokes the account's older keys of that description as the user (the
C<api-key-revoke> action; an administrator cannot remove another
user's key). Two-factor accounts: a password rotates, a key does not (the
mint needs a password session). Returns 0 or 1.

=cut

sub rotate ($self, %o) {
    my $login = $o{login} // Odoo::Error->throw( kind => 'usage', message => 'rotate needs --login' );
    my ($acc) = grep { lc $_->{login} eq lc $login } @{ $self->{spec}{accounts} };
    Odoo::Error->throw( kind => 'usage', message => "rotate: '$login' is not in the accounts file" ) if !$acc;
    if ( $o{forget} ) {
        my $n = 0;
        for my $k (qw(password key)) {
            my $f = $self->path_for( $login, "$k.previous" );
            $n += unlink $f if -e $f;
        }
        $self->_p("forgot $n previous file(s) of $login");
        return 0 if !$o{password} && !$o{api_key};
    }
    Odoo::Error->throw( kind => 'usage', message => 'rotate needs --password, --api-key or both' ) if !$o{password} && !$o{api_key};
    Odoo::Error->throw( kind => 'usage', message => "rotate: '$login' has no password setting in the file" ) if !defined $acc->{password};
    Odoo::Error->throw( kind => 'usage', message => "rotate: '$login' has no api_key in the file" ) if $o{api_key} && !$acc->{api_key};

    if ( $o{password} ) {
        my $cur = $self->path_for( $login, 'password' );
        my $new = "$cur.new";
        unlink $new if -e $new;
        $self->_write_new_secret( $new, $self->_generate );
        my $r = $self->_stage( "rotate password of $login", [ { action => 'password', login => $login, password_file => $new } ] );
        return 1 if $r->{declined} || $r->{failed} || $r->{held};
        $self->_swap( $cur, $new );
        $self->_p("   password file replaced; the old one is $cur.previous");
    }
    if ( $o{api_key} ) {
        my $pwf = $self->_password_path($acc);
        my $cur = $self->path_for( $login, 'key' );
        my $new = "$cur.new";
        unlink $new if -e $new;
        my $k = $acc->{api_key};
        my $r = $self->_stage( "mint a new key for $login",
            [ { action => 'api-key', login => $login, password_file => $pwf, key_file => $new, name => $k->{name},
                ( defined $k->{duration} ? ( duration => $k->{duration} ) : () ) } ] );
        return 1 if $r->{declined} || $r->{failed} || $r->{held};
        $self->_swap( $cur, $new );
        $self->_p("   key file replaced; the old one is $cur.previous");
        $r = $self->_stage( "revoke the older keys of $login",
            [ { action => 'api-key-revoke', login => $login, password_file => $pwf, name => $k->{name} } ] );
        return 1 if $r->{declined} || $r->{failed} || $r->{held};
    }
    return 0;
}

sub _swap ($self, $cur, $new) {
    rename $cur, "$cur.previous" or Odoo::Error->throw( kind => 'config', message => "cannot keep $cur as previous: $!" ) if -e $cur;
    rename $new, $cur or Odoo::Error->throw( kind => 'config', message => "cannot move $new to $cur: $!" );
}

# --- list -------------------------------------------------------------------------------

=head2 list

The accounts as Odoo has them against the file: present or missing,
active, two-factor, keys with their expiry; and C<extra>, users in Odoo
whose login is in the same mail domain as a login of the file but not in
it. Returns 0, or 1 when an account is missing.

=cut

sub list ($self) {
    my $ctx  = $self->ctx;
    my $have = $self->_users($ctx);
    my %in   = map { lc $_->{login} => 1 } @{ $self->{spec}{accounts} };
    my $bad  = 0;
    for my $a ( @{ $self->{spec}{accounts} } ) {
        my $cur = $have->{ lc $a->{login} };
        if ( !$cur ) { $self->_p( sprintf '%-40s missing', $a->{login} ); $bad = 1; next }
        my $keys = $a->{kind} eq 'internal' ? $self->_keys_of( $ctx, $cur->{id} ) : [];
        $self->_p( sprintf '%-40s present  active %s  two-factor %s  keys: %s', $a->{login}, $cur->{active} ? 'yes' : 'no',
            ( exists $cur->{totp_enabled} ? ( $cur->{totp_enabled} ? 'on' : 'off' ) : 'n/a' ),
            @$keys ? join( '; ', map { "$_->{name} expires " . _expiry($_) } @$keys ) : 'none' );
    }
    my %dom = map { ( $_->{login} =~ /\@(.+)\z/ ? lc $1 : () ) => 1 } @{ $self->{spec}{accounts} };
    for my $login ( sort keys %$have ) {
        next if $in{$login} || $login !~ /\@(.+)\z/ || !$dom{ lc $1 };
        $self->_p( sprintf '%-40s extra (not in the file)  active %s', $have->{$login}{login}, $have->{$login}{active} ? 'yes' : 'no' );
    }
    $bad = 1 if @{ $self->{spec}{roles} } && $self->_list_roles($ctx);
    return $bad;
}

# Each role's group, access rows and rules as Odoo holds them, and what is under
# __oom__ that no role file names (orphan). Returns 1 when a role's group is missing.
sub _list_roles ($self, $ctx) {
    my $client = $ctx->client;
    my $spec   = $self->{spec};
    my $scope  = { map { $_ => ['search_read'] } qw(ir.model.data res.groups ir.model.access ir.rule ir.model ir.module.category res.groups.privilege) };
    return $self->_read( $ctx, 'list-roles', $scope, sub {
        my $imd = $client->model('ir.model.data')->search_read( [ [ 'module', '=', '__oom__' ] ], [qw(name model res_id)] );
        my %by_name = map { $_->{name} => $_ } @$imd;
        my %named;
        my $bad = 0;
        my %flag = ( read => 'R', create => 'C', write => 'W', unlink => 'U' );
        for my $r ( @{ $spec->{roles} } ) {
            $named{$_} = 1 for Odoo::Ops::Core::Access->xml_names($r);
            my $gx = $by_name{ 'role_' . Odoo::Ops::Core::Access->slug( $r->{role} ) };
            my $g  = $gx ? $client->model('res.groups')->search_read( [ [ 'id', '=', $gx->{res_id} ] ], [qw(name implied_ids)] )->[0] : undef;
            if ( !$g ) { $self->_p( sprintf 'role %-30s missing (no group)', $r->{role} ); $bad = 1; next }
            my @implied = @{ $g->{implied_ids} } ? map { $_->{name} } @{ $client->model('res.groups')->search_read( [ [ 'id', 'in', $g->{implied_ids} ] ], ['name'] ) } : ();
            $self->_p( sprintf 'role %-30s group %d "%s"%s', $r->{role}, $g->{id}, $g->{name}, @implied ? ' implies ' . join( ', ', sort @implied ) : '' );
            my $acc = $client->model('ir.model.access')->search_read( [ [ 'group_id', '=', $g->{id} ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
                [qw(name model_id perm_read perm_create perm_write perm_unlink active)] );
            my %mn = map { $_->{id} => $_->{model} } @{ @$acc ? $client->model('ir.model')->search_read( [ [ 'id', 'in', [ map { $_->{model_id}[0] } @$acc ] ] ], ['model'] ) : [] };
            for my $x ( sort { $mn{ $a->{model_id}[0] } cmp $mn{ $b->{model_id}[0] } } @$acc ) {
                $self->_p( sprintf '   access %-24s %s%s', $mn{ $x->{model_id}[0] } // '?', join( '', map { $x->{"perm_$_"} ? $flag{$_} : '-' } qw(read create write unlink) ),
                    $x->{active} ? '' : ' (archived)' );
            }
            my $rules = $client->model('ir.rule')->search_read( [ [ 'groups', 'in', [ $g->{id} ] ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
                [qw(name model_id domain_force perm_read perm_create perm_write perm_unlink active)] );
            for my $x ( sort { $a->{name} cmp $b->{name} } @$rules ) {
                $self->_p( sprintf '   rule   %-24s %s  %s  %s%s', $x->{name}, $x->{model_id}[1], join( '', map { $x->{"perm_$_"} ? $flag{$_} : '-' } qw(read create write unlink) ),
                    $x->{domain_force}, $x->{active} ? '' : ' (archived)' );
            }
        }
        $named{category_external} = $named{privilege_external} = 1;
        for my $n ( sort grep { !$named{$_} } keys %by_name ) {
            $self->_p( sprintf 'orphan %s (%s %s): under __oom__ and named by no role file', $n, $by_name{$n}{model}, $by_name{$n}{res_id} );
        }
        return $bad;
    } );
}

sub _expiry ($key) {
    return 'never' if !exists $key->{expiration_date} || !$key->{expiration_date};
    return $key->{expiration_date};
}

# --- probe ----------------------------------------------------------------------------------

=head2 probe

For every account, from the consumer's side and without printing a
secret: the connection by key (uid, administrator, C<check_access_rights>
on the file's C<models>), the sign-in over the web session (signed in,
refused as C<credential>, or refused as C<second_factor>, which is the
password accepted and no session opened), and the key's expiry. When the
key is refused, the lines under it say what the config can read: whether the
login is archived, whether Odoo holds a key of that description, and its
expiry against the clock (C<key: the login is archived in Odoo>,
C<key: the key 'x' expired at ...>); they are facts read from Odoo, with no
cause chosen between them, and are kept in C<probe.last.json> as C<because>. The
result is also written, without secrets, to C<probe.last.json> in
C<secrets_dir> for C<handover>. Returns 1 when an account does not
behave as the file says.

=cut

sub probe ($self) {
    my $ctx    = $self->ctx;
    my $have   = $self->_users($ctx);
    my $client = $ctx->client;
    my $cfg    = $self->{config};
    my @report;
    my $bad = 0;
    for my $a ( @{ $self->{spec}{accounts} } ) {
        my %r = ( login => $a->{login}, expect => {} );
        my @wrong;
        my $cur = $have->{ lc $a->{login} };
        $self->_p("== $a->{login}");
        if ( !$cur ) {
            $self->_p('   missing in Odoo');
            push @report, { %r, exists => 0, wrong => ['missing in Odoo'] };
            $bad = 1;
            next;
        }
        $r{exists} = 1;
        $r{active} = $cur->{active} ? 1 : 0;
        $r{two_factor} = $cur->{totp_enabled} ? 1 : 0 if exists $cur->{totp_enabled};
        push @wrong, 'is ' . ( $cur->{active} ? 'active' : 'archived' ) . ' and the file says ' . ( $a->{active} ? 'active' : 'archived' )
            if ( $cur->{active} ? 1 : 0 ) != $a->{active};
        push @wrong, 'two-factor is ' . ( $cur->{totp_enabled} ? 'on' : 'off' ) . ' and the file says ' . ( $a->{two_factor} ? 'on' : 'off' )
            if defined $a->{two_factor} && ( $cur->{totp_enabled} ? 1 : 0 ) != $a->{two_factor};

        # 1. the connection by key
        if ( $a->{api_key} ) {
            my $kf = $self->path_for( $a->{login}, 'key' );
            if ( !-e $kf ) { $self->_p("   key: no key file ($kf)"); push @wrong, 'the key file does not exist' }
            else {
                my $c = eval { $self->_key_client( $a->{login}, $kf ) };
                my $uid = $c ? eval { $c->uid } : undef;
                if ( !$uid ) {
                    my $why = _why( $@ );
                    $self->_p("   key: REFUSED - $why");
                    $r{key} = { ok => 0, why => $why };
                    # Odoo refuses an archived login, an expired or deleted key and a wrong secret with one answer;
                    # what this config can read of the login and its keys is said beside it
                    my @because = $self->_refusal_facts( $ctx, $cur, $a );
                    $self->_p("   key: $_") for @because;
                    $r{key}{because} = \@because;
                    push @wrong, 'the key does not connect';
                }
                else {
                    my $admin = eval { $c->model('res.users')->call( 'has_group', ['base.group_system'] ) } ? 1 : 0;
                    $self->_p( "   key: connects as uid $uid; administrator " . ( $admin ? 'YES' : 'no' ) );
                    my $rights = $self->_probe_rights( $c, $self->_models_for($a) );
                    $r{key} = { ok => 1, uid => $uid, administrator => $admin, rights => $rights };
                    $r{rights_by} = 'key';
                    push @wrong, 'the key connects as an administrator' if $admin;
                    push @wrong, $self->_judge_rights( $a, $rights ) if $a->{role};
                }
                my $keys = eval { $self->_keys_of( $ctx, $cur->{id} ) } // [];
                my @mine = grep { $_->{name} eq $a->{api_key}{name} } @$keys;
                $r{key}{expiry} = [ map { _expiry($_) } @mine ];
                $self->_p( "   key expiry: " . ( @mine ? join( ', ', map { _expiry($_) } @mine ) : 'no key of that description' ) );
                push @wrong, "no key named '$a->{api_key}{name}' in Odoo" if !@mine;
            }
        }

        # 2. the sign-in over the web session
        if ( defined $a->{password} ) {
            my $pwf = $self->_password_path($a);
            my $pw  = -e $pwf ? eval { Odoo::Ops::Credential->secret_file( $pwf, 'password file' ) } : undef;
            if ( !defined $pw ) { $self->_p("   sign-in: no usable password file ($pwf)"); push @wrong, 'the password file is not usable' }
            else {
                my $web = $client->web_session;
                my $id  = eval { $web->authenticate( $client->db, $a->{login}, $pw ) };
                # right password, two-factor on: Odoo opened no session and waits for a code
                my $no_session = $id && $id->{pending};
                if ( $no_session ) { eval { $web->destroy }; $id = undef }
                if ($id) {
                    my $t = Odoo::Client->new( url => $client->url, db => $client->db, transport => $web, retries => [0] );
                    my $g = eval { $t->session_groups_report( xmlids => 0 ) };
                    my $gn = $g ? scalar @{ $g->{groups} } : undef;
                    $self->_p( "   sign-in: signed in as uid $id->{uid}" . ( $g ? ( $g->{groups_readable} ? ", $gn group(s)" : ', groups not readable' ) : '' ) );
                    $r{signin} = { result => 'signed-in', uid => $id->{uid}, ( $g ? ( groups => $gn, groups_readable => $g->{groups_readable} ) : () ) };
                    if ( $a->{role} && !$r{rights_by} ) {
                        # no key to prove the rights with: the person's own session does
                        my $rights = $self->_probe_rights( $t, $self->_models_for($a) );
                        $r{rights} = $rights;
                        $r{rights_by} = 'session';
                        push @wrong, $self->_judge_rights( $a, $rights );
                    }
                    eval { $web->destroy };
                    push @wrong, 'two-factor is on and a password signs in' if $a->{two_factor};
                    push @wrong, 'the account is archived and signs in' if !$a->{active};
                }
                else {
                    my $err = $@;
                    my $cat = $no_session ? 'second_factor' : ref $err && $err->can('fault_category') ? ( $err->fault_category // $err->kind ) : 'error';
                    $self->_p( "   sign-in: refused ($cat)" . ( $no_session
                        ? ' - the password was accepted and no session was opened: two-factor' : '' ) );
                    $r{signin} = { result => 'refused', category => $cat };
                    push @wrong, 'the password does not sign in' if $a->{active} && !$a->{two_factor};
                    push @wrong, "two-factor is on and the sign-in was refused as $cat, not second_factor" if $a->{two_factor} && $a->{active} && $cat ne 'second_factor';
                    push @wrong, 'the account is archived and the sign-in was not refused as credential' if !$a->{active} && $cat ne 'credential';
                }
            }
        }
        $self->_p("   rights: not proved against role '$a->{role}' (no key, and no password session to ask as)") if $a->{role} && !$r{rights_by};
        if (@wrong) { $self->_p("   MISMATCH: $_") for @wrong; $bad = 1 }
        else { $self->_p('   as the file says') }
        $r{wrong} = \@wrong;
        push @report, \%r;
    }
    my $path = File::Spec->catfile( $self->{spec}{secrets_dir}, 'probe.last.json' );
    my $json = Odoo::JSON->new( pretty => 1 )->encode( {
        at => Odoo::Ops::iso_time( $self->{now}->() ), instance => { url => $client->url, db => $client->db }, accounts => \@report } );
    sysopen( my $fh, $path, O_WRONLY | O_CREAT | O_TRUNC, 0600 ) or Odoo::Error->throw( kind => 'config', message => "cannot write $path: $!" );
    print {$fh} $json;
    close $fh;
    return $bad ? 1 : 0;
}

# What the config can read of why a key is refused: whether the login is archived and
# which keys of that description Odoo holds, with their expiry. Facts only; no cause is chosen.
sub _refusal_facts ($self, $ctx, $cur, $a) {
    my @f;
    push @f, 'the login is archived in Odoo (Odoo refuses the key of an archived login)' if !$cur->{active};
    my $keys = eval { $self->_keys_of( $ctx, $cur->{id} ) };
    if ( !$keys ) { push @f, 'the keys of this login could not be read with this config'; return @f }
    my @mine = grep { $_->{name} eq $a->{api_key}{name} } @$keys;
    push @f, "Odoo holds no key named '$a->{api_key}{name}' for this login (deleted, or never made)" if !@mine;
    my @t = gmtime $self->{now}->();
    my $now = sprintf '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
    for my $k (@mine) {
        my $e = _expiry($k);
        push @f, $e eq 'never' ? "the key '$k->{name}' has no expiry" : $e lt $now ? "the key '$k->{name}' expired at $e (UTC)" : "the key '$k->{name}' expires at $e (UTC)";
    }
    push @f, 'the login is active' if $cur->{active};
    return @f;
}

sub _key_client ($self, $login, $kf) {
    return $self->{client_for}->( $login, $kf ) if $self->{client_for};
    my $c = $self->{config};
    my %http = map { defined $c->get($_) ? ( $_ => $c->get($_) ) : () } qw(url ssl_ca_file);
    return Odoo::Client->new( %http, db => $c->get('db'), login => $login, api_key_file => $kf,
        transport => $c->get('transport') // 'jsonrpc', retries => [0] );
}

# models a role's account is probed on: the file's models, the role's table, and two
# models no external role should create in (the table says so by not naming them)
my @CANARY = qw(res.users ir.rule);

sub _models_for ($self, $a) {
    my @m = @{ $self->{spec}{models} };
    if ( $a->{role} ) {
        my %have = map { $_ => 1 } @m;
        for my $x ( ( map { $_->{model} } @{ $self->{spec}{role}{ $a->{role} }{access} } ), @CANARY ) { push @m, $x if !$have{$x}++ }
    }
    return \@m;
}

# check_access_rights as the connected user, per model and operation; undef where the model cannot be asked
sub _probe_rights ($self, $c, $models) {
    my %rights;
    for my $m (@$models) {
        for my $op (qw(read create write unlink)) {
            my $ok = eval { $c->model($m)->call( 'check_access_rights', [], operation => $op, raise_exception => JSON::PP::false ) };
            $rights{$m}{$op} = defined $ok ? ( $ok ? 1 : 0 ) : undef;
        }
        $self->_p( sprintf '   %-18s %s', $m, join( ' ', map { "$_ " . ( !defined $rights{$m}{$_} ? 'n/a' : $rights{$m}{$_} ? 'allowed' : 'refused' ) } qw(read create write unlink) ) );
    }
    return \%rights;
}

# the role's table is the expectation: every model in it agrees with the file on all four
# operations; a model it does not name must refuse create. Returns the disagreements, named.
sub _judge_rights ($self, $a, $rights) {
    my $role = $self->{spec}{role}{ $a->{role} };
    my %row  = map { $_->{model} => $_ } @{ $role->{access} };
    my @wrong;
    for my $m ( sort keys %$rights ) {
        my $got = $rights->{$m};
        if ( my $want = $row{$m} ) {
            for my $op (qw(read create write unlink)) {
                if ( !defined $got->{$op} ) { push @wrong, "$m $op cannot be checked and role '$role->{role}' says " . ( $want->{$op} ? 'allowed' : 'refused' ); next }
                push @wrong, "$m $op is " . ( $got->{$op} ? 'allowed' : 'refused' ) . " and role '$role->{role}' says " . ( $want->{$op} ? 'allowed' : 'refused' )
                    if $got->{$op} != $want->{$op};
            }
        }
        elsif ( $got->{create} ) {
            push @wrong, "$m create is allowed and role '$role->{role}' does not grant $m";
        }
    }
    return @wrong;
}

sub _why ($e) {
    return "$e" if !( blessed($e) && $e->isa('Odoo::Error') );
    return ( $e->fault_category // $e->kind ) . ': ' . $e->message;
}

# --- take-reset ---------------------------------------------------------------------------------

=head2 take_reset(link => L, password_file => F, ...)

Class method: the workflow that turns a password-reset link, the artefact
Odoo hands out when an administrator makes a user for an integration, into a
password file and a config that works. It needs no accounts file and no
config: C<link> alone carries the url and the database. Options: C<link>
(required), C<password_file> (required: a 0600 file to take the password
from, or the path of one to make), C<conf> (a config to write or complete),
C<login> (the login the form must name), C<ca_file> (a private CA for the
instance), C<check> (read the form and stop), C<yes>, C<confirm>, C<out>,
C<err>, C<now>, and for a program or a test C<context> (a code ref given the
config, returning a L<Odoo::Ops::Context>) and C<doctor> (a code ref given
the config path, returning the doctor's report).

The steps, each a line on the screen: the form is read through a
C<core.user> C<reset-take> plan (login, name, database, series, and the
holds); a C<conf> that already says otherwise is refused as
C<refused/conf-differs> before anything is consumed; the plan is approved
(C<yes>, or C<approval = self> or C<none> in the C<conf>) and applied, which
makes the password, writes the file, submits the form and proves the password
by signing in; the C<conf> is written or completed (only the keys it lacks:
C<url>, C<db>, C<login>, C<credential = password>, C<password_file> as an
absolute path, and C<ssl_ca_file> when C<ca_file> is given); the doctor runs
on it and its summary line is printed, then a C<then:> line. Without a
C<conf> the four values a config needs are printed. The password and the
token are not printed. Returns 0, or 1 when the form was held, the apply was
declined or failed, or the doctor failed.

=cut

sub take_reset ($class, %o) {
    my $link = $o{link} // Odoo::Error->throw( kind => 'usage', message => 'take-reset needs --link (the reset URL Odoo gave)' );
    my $pf   = $o{password_file} // Odoo::Error->throw( kind => 'usage', message => 'take-reset needs --password-file (a 0600 file, or the path of one to make)' );
    my $l    = Odoo::Ops::ResetForm->parse_link($link);
    Odoo::Error->throw( kind => 'usage', message => 'the link carries no db: --link must be the whole reset URL (https://host/web/reset_password?db=...&token=...)' )
        if $l->{path} eq '/web/reset_password' && ( !defined $l->{db} || $l->{db} eq '' );
    my $abs = File::Spec->rel2abs($pf);

    my ( $lines, $have ) = defined $o{conf} && -e $o{conf} ? $class->_conf_read( $o{conf} ) : ( [], {} );
    my $self = bless {
        out => $o{out} // \*STDOUT, err => $o{err} // \*STDERR, confirm => $o{confirm}, now => $o{now} // sub { time },
        yes => ( $o{yes} || ( $have->{approval} // '' ) =~ /^(?:self|none)\z/ ? 1 : 0 ),
    }, $class;
    my $ca = $o{ca_file} // $have->{ssl_ca_file};
    my $cfg = Odoo::Ops::Config->new(
        url => $l->{url}, db => $l->{db} // 'unknown', login => $o{login} // 'take-reset', allow_writes => 1, approval => 'required',
        runs_dir => $have->{runs_dir} // File::Temp::tempdir( 'oom-take-reset-XXXXXX', TMPDIR => 1, CLEANUP => 1 ),
        ( defined $ca ? ( ssl_ca_file => $ca ) : () ),
        ( defined $have->{ssl_verify} ? ( ssl_verify => $have->{ssl_verify} ) : () ),
        ( defined $have->{timeout} ? ( timeout => $have->{timeout} ) : () ),
    );
    my $ctx = $o{context} ? $o{context}->($cfg) : Odoo::Ops::Context->new( config => $cfg, credential => { login => 'take-reset', api_key => 'none' }, retries => [0] );
    $self->{context} = sub { $ctx };

    my $row = { action => 'reset-take', link => $link, password_file => $abs, ( defined $o{login} ? ( login => $o{login} ) : () ) };
    my $tok = $l->{token} // '';
    $self->_p( 'take-reset: ' . $l->{url} . ( defined $l->{db} ? " database $l->{db}" : '' ) . ( length $tok ? ', token ' . Odoo::Ops::ResetForm->prefix($tok) : '' ) );

    # 1. the form
    my $plan = Odoo::Ops::Core::User->new( ctx => $ctx, params => { records => [$row] } )->run;
    my ($held) = grep { $_->{action} eq 'hold' } @{ $plan->changes };
    if ($held) {
        $self->_p("   HELD $held->{bucket}: $held->{reason}");
        return 1;
    }
    my ($c) = grep { $_->{action} eq 'custom' } @{ $plan->changes };
    $self->_p("   form: login $c->{login}, name $c->{name}, database $c->{db}, Odoo $c->{series}");
    $self->_p("   password file: $abs" . ( -e $abs ? ' (exists: its password is the one set)' : ' (to be made, mode 0600)' ));

    # 2. a config that says otherwise is refused before the link is consumed
    my @add;
    if ( defined $o{conf} ) {
        my %want = ( url => $l->{url}, db => $c->{db}, login => $c->{login}, credential => 'password', password_file => $abs,
            ( defined $o{ca_file} ? ( ssl_ca_file => File::Spec->rel2abs( $o{ca_file} ) ) : () ) );
        my %said = ( url => 'the link says', db => 'the link says', login => 'the form says', credential => 'take-reset sets', password_file => '--password-file says', ssl_ca_file => '--ca-file says' );
        for my $k (qw(url db login credential password_file ssl_ca_file)) {
            next if !exists $want{$k};
            my $now = $have->{$k};
            if ( !defined $now ) { push @add, $k; next }
            my $same = $k eq 'url' ? Odoo::Ops::ResetForm->same_origin( $now, $want{$k} )
                : $k =~ /^(?:password_file|ssl_ca_file)\z/ ? File::Spec->rel2abs($now) eq $want{$k}
                : $k eq 'login' ? lc $now eq lc $want{$k} : $now eq $want{$k};
            Odoo::Error->throw( kind => 'refused', code => 'conf-differs', message => "$k is $now and $said{$k} $want{$k}",
                fix => "$o{conf} is not changed; correct that line, or give the --conf of the instance the link is for" ) if !$same;
        }
    }
    if ( $o{check} ) {
        $self->_p('   check: nothing was changed (the link is not used up)');
        return 0;
    }

    # 3. apply
    my $res = $self->_stage( 'take-reset', [$row], ctx => $ctx, note => 'oom-accounts take-reset' );
    return 1 if $res->{declined} || $res->{failed} || $res->{held} || !$res->{applied};

    # 4. the config
    my $conf = $o{conf};
    if ( defined $conf ) {
        my $new = !-e $conf;
        my %val = ( url => $l->{url}, db => $c->{db}, login => $c->{login}, credential => 'password', password_file => $abs,
            ( defined $o{ca_file} ? ( ssl_ca_file => File::Spec->rel2abs( $o{ca_file} ) ) : () ) );
        $self->_conf_complete( $conf, $new, \%val, \@add );
        $self->_p( $new ? "   config written: $conf (mode 0600)" : '   config completed: ' . $conf . ( @add ? ' (' . join( ', ', @add ) . ' added)' : ' (nothing to add)' ) );
    }
    else {
        $self->_p('   a config needs:');
        $self->_p("      $_") for "url = $l->{url}", "db = $c->{db}", "login = $c->{login}", 'credential = password', "password_file = $abs",
            ( defined $o{ca_file} ? 'ssl_ca_file = ' . File::Spec->rel2abs( $o{ca_file} ) : () );
        $self->_p("   password file written: $abs") if -e $abs;
    }

    # 5. the proof
    my $code = 0;
    if ( defined $conf ) {
        require Odoo::Ops::Core::Doctor;
        my $report = $o{doctor} ? $o{doctor}->($conf) : do { require Odoo::Ops::Core::Doctor; Odoo::Ops::Core::Doctor->examine($conf) };
        my ($sum) = grep { /^summary:/ } split /\n/, Odoo::Ops::Core::Doctor->format_text($report);
        $self->_p("   doctor: $sum");
        # the exit says whether the credential works: a doctor failure of a pack the series lacks (the mailing
        # profile is 16 only) is the doctor's own report, not a failed take
        my ($login_check) = grep { $_->{name} eq 'auth.login' } @{ $report->{checks} // [] };
        $code = 1 if $login_check ? $login_check->{status} ne 'ok' : ( $report->{summary}{exit} // 0 ) >= 2;
        $self->_p("then: oom-ops doctor --conf $conf");
    }
    else {
        $self->_p('then: save those keys as a config (mode 0600), then run: oom-ops doctor --conf <that config>');
    }
    return $code;
}

# key => value of a config file, and its lines (comments and unknown lines kept as they are)
sub _conf_read ($class, $path) {
    open my $fh, '<', $path or Odoo::Error->throw( kind => 'config', message => "cannot read config $path: $!" );
    my ( @lines, %v );
    while ( my $line = <$fh> ) {
        push @lines, $line;
        $v{$1} = $2 if $line =~ /^\s*([\w.]+)\s*=\s*(.*?)\s*\z/ && $line !~ /^\s*#/;
    }
    close $fh;
    return ( \@lines, \%v );
}

# a new config is made 0600 with a comment naming this tool and the date; an
# existing one gets only the lines it lacks, appended
sub _conf_complete ($self, $path, $new, $val, $add) {
    my @keys = $new ? grep { exists $val->{$_} } qw(url db login credential password_file ssl_ca_file) : @$add;
    my $text = '';
    if ($new) {
        my @t = gmtime $self->{now}->();
        $text = sprintf "# written by oom-accounts take-reset on %04d-%02d-%02d\n", $t[5] + 1900, $t[4] + 1, $t[3];
    }
    elsif ( -s $path ) {
        open my $in, '<', $path or Odoo::Error->throw( kind => 'config', message => "cannot read config $path: $!" );
        seek $in, -1, 2;
        read $in, my $last, 1;
        close $in;
        $text = "\n" if $last ne "\n";
    }
    $text .= "$_ = $val->{$_}\n" for @keys;
    return if $text eq '';
    my $fh;
    if ($new) { sysopen( $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600 ) or Odoo::Error->throw( kind => 'config', message => "cannot create config $path: $!" ) }
    else      { open( $fh, '>>', $path ) or Odoo::Error->throw( kind => 'config', message => "cannot append to config $path: $!" ) }
    print {$fh} $text;
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write config $path: $!" );
    return;
}

# --- handover -----------------------------------------------------------------------------------

=head2 handover(for => NAME, out => PATH)

Writes the hand-over sheet for the people who will use the accounts, in
house markdown: the URL, database and CA file of the instance, then each
login with its rights from the last C<probe> and the paths of its
secret files. It never holds a secret value. Returns 0.

=cut

sub handover ($self, %o) {
    my $cfg  = $self->{config};
    my $for  = $o{for} // 'the consumer';
    my $last = File::Spec->catfile( $self->{spec}{secrets_dir}, 'probe.last.json' );
    my $probe;
    if ( -e $last ) {
        open my $fh, '<', $last or Odoo::Error->throw( kind => 'config', message => "cannot read $last: $!" );
        local $/;
        $probe = eval { Odoo::JSON::decode(<$fh>) };
    }
    my %by = map { $_->{login} => $_ } @{ $probe ? $probe->{accounts} : [] };
    my @out = (
        '---', qq(title: "Accounts for $for"),
        qq(subtitle: "The logins on the instance below, what each can do as last proved, and where their secrets are kept."),
        'brand: plain', 'standard-margins: true', '---', '',
        '# The instance', '',
        '```datatable', 'columns: Item | Value', 'widths: 3cm | X', 'bold: 1', '---',
        'URL | `' . ( $cfg->get('url') // '' ) . '`',
        'Database | `' . ( $cfg->get('db') // '' ) . '`',
        ( $cfg->get('ssl_ca_file') ? 'Certificate authority | `' . $cfg->get('ssl_ca_file') . '`' : () ),
        'Rights last proved | ' . ( $probe ? $probe->{at} : 'not probed' ),
        '```', '',
        '# The accounts', '',
        '```datatable', 'columns: Login | What it is | Rights, as last proved | Secret files (mode 0600)',
        'widths: 4cm | 3cm | X | 4.6cm', 'bold: 1', '---',
    );
    for my $a ( @{ $self->{spec}{accounts} } ) {
        my $p = $by{ $a->{login} };
        my @is = ( $a->{kind}, ( $a->{role} ? "role $a->{role}" : () ), ( $a->{active} ? () : 'archived' ), ( $a->{two_factor} ? 'two-factor on' : () ) );
        my @rights;
        if ( !$p ) { push @rights, 'not probed' }
        else {
            push @rights, 'password: ' . ( $p->{signin} ? ( $p->{signin}{result} eq 'signed-in' ? 'signs in' : "refused ($p->{signin}{category})" ) : 'none' );
            if ( my $k = $p->{key} ) {
                push @rights, $k->{ok}
                    ? 'key: connects' . ( $k->{administrator} ? ' as an administrator' : ', not an administrator' )
                        . ( @{ $k->{expiry} // [] } ? ', expires ' . join( ', ', @{ $k->{expiry} } ) : '' )
                    : 'key: refused';
                for my $m ( sort keys %{ $k->{rights} // {} } ) {
                    my $r = $k->{rights}{$m};
                    push @rights, "`$m` " . join( '', map { $r->{$_} ? uc( substr $_, 0, 1 ) : '-' } qw(read create write unlink) );
                }
            }
            elsif ( $p->{rights} ) {
                for my $m ( sort keys %{ $p->{rights} } ) {
                    my $r = $p->{rights}{$m};
                    push @rights, "`$m` " . join( '', map { $r->{$_} ? uc( substr $_, 0, 1 ) : '-' } qw(read create write unlink) );
                }
            }
        }
        my @files = ( defined $a->{password} ? '`' . $self->_password_path($a) . '`' : (), ( $a->{api_key} ? '`' . $self->path_for( $a->{login}, 'key' ) . '`' : () ) );
        push @out, join( ' | ', "`$a->{login}`", join( ', ', @is ), join( '; ', @rights ), join( '; ', @files ) || 'none' );
    }
    push @out, '```', '',
        'The rights column reads R for read, C for create, W for write and U for unlink; a dash is refused.',
        'No secret value is on this sheet; each file holds one secret on its first line.', '';
    my %used = map { ( $_->{role} // '' ) => 1 } @{ $self->{spec}{accounts} };
    for my $role ( grep { $used{ $_->{role} } } @{ $self->{spec}{roles} } ) {
        push @out, "# Role $role->{role}", '',
            "The group \"$role->{name}\" holds what the role file declares; nothing outside this table is granted by it.", '';
        push @out, '```datatable', 'columns: Model | Read | Create | Write | Delete', 'widths: X | 1.6cm | 1.6cm | 1.6cm | 1.6cm', 'bold: 1', '---',
            ( map { join( ' | ', "`$_->{model}`", map { $_ ? 'yes' : '-' } @{$_}{qw(read create write unlink)} ) } @{ $role->{access} } ), '```', ''
            if @{ $role->{access} };
        if ( @{ $role->{rules} } ) {
            push @out, 'Record rules, which narrow the rows the group reaches:', '',
                '```datatable', 'columns: Rule | Model | Domain | Applies to', 'widths: 3.4cm | 3.4cm | X | 3cm', 'bold: 1', '---',
                ( map {
                    my $r = $_;
                    ( my $d = $r->{domain} ) =~ s/\|/\\|/g;
                    join( ' | ', "`$r->{label}`", "`$r->{model}`", "`$d`", join( ', ', grep { $r->{$_} } qw(read create write unlink) ) || 'nothing' )
                } @{ $role->{rules} } ), '```', '';
        }
    }
    my $text = join( "\n", @out );
    if ( defined $o{out} ) {
        open my $fh, '>', $o{out} or Odoo::Error->throw( kind => 'config', message => "cannot write $o{out}: $!" );
        print {$fh} $text;
        close $fh;
        $self->_p("hand-over sheet written to $o{out}");
    }
    else { print { $self->{out} } $text }
    return 0;
}

1;

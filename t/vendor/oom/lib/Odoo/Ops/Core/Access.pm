package Odoo::Ops::Core::Access;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(basename);
use JSON::PP ();
use YAML::PP ();

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Access - the groups, model access and record rules an app declares

=head1 SYNOPSIS

    oom-ops run core.access --conf C --set file=roles/lazysite-connection.yaml
    oom-ops run core.access --conf C --set dir=roles/

    # in-process (what oom-accounts does)
    Odoo::Ops::Core::Access->new( ctx => $ctx, params => { roles => \@parsed } )->run;

=head1 DESCRIPTION

C<core.access> brings the Odoo rights an external application needs to
the state its role file declares, so that nobody opens Odoo to set
permissions. One YAML file per role, shipped by whoever builds the app:

    role: lazysite-connection        # stable id; xml id __oom__.role_lazysite_connection
    name: lazysite connection        # the group's name as Odoo shows it
    implied: [base.group_user]       # groups this one implies, by xml id
    access:                          # ir.model.access rows; a model not listed is not granted
      - { model: product.product, read: true }
      - { model: sale.order, read: true, create: true, write: true }
    rules:                           # ir.rule rows for this group
      - label: own-draft-quotations
        model: sale.order
        domain: "[('create_uid', '=', user.id), ('state', 'in', ['draft', 'sent'])]"
        read: true
        write: true
        create: true
        unlink: false

A role is the truth for what it names. The group, each access row and each
rule is found by its xml id in the module C<__oom__> (C<role_E<lt>roleE<gt>>,
C<access_E<lt>roleE<gt>_E<lt>modelE<gt>>, C<rule_E<lt>roleE<gt>_E<lt>labelE<gt>>, dots and dashes written
as underscores) and created or brought to the file's values; an access row or rule that
carries the role's xml id and group but is no longer in the file is removed (its
before-image is journalled, so a revert recreates it). Nothing without an
C<__oom__> xml id is touched, and nothing of another role.

Rights flags on an access row default to refused. On a rule they default to
applying (as in Odoo), so a rule restricts every operation unless the file says
C<< unlink: false >>. A rule belongs to the role's group only and is never global.

Buckets: C<role-create>, C<role-update>, C<access-create>, C<access-update>,
C<access-remove>, C<rule-create>, C<rule-update>, C<rule-remove>, C<unchanged>,
and the holds C<unknown-model> (the model is not on the instance),
C<unknown-implied-group>, C<invalid-domain> (the domain cannot be read, names a
field the model lacks or a name Odoo does not provide) and C<role-held> (the
rows of a role whose group is held). The buckets sum to the groups, access rows
and rules the files name, plus removals. Supporting rows (the one category or
privilege "External applications" all roles share, xml id
C<__oom__.category_external>, and every C<ir.model.data> row) are marked
C<support> and are not counted.

Where the series groups groups: 16 and 18 by a C<category_id> (an
C<ir.module.category>), 19 by a C<privilege_id> (a C<res.groups.privilege>
whose C<category_id> puts it on the user form). This operation makes the
category on 16 and 18, and on 19 the privilege
(C<__oom__.privilege_external>), once. Odoo gives an administrator read
only on C<ir.module.category> (live on 16, 18 and 19): where
C<check_access_rights> says create is refused, the category is not made,
the plan says so in a note, and the group is created without one (on 19
the privilege is made without a category, so the group is not offered on the
user form's group selection; it is still assigned by xml id).

A domain Odoo refuses is held at planning from a check made here (a list, balanced,
fields that exist, names Odoo provides); Odoo checks it again when the rule is
written, and a refusal there stops the run with Odoo's own message.

Two roles with the same C<role> id in one run are refused by name.

=cut

sub op_name ($class) { 'core.access' }
sub summary ($class) { 'Bring an app\'s groups, model access and record rules to its role file' }
sub pack    ($class) { undef }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'role-create', meaning => 'a role (a group) is made' },
        { name => 'role-update', meaning => 'an existing role\'s name, category or implied groups are written' },
        { name => 'access-create', meaning => 'a model access row (create, read, write, unlink rights) is made for the role' },
        { name => 'access-update', meaning => 'an existing access row is written' },
        { name => 'access-remove', meaning => 'an access row the file no longer lists is removed (remove=1)' },
        { name => 'rule-create', meaning => 'a record rule is made for the role' },
        { name => 'rule-update', meaning => 'an existing record rule is written' },
        { name => 'rule-remove', meaning => 'a record rule the file no longer lists is removed (remove=1)' },
        { name => 'support-create', meaning => 'a category the roles need is made first (a support row)' },
        { name => 'xmlid-create', meaning => 'an external id is recorded so the next run finds the row again (a support row)' },
        { name => 'xmlid-remove', meaning => 'an external id goes with the row it named (a support row)' },
        { name => 'unchanged', meaning => 'the role, access row or rule already matches' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-model', meaning => 'the model is not on this instance (is its module installed?)' },
        { name => 'unknown-implied-group', meaning => 'an implied group does not exist' },
        { name => 'invalid-domain', meaning => 'a rule\'s domain cannot be read, names a field the model lacks, or uses a name Odoo does not provide' },
        { name => 'role-held', meaning => 'the rows of a role whose group is held for one of the reasons above' },
    ];
}

sub params ($class) {
    {   file  => { type => 'path', help => 'one role file (YAML)' },
        dir   => { type => 'path', help => 'a directory: every *.yaml in it is a role file' },
        roles => { type => 'json', help => 'in-process: a list of parsed roles (Odoo::Ops::Core::Access->parse_role) - for a program' },
    };
}

sub read_scope ($class) {
    {   'res.groups'            => ['search_read'],
        'res.groups.privilege'  => ['search_read'],
        'ir.module.category'    => [qw(search_read check_access_rights)],
        'ir.model.data'         => ['search_read'],
        'ir.model'              => ['search_read'],
        'ir.model.access'       => ['search_read'],
        'ir.rule'               => ['search_read'],
    };
}

sub write_scope ($class) {
    {   'res.groups'            => [qw(create write unlink)],
        'res.groups.privilege'  => [qw(create unlink)],
        'ir.module.category'    => [qw(create unlink)],
        'ir.model.data'         => [qw(create unlink)],
        'ir.model.access'       => [qw(create write unlink)],
        'ir.rule'               => [qw(create write unlink)],
    };
}

my $MODULE = '__oom__';
my @PERMS  = qw(read create write unlink);

# --- the role file ----------------------------------------------------------

=head1 CLASS METHODS

=head2 parse_role(\%hash, $what)

A role file's data checked and normalised: C<role>, C<name>, C<implied>, C<access>
(C<model> and the four flags as 1 or 0), C<rules> (C<label>, C<model>, C<domain>,
four flags). Dies as C<config> naming C<$what> and the field at fault.

=cut

sub parse_role ($class, $y, $what = 'role file') {
    my $bad = sub ($m) { Odoo::Error->throw( kind => 'config', message => "$what: $m" ) };
    $bad->('a map was expected') if ref $y ne 'HASH';
    my %known = map { $_ => 1 } qw(role name implied access rules);
    my @unk = grep { !$known{$_} } sort keys %$y;
    $bad->( 'unknown key(s) ' . join( ', ', @unk ) . ' (known: ' . join( ', ', sort keys %known ) . ')' ) if @unk;
    my $role = $y->{role};
    $bad->('role is required (a stable id)') if !defined $role || ref $role || $role eq '';
    $bad->("role '$role' must be letters, digits, dot, dash and underscore") if $role !~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    my $w = "$what: role '$role'";
    $bad = sub ($m) { Odoo::Error->throw( kind => 'config', message => "$w: $m" ) };
    my $name = $y->{name} // $role;
    $bad->('name is a text') if ref $name;
    my $implied = $y->{implied} // [];
    $bad->('implied is a list of group xml ids (module.name)') if ref $implied ne 'ARRAY';
    for my $x (@$implied) { $bad->("implied '" . ( $x // '' ) . "' is not an xml id (module.name)") if ref $x || !defined $x || $x !~ /\A[\w-]+\.[\w.-]+\z/ }
    my ( @access, %seen );
    $bad->('access is a list') if defined $y->{access} && ref $y->{access} ne 'ARRAY';
    for my $a ( @{ $y->{access} // [] } ) {
        $bad->('an access row is a map with a model') if ref $a ne 'HASH' || !defined $a->{model} || ref $a->{model};
        my @u = grep { !/\A(model|read|create|write|unlink)\z/ } sort keys %$a;
        $bad->("access $a->{model}: unknown key(s) " . join( ', ', @u ) ) if @u;
        $bad->("access $a->{model}: not a model name") if $a->{model} !~ /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\z/;
        $bad->("access $a->{model} appears twice") if $seen{ $a->{model} }++;
        my %f = map { $_ => _flag( $a->{$_}, 0 ) } @PERMS;
        for my $p (@PERMS) { $bad->("access $a->{model}: $p is true or false") if !defined $f{$p} }
        push @access, { model => $a->{model}, %f };
    }
    my ( @rules, %lab );
    $bad->('rules is a list') if defined $y->{rules} && ref $y->{rules} ne 'ARRAY';
    for my $r ( @{ $y->{rules} // [] } ) {
        $bad->('a rule is a map with a label') if ref $r ne 'HASH' || !defined $r->{label} || ref $r->{label};
        my $l = $r->{label};
        my @u = grep { !/\A(label|model|domain|read|create|write|unlink)\z/ } sort keys %$r;
        $bad->("rule $l: unknown key(s) " . join( ', ', @u ) ) if @u;
        $bad->("rule '$l': label is letters, digits, dot, dash and underscore") if $l !~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
        $bad->("rule $l appears twice") if $lab{$l}++;
        $bad->("rule $l: model is required") if !defined $r->{model} || ref $r->{model} || $r->{model} !~ /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\z/;
        $bad->("rule $l: domain is required (a text such as \"[('create_uid', '=', user.id)]\")") if !defined $r->{domain} || ref $r->{domain} || $r->{domain} eq '';
        my %f = map { $_ => _flag( $r->{$_}, 1 ) } @PERMS;
        for my $p (@PERMS) { $bad->("rule $l: $p is true or false") if !defined $f{$p} }
        push @rules, { label => $l, model => $r->{model}, domain => $r->{domain}, %f };
    }
    return { role => $role, name => "$name", implied => [@$implied], access => \@access, rules => \@rules };
}

sub _flag ($v, $default) {
    return $default if !defined $v;
    return $v ? 1 : 0 if ref $v;
    my $s = lc "$v";
    return 1 if $s =~ /\A(on|yes|true|1)\z/;
    return 0 if $s =~ /\A(off|no|false|0|)\z/;
    return undef;
}

=head2 load_roles(file => F, dir => D, paths => [...])

The role files read and parsed: one file, every C<*.yaml> of a directory
(sorted), or a list of either. Each role carries C<_file>. Two roles with one
C<role> id are refused by name.

=cut

sub load_roles ($class, %o) {
    my @paths = ( ( defined $o{file} ? $o{file} : () ), ( defined $o{dir} ? $o{dir} : () ), @{ $o{paths} // [] } );
    my @files;
    for my $p (@paths) {
        if ( -d $p ) {
            opendir my $dh, $p or Odoo::Error->throw( kind => 'config', message => "cannot read directory $p: $!" );
            my @y = sort grep { /\.ya?ml\z/ && -f "$p/$_" } readdir $dh;
            closedir $dh;
            Odoo::Error->throw( kind => 'config', message => "roles directory $p holds no *.yaml role file" ) if !@y;
            push @files, map { "$p/$_" } @y;
        }
        elsif ( -f $p ) { push @files, $p }
        else { Odoo::Error->throw( kind => 'config', message => "role file or directory $p does not exist" ) }
    }
    my @roles;
    for my $f (@files) {
        my $y = eval { YAML::PP->new( schema => ['Core'] )->load_file($f) };
        Odoo::Error->throw( kind => 'config', message => "role file $f: " . ( $@ || 'empty' ) ) if !defined $y;
        my $r = $class->parse_role( $y, $f );
        $r->{_file} = $f;
        push @roles, $r;
    }
    $class->check_unique( \@roles );
    return \@roles;
}

=head2 check_unique(\@roles)

Dies as C<usage> when two roles share an id, or when two names map to one
xml id (C<a.b> and C<a-b> both become C<a_b>).

=cut

sub check_unique ($class, $roles) {
    my ( %role, %xml );
    for my $r (@$roles) {
        my $from = $r->{_file} ? " ($r->{_file})" : '';
        Odoo::Error->throw( kind => 'usage', message => "role '$r->{role}' appears twice in this run$from" ) if $role{ $r->{role} }++;
        for my $n ( $class->xml_names($r) ) {
            my $other = $xml{$n}++;
            Odoo::Error->throw( kind => 'usage', message => "role '$r->{role}': two entries map to the xml id $MODULE.$n (dots and dashes become underscores)" ) if $other;
        }
    }
}

sub slug ($class, $s) { $s =~ s/[.\-]/_/gr }

=head2 role_xmlid($role_id)

C<__oom__.role_E<lt>slugE<gt>>, the xml id of a role's group.

=cut

sub role_xmlid ($class, $id) { "$MODULE.role_" . $class->slug($id) }

sub xml_names ($class, $r) {
    my $s = $class->slug( $r->{role} );
    return ( "role_$s", ( map { "access_${s}_" . $class->slug( $_->{model} ) } @{ $r->{access} } ),
        ( map { "rule_${s}_" . $class->slug( $_->{label} ) } @{ $r->{rules} } ) );
}

# --- planning -----------------------------------------------------------------

sub plan ($self) {
    my @in = grep { defined $self->param($_) } qw(file dir roles);
    Odoo::Error->throw( kind => 'usage', message => 'core.access: give file, dir or roles (got ' . ( @in ? "@in" : 'none' ) . ')' ) if !@in;
    my $roles = $self->param('roles') ? $self->param('roles') : $self->load_roles( map { $_ => $self->param($_) } grep { $_ ne 'roles' } @in );
    $self->check_unique($roles);

    my $plan = $self->new_plan;
    $self->{plan} = $plan;
    my $groups  = $self->model('res.groups');
    $self->{gf} = $groups->fields->{privilege_id} ? 'privilege_id' : 'category_id';
    $self->{n}  = 0;

    # every __oom__ xml id, once
    my $imd = $self->model('ir.model.data')->search_read( [ [ 'module', '=', $MODULE ] ], [qw(name model res_id)] );
    $self->{imd}   = { map { $_->{name} => $_ } @$imd };
    $self->{imd_by} = {};
    $self->{imd_by}{ $_->{model} }{ $_->{res_id} } = $_ for @$imd;
    $self->{xml_group} = {};

    $self->_plan_role( $plan, $_ ) for @$roles;
    $plan->set_input_count( $self->{n} );
    $plan->note( 'core.access: ' . scalar(@$roles) . ' role(s); groups are grouped by ' . ( $self->{gf} eq 'privilege_id' ? 'a privilege (19 and later)' : 'a category' ) );
    return $plan;
}

sub _count ($self) { $self->{n}++ }

# the group an xml id (module.name) names, or undef
sub _group_by_xmlid ($self, $xmlid) {
    return $self->{xml_group}{$xmlid} if exists $self->{xml_group}{$xmlid};
    my ( $module, $name ) = split /\./, $xmlid, 2;
    my $rows = $self->model('ir.model.data')->search_read(
        [ [ 'module', '=', $module ], [ 'name', '=', $name ], [ 'model', '=', 'res.groups' ] ], ['res_id'] );
    return $self->{xml_group}{$xmlid} = @$rows == 1 ? 0 + $rows->[0]{res_id} : undef;
}

# records of a model by id, with fields, active ones and archived
sub _records ($self, $model, $ids, $fields) {
    return {} if !@$ids;
    my $m = $self->model($model);
    my @dom = ( [ 'id', 'in', [@$ids] ] );
    push @dom, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] if $m->fields->{active};
    return { map { $_->{id} => $_ } @{ $m->search_read( \@dom, $fields ) } };
}

# A support record all roles share: found by its xml id, else created (with its
# xml id row). Returns an id, or { '$ref' => name } when this plan creates it.
sub _support ($self, $plan, $xmlname, $model, $vals_cb) {
    return $self->{support}{$xmlname} if exists $self->{support}{$xmlname};
    my $imd = $self->{imd}{$xmlname};
    my $have = $imd && $imd->{model} eq $model ? $self->_records( $model, [ $imd->{res_id} ], ['id'] )->{ $imd->{res_id} } : undef;
    return $self->{support}{$xmlname} = 0 + $imd->{res_id} if $have;
    $plan->add( bucket => 'xmlid-remove', action => 'unlink', model => 'ir.model.data', id => $imd->{id}, support => 1,
        key => "xmlid:$xmlname", before => { module => $MODULE, name => $xmlname, model => $imd->{model}, res_id => $imd->{res_id} } ) if $imd;
    my $ref = "oom:$xmlname";
    $plan->add( bucket => 'support-create', action => 'create', model => $model, support => 1, ref => $ref, key => "support:$xmlname", vals => $vals_cb->() );
    $self->_xmlid( $plan, $xmlname, $model, { '$ref' => $ref } );
    return $self->{support}{$xmlname} = { '$ref' => $ref };
}

sub _xmlid ($self, $plan, $name, $model, $res_id, %o) {
    $plan->add( bucket => 'xmlid-create', action => 'create', model => 'ir.model.data', support => 1, key => "xmlid:$name",
        vals => { module => $MODULE, name => $name, model => $model, res_id => $res_id, noupdate => JSON::PP::true } );
}

# the vals that put a group in the shared category / privilege (made on first need)
sub _container ($self, $plan) {
    # An administrator may not create an ir.module.category over RPC (read only for group_erp_manager on
    # 16, 18 and 19, probed live 2026-10-14): the category is made when the instance lets this user, else
    # the group goes without one (it shows under "Other" on 16 and 18; on 19 the privilege is the grouping).
    my $cat;
    if ( $self->{imd}{category_external} || $self->_can_create('ir.module.category') ) {
        $cat = $self->_support( $plan, 'category_external', 'ir.module.category', sub { { name => 'External applications' } } );
    }
    elsif ( !$self->{noted_category}++ ) {
        $plan->note('ir.module.category cannot be created by this user on this instance: the groups are made without a category');
    }
    return ( $cat ? ( category_id => $cat ) : () ) if $self->{gf} eq 'category_id';
    my $priv = $self->_support( $plan, 'privilege_external', 'res.groups.privilege', sub { { name => 'External applications', ( $cat ? ( category_id => $cat ) : () ) } } );
    return ( privilege_id => $priv );
}

sub _can_create ($self, $model) {
    my $ok = eval { $self->model($model)->call( 'check_access_rights', [], operation => 'create', raise_exception => JSON::PP::false ) };
    return $ok ? 1 : 0;
}

sub _plan_role ($self, $plan, $r) {
    my $role  = $r->{role};
    my $s     = $self->slug($role);
    my $gname = "role_$s";
    my $held  = sub ($bucket, $key, $reason) { $self->_count; $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $reason ) };

    # the models the role names, in one read
    my %need = map { $_ => 1 } ( ( map { $_->{model} } @{ $r->{access} } ), ( map { $_->{model} } @{ $r->{rules} } ) );
    my %model_id;
    if (%need) {
        my $rows = $self->model('ir.model')->search_read( [ [ 'model', 'in', [ sort keys %need ] ] ], [qw(model)] );
        %model_id = map { $_->{model} => 0 + $_->{id} } @$rows;
    }

    # the implied groups
    my ( @implied, @unknown );
    for my $x ( @{ $r->{implied} } ) {
        my $id = $self->_group_by_xmlid($x);
        defined $id ? push @implied, $id : push @unknown, $x;
    }

    # the group
    my ( $gid, $gcur );
    my $gimd = $self->{imd}{$gname};
    if ( $gimd && $gimd->{model} eq 'res.groups' ) {
        $gcur = $self->_records( 'res.groups', [ $gimd->{res_id} ], [qw(name implied_ids)] )->{ $gimd->{res_id} };
        $gid  = 0 + $gimd->{res_id} if $gcur;
    }
    my $gkey = "role:$role";
    my $group_ok = 1;
    if (@unknown) {
        $held->( 'unknown-implied-group', $gkey, "role '$role' implies " . join( ', ', map {"'$_'"} @unknown ) . ', which this instance does not have (module not installed?)' );
        $group_ok = 0;
    }
    elsif ( !$gcur ) {
        $self->_count;
        my %cont = $self->_container($plan);
        $plan->add( bucket => 'xmlid-remove', action => 'unlink', model => 'ir.model.data', id => $gimd->{id}, support => 1, key => "xmlid:$gname",
            before => { module => $MODULE, name => $gname, model => $gimd->{model}, res_id => $gimd->{res_id} } ) if $gimd;
        my $ref = "oom:group:$role";
        $plan->add( bucket => 'role-create', action => 'create', model => 'res.groups', key => $gkey, ref => $ref,
            vals => { name => $r->{name}, ( @implied ? ( implied_ids => [ [ 6, 0, [@implied] ] ] ) : () ), %cont } );
        $self->_xmlid( $plan, $gname, 'res.groups', { '$ref' => $ref } );
        $gid = { '$ref' => $ref };
    }
    else {
        $self->_count;
        my %set;
        my %before;
        if ( $gcur->{name} ne $r->{name} ) { $set{name} = $r->{name}; $before{name} = $gcur->{name} }
        my %have = map { $_ => 1 } @{ $gcur->{implied_ids} // [] };
        my %want = map { $_ => 1 } @implied;
        if ( join( ',', sort { $a <=> $b } keys %have ) ne join( ',', sort { $a <=> $b } keys %want ) ) {
            $set{implied_ids} = [ [ 6, 0, [@implied] ] ];
            $before{implied_ids} = [ @{ $gcur->{implied_ids} // [] } ];
        }
        if (%set) { $plan->add( bucket => 'role-update', action => 'write', model => 'res.groups', id => $gid, key => $gkey, vals => \%set, before => \%before ) }
        else      { $plan->add( bucket => 'unchanged', action => 'skip', id => $gid, key => $gkey ) }
    }

    if ( !$group_ok ) {
        for my $a ( @{ $r->{access} } ) { $held->( 'role-held', "access:$role:$a->{model}", "the group of role '$role' is held (unknown implied group)" ) }
        for my $x ( @{ $r->{rules} } )  { $held->( 'role-held', "rule:$role:$x->{label}",  "the group of role '$role' is held (unknown implied group)" ) }
        return;
    }

    my $real = ref $gid ? undef : $gid;    # an id when the group exists already
    my ( %want_access, %want_rule );

    # access rows
    my @arows = grep { defined $_ } map { $self->{imd}{ "access_${s}_" . $self->slug( $_->{model} ) } } @{ $r->{access} };
    my $acur = $self->_records( 'ir.model.access', [ map { $_->{res_id} } grep { $_->{model} eq 'ir.model.access' } @arows ],
        [qw(name model_id group_id perm_read perm_create perm_write perm_unlink active)] );
    for my $a ( @{ $r->{access} } ) {
        my $xn  = "access_${s}_" . $self->slug( $a->{model} );
        $want_access{$xn} = 1;
        my $key = "access:$role:$a->{model}";
        $self->_count;
        my $mid = $model_id{ $a->{model} };
        if ( !$mid ) { $plan->add( bucket => 'unknown-model', action => 'hold', key => $key, reason => "no model '$a->{model}' on this instance (is its module installed?)" ); next }
        my %perm = map { ( "perm_$_" => ( $a->{$_} ? JSON::PP::true : JSON::PP::false ) ) } @PERMS;
        my $vals = { name => "oom:$role:$a->{model}", model_id => $mid, group_id => $gid, %perm };
        my $imd = $self->{imd}{$xn};
        my $cur = $imd && $imd->{model} eq 'ir.model.access' ? $acur->{ $imd->{res_id} } : undef;
        if ( !$cur ) {
            $plan->add( bucket => 'xmlid-remove', action => 'unlink', model => 'ir.model.data', id => $imd->{id}, support => 1, key => "xmlid:$xn",
                before => { module => $MODULE, name => $xn, model => $imd->{model}, res_id => $imd->{res_id} } ) if $imd;
            my $ref = "oom:$xn";
            $plan->add( bucket => 'access-create', action => 'create', model => 'ir.model.access', key => $key, ref => $ref, vals => $vals );
            $self->_xmlid( $plan, $xn, 'ir.model.access', { '$ref' => $ref } );
            next;
        }
        my ( %set, %before );
        my $gcur_id = ref $cur->{group_id} ? $cur->{group_id}[0] : $cur->{group_id};
        my $mcur_id = ref $cur->{model_id} ? $cur->{model_id}[0] : $cur->{model_id};
        if ( $cur->{name} ne $vals->{name} ) { $set{name} = $vals->{name}; $before{name} = $cur->{name} }
        if ( ( $mcur_id // 0 ) != $mid ) { $set{model_id} = $mid; $before{model_id} = $cur->{model_id} }
        if ( ref $gid || ( $gcur_id // 0 ) != $gid ) { $set{group_id} = $gid; $before{group_id} = $cur->{group_id} }
        for my $p (@PERMS) {
            my $f = "perm_$p";
            if ( ( $cur->{$f} ? 1 : 0 ) != $a->{$p} ) { $set{$f} = $vals->{$f}; $before{$f} = $cur->{$f} }
        }
        if ( !$cur->{active} ) { $set{active} = JSON::PP::true; $before{active} = $cur->{active} }
        if (%set) { $plan->add( bucket => 'access-update', action => 'write', model => 'ir.model.access', id => $cur->{id}, key => $key, vals => \%set, before => \%before ) }
        else      { $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key ) }
    }

    # rules
    my @rrows = grep { defined $_ } map { $self->{imd}{ "rule_${s}_" . $self->slug( $_->{label} ) } } @{ $r->{rules} };
    my $rcur = $self->_records( 'ir.rule', [ map { $_->{res_id} } grep { $_->{model} eq 'ir.rule' } @rrows ],
        [qw(name model_id domain_force groups perm_read perm_create perm_write perm_unlink active)] );
    for my $x ( @{ $r->{rules} } ) {
        my $xn  = "rule_${s}_" . $self->slug( $x->{label} );
        $want_rule{$xn} = 1;
        my $key = "rule:$role:$x->{label}";
        $self->_count;
        my $mid = $model_id{ $x->{model} };
        if ( !$mid ) { $plan->add( bucket => 'unknown-model', action => 'hold', key => $key, reason => "no model '$x->{model}' on this instance (is its module installed?)" ); next }
        if ( my $why = $self->domain_problem( $x->{domain}, $x->{model} ) ) {
            $plan->add( bucket => 'invalid-domain', action => 'hold', key => $key, reason => "Invalid domain: $why" );
            next;
        }
        my %perm = map { ( "perm_$_" => ( $x->{$_} ? JSON::PP::true : JSON::PP::false ) ) } @PERMS;
        my $vals = { name => "oom:$role:$x->{label}", model_id => $mid, domain_force => $x->{domain}, groups => [ [ 6, 0, [$gid] ] ], %perm };
        my $imd = $self->{imd}{$xn};
        my $cur = $imd && $imd->{model} eq 'ir.rule' ? $rcur->{ $imd->{res_id} } : undef;
        if ( !$cur ) {
            $plan->add( bucket => 'xmlid-remove', action => 'unlink', model => 'ir.model.data', id => $imd->{id}, support => 1, key => "xmlid:$xn",
                before => { module => $MODULE, name => $xn, model => $imd->{model}, res_id => $imd->{res_id} } ) if $imd;
            my $ref = "oom:$xn";
            $plan->add( bucket => 'rule-create', action => 'create', model => 'ir.rule', key => $key, ref => $ref, vals => $vals );
            $self->_xmlid( $plan, $xn, 'ir.rule', { '$ref' => $ref } );
            next;
        }
        my ( %set, %before );
        my $mcur_id = ref $cur->{model_id} ? $cur->{model_id}[0] : $cur->{model_id};
        if ( $cur->{name} ne $vals->{name} ) { $set{name} = $vals->{name}; $before{name} = $cur->{name} }
        if ( ( $mcur_id // 0 ) != $mid ) { $set{model_id} = $mid; $before{model_id} = $cur->{model_id} }
        if ( ( $cur->{domain_force} || '' ) ne $x->{domain} ) { $set{domain_force} = $x->{domain}; $before{domain_force} = $cur->{domain_force} }
        if ( ref $gid || join( ',', sort { $a <=> $b } @{ $cur->{groups} // [] } ) ne $gid ) { $set{groups} = [ [ 6, 0, [$gid] ] ]; $before{groups} = [ @{ $cur->{groups} // [] } ] }
        for my $p (@PERMS) {
            my $f = "perm_$p";
            if ( ( $cur->{$f} ? 1 : 0 ) != $x->{$p} ) { $set{$f} = $vals->{$f}; $before{$f} = $cur->{$f} }
        }
        if ( !$cur->{active} ) { $set{active} = JSON::PP::true; $before{active} = $cur->{active} }
        if (%set) { $plan->add( bucket => 'rule-update', action => 'write', model => 'ir.rule', id => $cur->{id}, key => $key, vals => \%set, before => \%before ) }
        else      { $plan->add( bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => $key ) }
    }

    # removals: rows of this role's group that carry an __oom__ xml id the file no longer names
    if ($real) {
        my $by = $self->{imd_by};
        my $am = $self->model('ir.model.access');
        my $rows = $am->search_read( [ [ 'group_id', '=', $real ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [qw(name model_id group_id perm_read perm_create perm_write perm_unlink active)] );
        for my $row (@$rows) {
            my $imd = $by->{'ir.model.access'}{ $row->{id} } or next;
            next if $imd->{name} !~ /\Aaccess_/ || $want_access{ $imd->{name} };
            $self->_count;
            my $mname = ref $row->{model_id} ? $row->{model_id}[1] : '';
            $plan->add( bucket => 'access-remove', action => 'custom', handler => $self->op_name, kind => 'remove', model => 'ir.model.access', id => $row->{id},
                key => "access-remove:$role:$imd->{name}", before => _snap($row), vals => { xmlid => $imd->{name}, imd_id => $imd->{id} },
                reason => "the role file no longer lists this access row ($row->{name}); it is removed" );
        }
        my $rm = $self->model('ir.rule');
        $rows = $rm->search_read( [ [ 'groups', 'in', [$real] ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [qw(name model_id domain_force groups perm_read perm_create perm_write perm_unlink active)] );
        for my $row (@$rows) {
            my $imd = $by->{'ir.rule'}{ $row->{id} } or next;
            next if $imd->{name} !~ /\Arule_/ || $want_rule{ $imd->{name} };
            $self->_count;
            $plan->add( bucket => 'rule-remove', action => 'custom', handler => $self->op_name, kind => 'remove', model => 'ir.rule', id => $row->{id},
                key => "rule-remove:$role:$imd->{name}", before => _snap($row), vals => { xmlid => $imd->{name}, imd_id => $imd->{id} },
                reason => "the role file no longer lists this rule ($row->{name}); it is removed" );
        }
    }
}

# a read row as a before-image: as read (the runner compares it with a fresh read), without its id
sub _snap ($row) { return { map { $_ => $row->{$_} } grep { $_ ne 'id' } keys %$row } }

# --- the domain check made at planning ---------------------------------------------

my %OP = map { $_ => 1 } ( '=', '!=', '<', '>', '<=', '>=', '=?', '=like', '=ilike', 'like', 'ilike', 'not like', 'not ilike',
    'in', 'not in', 'child_of', 'parent_of', 'any', 'not any', 'any!', 'not any!' );
my %NAME = map { $_ => 1 } qw(user company_id company_ids allowed_company_ids time datetime date relativedelta context_today uid
    True False None and or not in is if else for);

=head2 domain_problem($domain, $model)

A reason Odoo would refuse the domain (the form of Odoo's own message), or undef.
Instance side: field names are checked against C<fields_get> following relations.

=cut

sub domain_problem ($self, $domain, $model) {
    my $d = $domain =~ s/\A\s+|\s+\z//gr;
    my @str;
    ( my $bare = $d ) =~ s/('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")/push @str, $1; ' S '/gse;
    return 'string literal was never closed' if $bare =~ /['"]/;
    my @stack;
    my %close = ( ')' => '(', ']' => '[', '}' => '{' );
    for my $ch ( split //, $bare ) {
        if ( $ch =~ /[\[({]/ ) { push @stack, $ch }
        elsif ( $ch =~ /[\])}]/ ) {
            my $o = pop @stack;
            return "closing parenthesis '$ch' does not match opening parenthesis" if !defined $o || $o ne $close{$ch};
        }
    }
    return "'" . $stack[-1] . "' was never closed" if @stack;
    return 'Domains to normalize must have a \'domain\' form: a list or tuple of domain components' if $d !~ /\A\[.*\]\z/s;
    ( my $names = $bare ) =~ s/\.\s*[A-Za-z_]\w*//g;     # user.id: id is an attribute
    $names =~ s/\b[A-Za-z_]\w*\s*=(?!=)//g;              # keyword arguments
    for my $w ( $names =~ /\b([A-Za-z_]\w*)\b/g ) {
        return "NameError(\"name '$w' is not defined\") while evaluating" if !$NAME{$w} && $w ne 'S';
    }
    # leaves: ('field.path', 'op', ...)
    while ( $d =~ /\(\s*'([A-Za-z_][\w.]*)'\s*,\s*'([^']*)'\s*,/g ) {
        my ( $path, $op ) = ( $1, $2 );
        return "Invalid operator '$op' in leaf ('$path', '$op', ...)" if !$OP{ lc $op };
        my ( $m, @seg ) = ( $model, split /\./, $path );
        while (@seg) {
            my $seg = shift @seg;
            my $f   = eval { $self->model($m)->fields } or last;
            my $def = $f->{$seg};
            return "Invalid field $m.$seg in leaf ('$path', '$op', ...)" if !$def;
            last if !@seg;
            return "Invalid field $m.$seg in leaf ('$path', '$op', ...): not a relation" if !$def->{relation};
            $m = $def->{relation};
        }
    }
    return undef;
}

# --- apply of the custom changes ---------------------------------------------------

# kind remove: unlink the row (and what is left of its xml id); kind restore: recreate it
sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    my $m    = $client->model( $c->{model} );
    if ( $kind eq 'remove' ) {
        $m->unlink( [ $c->{id} ] );
        my $imd = $client->model('ir.model.data');
        my $left = $imd->search_read( [ [ 'module', '=', $MODULE ], [ 'name', '=', $c->{vals}{xmlid} ] ], ['id'] );
        $imd->unlink( [ map { $_->{id} } @$left ] ) if @$left;
        my $gone = $m->search_read( [ [ 'id', '=', $c->{id} ], ( $m->fields->{active} ? [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] : () ) ], ['id'] );
        return { id => $c->{id}, after => ( @$gone ? undef : { removed => $c->{id} } ) };
    }
    if ( $kind eq 'restore' ) {
        my %v = %{ $c->{vals} };
        my $xmlid = delete $v{xmlid};
        my $id = $m->create( \%v );
        $id = $id->[0] if ref $id eq 'ARRAY';
        $client->model('ir.model.data')->create( { module => $MODULE, name => $xmlid, model => $c->{model}, res_id => $id, noupdate => JSON::PP::true } );
        my $row = $m->read_one( $id, [ sort keys %v ] );
        return { id => $id, after => $row };
    }
    Odoo::Error->throw( kind => 'usage', message => "core.access cannot apply kind '$kind'" );
}

# a removal is undone by creating the row again from its before-image; a restore by removing it
sub undo_custom ($class, $entry) {
    my $kind = $entry->{kind} // '';
    if ( $kind eq 'remove' ) {
        my %b = %{ $entry->{before} // {} };
        my %v = ( %b, xmlid => $entry->{vals}{xmlid} );
        $v{groups} = [ [ 6, 0, [ @{ $b{groups} } ] ] ] if ref $b{groups} eq 'ARRAY';
        for my $f (qw(model_id group_id)) { $v{$f} = $v{$f}[0] if ref $v{$f} eq 'ARRAY' }
        return ( { action => 'custom', handler => 'core.access', kind => 'restore', bucket => 'undo-remove', model => $entry->{model},
                key => $entry->{key}, vals => \%v, reason => 'recreates the row the run removed, from its before-image' } );
    }
    if ( $kind eq 'restore' ) {
        return ( { action => 'custom', handler => 'core.access', kind => 'remove', bucket => 'undo-restore', model => $entry->{model}, id => $entry->{id},
                key => $entry->{key}, vals => { xmlid => $entry->{vals}{xmlid} }, reason => 'removes the row the revert recreated' } );
    }
    return ( undef, "core.access cannot undo kind '$kind'" );
}

1;

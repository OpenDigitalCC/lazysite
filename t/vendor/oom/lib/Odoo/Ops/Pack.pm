package Odoo::Ops::Pack;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use File::Spec;
use Time::HiRes ();
use JSON::PP ();
use YAML::PP ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Pack - the contract a pack stands on, and the loading of packs

=head1 SYNOPSIS

    package Odoo::Pack::CrmPage::Lead;
    use parent 'Odoo::Ops::Operation';
    use Odoo::Error;
    use Odoo::Ops::Pack;

    sub op_name ($class) { 'crm_page.lead' }
    sub report  ($self)  {
        return Odoo::Ops::Pack->read( $self, 'core.get', model => 'crm.lead', id => $self->param('id'), fields => 'name' );
    }

=head1 DESCRIPTION

A pack is a directory of operations for a kind of app or a customer, released
on its own and loaded at run time from C<pack_dirs> (see F<packs/README.md>
and the Packs section of F<docs/OPS.md>). It composes OOM's primitives. It
never changes core behaviour, and core never imports a pack.

=head1 THE CONTRACT

A pack may use only this interface, and a core release that keeps it cannot
break a pack. The pack's C<oom_min> names the contract's version.

=over 4

=item * L<Odoo::Ops::Operation> and the methods its POD documents: the class
methods C<op_name>, C<summary>, C<pack>, C<invariant_packs>, C<params>,
C<read_scope>, C<write_scope>, C<buckets>, C<holds>, C<fields>,
C<models_touched>, and on an instance C<ctx>, C<client>, C<param>,
C<all_params>, C<model>, C<new_plan>, C<fields_for>, C<report> and C<plan>; and for an
operation that declares C<acts_for> (see L<Odoo::Ops::Acting>) the class method C<acts_for> and, on an instance,
C<person>, C<service_client> and C<own>.

=item * The change kinds of L<Odoo::Ops::Plan>: C<create>, C<write>,
C<unlink>, C<call>, C<custom>, C<skip> and C<hold>, with the keys the
operation contract names (C<bucket>, C<key>, C<model>, C<id>, C<vals>,
C<before>, C<method>, C<ids>, C<kwargs>, C<verify>, C<unique_by>,
C<readback>, C<reason>). A pack builds plans with C<< $self->new_plan >> and
C<< $plan->add >> and C<< $plan->note >>.

=item * L<Odoo::Error>, to throw C<usage>, C<config>, C<fault> and
C<refused> errors.

=item * The helpers of L<Odoo::Ops>: C<json> and C<iso_time>.

=item * This module's C<read>, the composition helper below: a pack calls a
core read operation through it, never by loading the core module.

=item * This module's C<wizard> and C<action> (the changes of C<core.wizard> and
C<core.action> in a pack's plan), C<has_groups> and C<may> (what the login may
do), below.

=item * This module's C<group> and C<page> (a grouped and a paged read), C<reconcile>,
C<unreconcile>, C<statement_undo> and C<mail> (the changes of C<account.reconcile>,
C<account.unreconcile>, C<account.statement_undo> and C<core.mail> in a pack's plan) and
C<needs> (what the operation declares to call them), below.

=item * Its own namespace, C<Odoo::Pack::E<lt>NameE<gt>>.

=back

Everything else under C<Odoo::> is core's. A C<use>, C<require> or fully
qualified name of any other C<Odoo::> module, and any call into a core
C<_private> sub, fails the lint (C<t/66-packs.t>, L</lint_pack>).

=head1 METHODS

=head2 read($op, $name, %params)

Runs the read operation C<$name> (C<core.get>, C<core.read>, C<core.report>) for the
operation C<$op>, on its context and inside its scope, and answers its
report. The operation C<$op> declares in its C<read_scope> the models the
composed read touches. A write operation is refused: a pack's writes are its
own plans, applied by the runner like any other.

A pack read that opts in to the data cache (L<Odoo::Cache::Data>) declares C<max_age> among its
parameters and passes it on, C<< max_age => $self->param('max_age') >>, with C<pricelist> where it prices; its
read scope then holds the C<read_group> of the model. The reads the core operation made are
summed into the pack operation's audit line (C<cached>, and the greatest C<age>). A read that names its own audit detail (C<core.report> says the report and the
bytes, never the content) is written to the audit trail as a read of its own.
C<core.report> with C<inline =E<gt> 1> returns each document as C<content_base64>
in its rows, so a pack hands a rendered pdf on without a render of its own. The
calling operation declares in its C<read_scope> the models the report reads
(C<ir.actions.report>, C<ir.model.data>, C<ir.attachment> and the model it prints).

=cut

sub read ($class, $op, $name, %params) { return $class->_read( $op, $op->ctx, $name, %params ) }

sub _read ($class, $op, $ctx, $name, %params) {
    require Odoo::Ops::Registry;
    my $cls = Odoo::Ops::Registry->new->class_for($name);
    Odoo::Error->throw( kind => 'usage', message => "pack operation " . $op->op_name . " composes $name, which is not a read" )
        if $cls->writes || $cls->immediate;
    my $inner  = $cls->new( ctx => $ctx, params => \%params );
    my $report = $inner->report;
    # the composing operation's audit line says whether any of its reads came from the data cache
    if ( ref $report eq 'HASH' && defined $report->{cached} ) {
        my $n = $op->{cache_note} //= { cached => 0 };
        $n->{cached} = 1 if $report->{cached};
        $n->{age} = $report->{age} if $report->{cached} && ( !defined $n->{age} || $report->{age} > $n->{age} );
    }
    $inner->_audit_read( $inner->scope_for('read'), $report ) if $inner->can('audit_detail');
    return $report;
}

=head2 wizard($op, $plan, %params) / action($op, $plan, %params)

Adds to the plan C<$plan> of the pack operation C<$op> the changes
C<core.wizard> or C<core.action> would plan for C<%params> (their own
parameters: C<model>, C<for>, C<records>, C<values>, C<method>, C<context> for a
wizard; C<model>, C<record> or C<records>, C<method>, C<context>, C<args> for an
action), and answers how many changes it added (the rows to count in the
plan's C<input_count>). The change is the one the core operation plans: a wizard
is created and a method called on it, an action is a public method called on
the records or on the model, and the same checks apply (the method and the
wizard must be listed in the model's behaviour file, the module installed). So
the apply journals it, reads it back and names what Odoo made, and
C<oom-ops revert> takes it back by the behaviour file's C<undo>, exactly as for
C<core.wizard> and C<core.action>. The plan's notes are carried over.

    my $n = Odoo::Ops::Pack->wizard( $self, $plan,
        model => 'hr.holidays.cancel.leave', for => 'hr.leave', records => $id,
        values => { reason => 'booked in error' }, method => 'action_cancel_leave' );

The pack operation declares what the change calls, as for any plan: in
C<read_scope> the model acted on (C<search_read>, C<read>) and
C<ir.module.module> (C<search_read>); in C<write_scope> the wizard model
(C<create> and the method) and, for an action, the model and the method; and
the C<buckets> the change lands in (C<wizard>, C<call>, C<unknown-record>; the
option C<bucket =E<gt> NAME> puts every change of this call in the named
bucket instead). A call outside the scope is refused C<scope> at plan time,
naming it.

=cut

sub wizard ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'core.wizard', %params ) }
sub action ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'core.action', %params ) }

sub _compose ($class, $op, $plan, $name, %params) {
    require Odoo::Ops::Registry;
    my $bucket = delete $params{bucket};
    my $cls    = Odoo::Ops::Registry->new->class_for($name);
    my $inner  = $cls->new( ctx => $op->ctx, params => \%params )->plan;
    my $n = 0;
    for my $c ( @{ $inner->changes } ) {
        my %c = %$c;
        delete $c{seq};
        $c{bucket} = $bucket if defined $bucket;
        $plan->add(%c);
        $n++;
    }
    $plan->note($_) for @{ $inner->notes };
    return $inner->input_count;
}

=head2 group($op, %params) / page($op, %params)

C<group> runs C<core.group> (Odoo's C<read_group>: counts and sums per group, each group with the domain that selects
it) for the operation C<$op> and answers its report; C<page> runs C<core.read> and answers it, with C<offset> and
C<total> for a result larger than one answer (the report's C<total> is the whole domain's size, so the last page is
the one where C<offset> plus C<count> reaches it; page on an order that ends in C<id>). Both are C<read>
under another name, so the rules of C<read> hold. The operation declares in its C<read_scope> the model's
C<read_group> (for C<group>), or C<search_read> and C<search_count> (for C<page>, which asks for the total).

    my $g = Odoo::Ops::Pack->group( $self, model => 'account.move.line', groupby => 'partner_id,date:month',
        fields => 'balance:sum', domain => [ [ 'parent_state', '=', 'posted' ] ] );
    for my $row ( @{ $g->{rows} } ) {      # $row->{__domain} selects the group's records
        my $items = Odoo::Ops::Pack->page( $self, model => 'account.move.line', domain => $row->{__domain},
            fields => 'name,balance', order => 'date, id', limit => 80, offset => 0 );
    }

=cut

sub group ($class, $op, %params) { return $class->read( $op, 'core.group', %params ) }
sub page  ($class, $op, %params) { return $class->read( $op, 'core.read',  %params ) }

=head2 reconcile($op, $plan, %params) / unreconcile / statement_undo / mail

Add to the plan C<$plan> of the pack operation C<$op> the changes C<account.reconcile>, C<account.unreconcile>,
C<account.statement_undo> or C<core.mail> would plan for C<%params> (their own parameters: C<lines> for the three
account operations; C<model>, C<record> or C<records>, C<template>, C<reports>, C<partners> for C<mail>, or its
C<items> rows), and answer how many rows they planned (the rows to count in the plan's C<input_count>). The change
is the one the core operation plans, with its holds, so the apply journals it, reads it back and names what Odoo
did, and C<oom-ops revert> takes it back as the core operation does: an C<account.reconcile> by removing the partial
reconciles it made, an C<account.unreconcile> by reconciling the items again, a C<core.mail> and an
C<account.statement_undo> never (they are held C<irreversible>). The option C<bucket =E<gt> NAME> puts every change
of the call in the named bucket.

    my $n = Odoo::Ops::Pack->reconcile( $self, $plan, lines => [ 696, 698 ] );
    $n    = Odoo::Ops::Pack->mail( $self, $plan, model => 'account.move', records => [ 12, 13 ],
        template => 'account.email_template_edi_invoice', reports => ['account.account_invoices'] );

The pack operation declares what the change calls, as for any plan, from C<needs>:

    sub read_scope  { Odoo::Ops::Pack->needs( 'account.reconcile' )->{read} }
    sub write_scope { Odoo::Ops::Pack->needs( 'account.reconcile' )->{write} }

and the buckets the change lands in (C<reconcile>, C<unreconcile>, C<undo>, C<mail>, and their holds, which the
operation's C<holds> lists). A call outside the scope is refused C<scope> at plan time, naming it. The account
operations refuse a series other than 16 and 18 (C<series>) and C<core.mail> likewise.

=cut

sub reconcile      ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'account.reconcile',        %params ) }
sub unreconcile    ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'account.unreconcile',      %params ) }
sub statement_undo ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'account.statement_undo',   %params ) }
sub mail           ($class, $op, $plan, %params) { return $class->_compose( $op, $plan, 'core.mail',                %params ) }

=head2 needs($name, %options)

What a pack operation declares to call the core operation C<$name> (one of C<account.reconcile>,
C<account.unreconcile>, C<account.statement_undo>, C<core.mail>, C<core.group>, C<core.read>), as
C<< { read => { model => [methods] }, write => { model => [methods] } } >> with physical model names, ready to merge
into the operation's C<read_scope> and C<write_scope>. C<core.mail> and C<core.read> also need the model of the
records: C<< model =E<gt> 'account.move' >> adds C<read> and C<search_read> on it, and with C<core.mail>
C<< report_model =E<gt> 'res.partner' >> does so for the model a C<report:ID> attachment is rendered for. C<core.read>
adds C<search_count> with C<< total =E<gt> 1 >>, and C<core.group> needs C<model>. An unknown name is C<usage>.

=cut

my %NEEDS = map { $_ => 1 } qw(account.reconcile account.unreconcile account.statement_undo core.mail core.group core.read);

sub needs ($class, $name, %o) {
    Odoo::Error->throw( kind => 'usage', message => 'needs: ' . ( defined $name ? "'$name'" : 'no name' ) . ' is not an operation a pack composes here (' . join( ', ', sort keys %NEEDS ) . ')' )
        if !defined $name || !$NEEDS{$name};
    require Odoo::Ops::Registry;
    my $cls = Odoo::Ops::Registry->new->class_for($name);
    my ( %read, %write );
    my $add = sub ($h, $m, @methods) { $h->{$m}{$_} = 1 for @methods };
    if ( $name eq 'core.read' || $name eq 'core.group' ) {
        Odoo::Error->throw( kind => 'usage', message => "needs: $name needs model => 'the.model'" ) if !defined $o{model};
        $add->( \%read, $o{model}, $name eq 'core.group' ? 'read_group' : ( 'search_read', ( $o{total} ? ('search_count') : () ) ) );
    }
    else {
        my ( $r, $w ) = ( $cls->read_scope, $cls->write_scope );
        $add->( \%read,  $_, @{ $r->{$_} } ) for keys %$r;
        $add->( \%write, $_, @{ $w->{$_} } ) for keys %$w;
        $add->( \%write, $_, 'read' ) for keys %$w;
        if ( $name eq 'core.mail' ) {
            Odoo::Error->throw( kind => 'usage', message => "needs: core.mail needs model => 'the.model' (the model of the records)" ) if !defined $o{model};
            $add->( \%read, $_, qw(read search_read) ) for grep { defined } $o{model}, $o{report_model};
        }
    }
    return { read => { map { $_ => [ sort keys %{ $read{$_} } ] } keys %read }, write => { map { $_ => [ sort keys %{ $write{$_} } ] } keys %write } };
}

=head2 has_groups($op, @xmlids)

Whether the person the operation runs as holds each group: C<core.has_groups>
as a library call, answering C<< { groups => { XMLID => 1|0 } } >>
(see L<Odoo::Ops::Core::HasGroups>). The operation declares C<res.users>
C<has_group> in its C<read_scope>.

=cut

sub has_groups ($class, $op, @groups) {
    return $class->read( $op, 'core.has_groups', groups => [@groups] );
}

=head2 may($op, $model, $operation)

Whether the person the operation runs as may C<read>, C<write>, C<create> or
C<unlink> the physical model C<$model>: 1 or 0, as Odoo's own access check
answers for that login, never a guess. The question is Odoo's public one
and differs by series: on 16 and 17 C<check_access_rights(operation,
raise_exception=False)> on the model, from 18 C<has_access(operation)> on the
empty recordset (which replaces it; 18 and 19 keep the old name as a deprecated
alias, and it is not used there). It answers for the model's access list, the
groups of the login; a record rule restricts which records of the model, and
C<may> does not say which. A model the server does not have is Odoo's own fault,
raised as C<fault>.

The operation declares the call in its C<read_scope>, both names, since the
series is the server's: C<< 'hr.leave' =E<gt> [ 'check_access_rights', 'has_access' ] >>.

=cut

my %ACCESS_OP = map { $_ => 1 } qw(read write create unlink);

sub may ($class, $op, $model, $operation) {
    Odoo::Error->throw( kind => 'usage', message => 'may: the model must be a physical model name (with a dot), got ' . ( defined $model ? "'$model'" : 'undef' ) )
        if !defined $model || ref $model || $model !~ /\A[a-z0-9_]+(?:\.[a-z0-9_]+)+\z/;
    Odoo::Error->throw( kind => 'usage', message => 'may: the operation must be one of read, write, create, unlink, got ' . ( defined $operation ? "'$operation'" : 'undef' ),
        fix => "ask may( \$op, '$model', 'read' )" )
        if !defined $operation || !$ACCESS_OP{$operation};
    my $client = $op->client;
    my $answer = $client->server_series >= 18
        ? $client->execute_kw( $model, 'has_access', [ [], $operation ], {} )
        : $client->execute_kw( $model, 'check_access_rights', [$operation], { raise_exception => JSON::PP::false } );
    return $answer ? 1 : 0;
}

=head2 service_read($op, $name, %params)

As C<read>, for an operation that declares C<acts_for>: the core read runs as the service credential, on its
client and inside the operation's scope (the guard of the service credential is held to the same scope). For
the reads the person may not make (prices, taxes, stock). The data cache keeps the files of the service login.
The caller scopes what it reads to the person.

=cut

sub service_read ($class, $op, $name, %params) {
    Odoo::Error->throw( kind => 'usage', message => 'pack operation ' . $op->op_name . ' reads as the service credential and does not declare acts_for' )
        if !$op->acts_for;
    return $class->_read( $op, $op->ctx->service_context, $name, %params );
}

=head2 file_stamp($path)

What a kept answer about a file is checked against: size, modification time
and a digest of the content. The time alone cannot tell two writes of the
same size apart when they land in one tick of the filesystem's clock (a
version bump of C<1.0.0> to C<1.1.0> made at once), so the content is read;
a pack's files are few and small.

=cut

sub file_stamp ($class, $path) {
    my @st = Time::HiRes::stat($path);
    my $sha = '';
    if ( open my $fh, '<:raw', $path ) {
        my $d = Digest::SHA->new(1);
        $d->addfile($fh);
        $sha = substr( $d->hexdigest, 0, 12 );
        close $fh;
    }
    return join ':', $st[7] // 0, $st[9] // 0, $sha;
}

=head2 version_cmp($a, $b)

C<-1>, C<0> or C<1> comparing two dotted versions component by component
(C<0.9> is older than C<0.30>).

=cut

sub version_cmp ($class, $a, $b) {
    my @a = split /\./, $a;
    my @b = split /\./, $b;
    for my $i ( 0 .. ( @a > @b ? $#a : $#b ) ) {
        my $c = ( $a[$i] // 0 ) <=> ( $b[$i] // 0 );
        return $c if $c;
    }
    return 0;
}

sub _running () {
    require Odoo::Ops;
    return $Odoo::Ops::VERSION;
}

=head2 manifest($dir)

The checked C<pack.yaml> of the pack directory C<$dir>, as a hash with
C<name version oom_min namespace series summary dir lib>. A config error
names the pack and the line that is wrong: the name is the directory's, the
version dotted numbers, C<oom_min> not newer than the running OOM
(C<pack crm_page needs OOM 0.31, this is 0.30>), the namespace
C<Odoo::Pack::E<lt>NameE<gt>> and the series a list.

=cut

sub manifest ($class, $dir) {
    ( my $name = $dir ) =~ s{/+\z}{};
    $name =~ s{.*/}{};
    my $path = File::Spec->catfile( $dir, 'pack.yaml' );
    my $bad  = sub ($why) { Odoo::Error->throw( kind => 'config', message => "pack $name: $why", fix => 'packs/README.md says what pack.yaml holds' ) };
    -f $path or $bad->("$path is missing");
    my $m = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) };
    ref $m eq 'HASH' or $bad->( 'pack.yaml cannot be read: ' . ( $@ ? ( $@ =~ s/\s+at \S+ line \d+.*//sr ) : 'not a mapping' ) );
    for my $k (qw(name version oom_min namespace series summary)) {
        $bad->("pack.yaml has no $k") if !defined $m->{$k} || ( ref $m->{$k} eq '' && !length $m->{$k} );
    }
    if ( $name !~ /\A[a-z][a-z0-9_]*\z/ ) {
        ( my $fix = lc $name ) =~ s/-/_/g;
        $bad->("a pack name is lower case letters, digits and _, starting with a letter (rename it $fix)");
    }
    $bad->("pack.yaml name '$m->{name}' is not the directory name '$name'") if $m->{name} ne $name;
    for my $k (qw(version oom_min)) {
        $bad->("pack.yaml $k '$m->{$k}' is not dotted numbers (such as 0.30)") if $m->{$k} !~ /\A\d+(?:\.\d+)*\z/;
    }
    ( my $camel = join '', map { ucfirst } split /_/, $name );
    $bad->("pack.yaml namespace must be Odoo::Pack::$camel, not '$m->{namespace}'") if $m->{namespace} ne "Odoo::Pack::$camel";
    $bad->('pack.yaml series must be a list') if ref $m->{series} ne 'ARRAY' || !@{ $m->{series} };
    my $running = _running();
    Odoo::Error->throw( kind => 'config', message => "pack $name needs OOM $m->{oom_min}, this is $running",
        fix => "install OOM $m->{oom_min} or newer, or use an older release of the pack" )
        if $class->version_cmp( $m->{oom_min}, $running ) > 0;
    return { %$m, dir => $dir, lib => File::Spec->catdir( $dir, 'lib' ) };
}

=head2 discover(\@dirs, only =E<gt> \@names)

Reads every C<pack.yaml> under the pack directories (each entry holds pack
directories). Answers C<< { packs => { name => manifest }, refused => [ { name,
dir, reason } ] } >>. A pack that fails its checks is refused with the
reason, not thrown, so the other packs and core still load; the refusal is
said by name when an operation of that pack is asked for and by C<doctor>. A
name two directories share refuses both, naming both. A pack whose
C<behaviours/> or C<profiles/> hold a model or pack core already has is
refused (C<core lists hr.leave; a pack may not replace it>). C<only>, the
config's C<pack>, limits which packs load; a name in it that no directory
holds is refused as not found.

=cut

my %MEMO;

sub discover ($class, $dirs, %args) {
    my %only = map { $_ => 1 } @{ $args{only} // [] };
    my ( %seen, @refused );
    for my $root ( grep { defined && length } @$dirs ) {
        next if !-d $root;
        opendir my $dh, $root or next;
        for my $n ( sort grep { !/^\./ } readdir $dh ) {
            my $dir = File::Spec->catdir( $root, $n );
            next if !-d $dir || !-f File::Spec->catfile( $dir, 'pack.yaml' );
            next if %only && !$only{$n};
            push @{ $seen{$n} }, $dir;
        }
        closedir $dh;
    }
    # a registry is made often in one process (every custom change of a plan asks for one): the answer is
    # kept while the manifests it came from are unchanged
    my $memo_key = join "\0", @$dirs, '--', sort keys %only;
    my $sig = join ';', map { join ':', $_, $class->file_stamp( File::Spec->catfile( $_, 'pack.yaml' ) ) } map { @{ $seen{$_} } } sort keys %seen;
    return $MEMO{$memo_key}{result} if $MEMO{$memo_key} && $MEMO{$memo_key}{sig} eq $sig;
    my %packs;
    for my $n ( sort keys %seen ) {
        my @at = @{ $seen{$n} };
        if ( @at > 1 ) {
            push @refused, { name => $n, dir => $_, reason => "pack $n is in both $at[0] and $at[1]; a pack name is loaded once" } for @at;
            next;
        }
        my $m = eval { my $x = $class->manifest( $at[0] ); $class->_not_core( $x ); $x };
        if ($m) { $packs{$n} = $m }
        else    { push @refused, { name => $n, dir => $at[0], reason => _msg($@) } }
    }
    for my $n ( sort grep { !$seen{$_} } keys %only ) {
        push @refused, { name => $n, dir => undef, reason => "pack $n is named in pack but no pack_dirs entry holds it" };
    }
    my $result = { packs => \%packs, refused => \@refused };
    $MEMO{$memo_key} = { sig => $sig, result => $result };
    return $result;
}

sub _msg ($e) { ref $e && $e->can('message') ? $e->message : "$e" =~ s/\s+\z//r }

# a pack adds models and actions; it does not replace what core lists
sub _not_core ($class, $m) {
    require Odoo::Ops::Behaviour;
    require Odoo::Ops::Profile;
    my $bdir = File::Spec->catdir( $m->{dir}, 'behaviours' );
    if ( -d $bdir ) {
        my %core;
        for my $root ( Odoo::Ops::Behaviour->core_dirs ) {
            opendir my $ch, $root or next;
            $core{$_} = 1 for grep { !/^\./ && -d File::Spec->catdir( $root, $_ ) } readdir $ch;
            closedir $ch;
        }
        opendir my $dh, $bdir or return;
        for my $model ( sort grep { !/^\./ && -d File::Spec->catdir( $bdir, $_ ) } readdir $dh ) {
            Odoo::Error->throw( kind => 'config', message => "pack $m->{name}: core lists $model; a pack may not replace it",
                fix => 'a pack adds behaviour files for models core does not list' ) if $core{$model};
        }
    }
    my $pdir = File::Spec->catdir( $m->{dir}, 'profiles' );
    if ( -d $pdir ) {
        my @core = Odoo::Ops::Profile->core_dirs;
        opendir my $dh, $pdir or return;
        for my $p ( sort grep { !/^\./ && -d File::Spec->catdir( $pdir, $_ ) } readdir $dh ) {
            Odoo::Error->throw( kind => 'config', message => "pack $m->{name}: core has a $p profile; a pack may not replace it",
                fix => 'a pack adds profiles under its own name' ) if grep { -d File::Spec->catdir( $_, $p ) } @core;
        }
    }
    return;
}

my %ROOTS = ( behaviours => [], profiles => [] );

=head2 set_roots(@manifests)

Adds the C<behaviours/> and C<profiles/> of the loaded packs to the search
roots, after core's (L<Odoo::Ops::Behaviour> and L<Odoo::Ops::Profile> read
them through C<roots>). A pack's roots replace the previous set.

=cut

sub set_roots ($class, @packs) {
    for my $kind (qw(behaviours profiles)) {
        $ROOTS{$kind} = [ grep { -d } map { File::Spec->catdir( $_->{dir}, $kind ) } @packs ];
    }
    return;
}

sub roots ($class, $kind) { @{ $ROOTS{$kind} // [] } }

=head2 lint_pack($dir)

The contract's lint: every C<.pm> under the pack's C<lib/> is read (comments
and POD left out) and each violation is answered as C<file:line: text>. A
violation is an C<Odoo::> module outside the contract and the pack's own
namespace, named by C<use>, C<require>, C<parent>, C<base> or fully qualified
in code, and a call into a C<_private> sub of any other package
(C<Odoo::Ops::Runner::_x(...)>, C<< Odoo::Ops::Runner-E<gt>_x >>,
C<SUPER::_x>).

=cut

my @ALLOWED = qw(Odoo::Ops::Operation Odoo::Ops::Plan Odoo::Error Odoo::Ops Odoo::Ops::Pack);

sub lint_pack ($class, $dir) {
    my $m   = $class->manifest($dir);
    my $own = $m->{namespace};
    my @bad;
    my $walk;
    $walk = sub ($d) {
        opendir my $dh, $d or return;
        for my $e ( sort grep { !/^\./ } readdir $dh ) {
            my $p = File::Spec->catfile( $d, $e );
            if    ( -d $p )        { $walk->($p) }
            elsif ( $e =~ /\.pm\z/ ) {
                push @bad, $class->lint_file( $p, $own );
                push @bad, $class->_lint_op_name( $p, $m->{name} );
            }
        }
        closedir $dh;
    };
    $walk->( $m->{lib} );
    return @bad;
}

=head2 op_name_violations($pack, $op_name)

The rule for the name of an operation of the pack C<$pack>: C<E<lt>packE<gt>.E<lt>segmentE<gt>>,
the pack's own name first, each dotted segment lower case letters, digits and
C<_> starting with a letter (C<[a-z][a-z0-9_]*>, the rule a binding applies to an
operation name). Answers the reason, or nothing when the name fits.

=cut

sub op_name_violations ($class, $pack, $op_name) {
    return "operation name '$op_name' must start with '$pack.'" if index( $op_name, "$pack." ) != 0;
    for my $seg ( split /\./, $op_name, -1 ) {
        return "operation name '$op_name' has a segment '$seg' that is not lower case letters, digits and _, starting with a letter"
            if $seg !~ /\A[a-z][a-z0-9_]*\z/;
    }
    return;
}

sub _lint_op_name ($class, $path, $pack) {
    open my $fh, '<', $path or return;
    my ( @bad, $pod );
    while ( my $line = <$fh> ) {
        if ( $line =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod;
        next if $line !~ /\bsub\s+op_name\b[^{]*\{\s*['"]([^'"]*)['"]/;
        my $why = $class->op_name_violations( $pack, $1 ) or next;
        push @bad, "$path:$.: $why";
    }
    close $fh;
    return @bad;
}

=head2 lint_file($path, $namespace)

The violations (see L</lint_pack>) of one file.

=cut

sub lint_file ($class, $path, $own) {
    open my $fh, '<', $path or return ("$path:0: cannot read");
    my ( @bad, $pod, $acting, $declares );
    while ( my $line = <$fh> ) {
        if ( $line =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod;
        last if $line =~ /\A__(?:END|DATA)__\b/;
        ( my $code = $line ) =~ s/(?:\A|\s)#.*//;
        for my $name ( $code =~ /\b(Odoo::\w+(?:::\w+)*)/g ) {
            ( my $mod = $name ) =~ s/::_\w+\z//;    # a _private sub is judged below
            $mod =~ s/::[a-z]\w*\z//;                # a helper sub of an allowed module (Odoo::Ops::json)
            next if grep { $mod eq $_ } @ALLOWED;
            next if $mod eq $own || index( $mod, "$own\::" ) == 0;
            push @bad, "$path:$.: uses $mod, which is not in the pack contract (Odoo::Ops::Pack)";
        }
        while ( $code =~ /\b(Odoo::\w+(?:::\w+)*)(?:::|->)(_\w+)/g ) {
            my ( $mod, $sub ) = ( $1, $2 );
            next if $mod eq $own || index( $mod, "$own\::" ) == 0;
            push @bad, "$path:$.: calls $mod\::$sub, a private sub of core";
        }
        push @bad, "$path:$.: calls SUPER::$1, a private sub of core" if $code =~ /\bSUPER::(_\w+)/;
        $acting //= $.  if $code =~ /->\s*(?:service_client|person|own|service_read)\b|\bservice_read\b/;
        $declares = 1  if $code =~ /\bsub\s+acts_for\b[^{]*\{\s*(?:return\s+)?[1-9]/;
    }
    close $fh;
    # a service credential's client and the person's identity are for an operation that declares acts_for
    push @bad, "$path:$acting: uses person, service_client, own or service_read, and the file declares no acts_for (sub acts_for { 1 })"
        if defined $acting && !$declares;
    my %seen;
    return grep { !$seen{$_}++ } @bad;
}

1;

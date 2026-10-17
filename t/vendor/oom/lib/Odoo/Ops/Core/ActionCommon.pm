package Odoo::Ops::Core::ActionCommon;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use B ();
use Cwd ();
use JSON::PP ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops::PlanPrint;

=head1 NAME

Odoo::Ops::Core::ActionCommon - what C<core.action> and C<core.wizard> share

=head1 DESCRIPTION

Plain functions, not an operation. The two operations call Odoo's own
methods on records, so they need the same few things: the records a call
names, the state of a record as Odoo holds it, whether the module that adds
a method is installed, how Odoo's answer is put into words, and the
refusals that name the behaviour file to edit.

=head2 check_args($op, $subject, \@params, $args)

The positional arguments of a model-level call checked against the entry's
C<params> (C<< { name, type } >>, type C<str>, C<int>, C<bool> or C<json>). C<$args>
must be a JSON list of as many values as there are params, each of its type; a
mismatch is C<usage>, naming the parameter. A JSON number is not a C<str> and a
JSON string is not an C<int>: the caller says what it means. Returns the list.

=cut

sub _json_kind ($v) {
    return 'null' if !defined $v;
    return 'bool' if blessed($v) && $v->isa('JSON::PP::Boolean');
    return ref $v eq 'ARRAY' ? 'list' : ref $v eq 'HASH' ? 'object' : 'other' if ref $v;
    my $f = B::svref_2object( \$v )->FLAGS;
    return 'str' if $f & B::SVp_POK();
    return 'int' if ( $f & B::SVp_IOK() ) && !( $f & B::SVp_NOK() );
    return 'int' if ( $f & B::SVp_NOK() ) && $v == int($v) && $v !~ /e/i;
    return 'number';
}

sub check_args ( $class, $op, $subject, $params, $args ) {
    $args //= [];
    Odoo::Error->throw( kind => 'usage', message => "$op: $subject takes its arguments as a JSON list (args), not an object" )
        if ref $args ne 'ARRAY';
    my @p = @{ $params // [] };
    Odoo::Error->throw( kind => 'usage',
        message => "$op: $subject takes " . ( @p ? scalar(@p) . ' argument' . ( @p == 1 ? '' : 's' ) . ' (' . join( ', ', map { "$_->{name}: $_->{type}" } @p ) . ')' : 'no arguments' )
            . ', got ' . scalar(@$args) )
        if @$args != @p;
    for my $i ( 0 .. $#p ) {
        my ( $want, $got ) = ( $p[$i]{type}, _json_kind( $args->[$i] ) );
        next if $want eq 'json' || $want eq $got;
        Odoo::Error->throw( kind => 'usage', message => "$op: $subject argument " . ( $i + 1 ) . " ($p[$i]{name}) must be $want, got $got" );
    }
    return @$args;
}

=head2 args_text(\@params, $args)

The arguments as a plan line shows them: C<name=value> in order, a long value cut.

=cut

sub args_text ( $class, $params, $args ) {
    my @p = @{ $params // [] };
    my $j = JSON::PP->new->canonical->allow_nonref;
    return join ', ', map {
        my $v = $j->encode( $args->[$_] );
        $v = substr( $v, 0, 40 ) . '...' if length $v > 43;
        "$p[$_]{name}=$v";
    } 0 .. $#{$args};
}

=head2 refuse_unlisted($ctx, $model, $what, $message)

The C<refused> error for a method or wizard the model's behaviour file does
not list. C<$what> is C<action> or C<wizard>; the C<fix> names the file to add
the entry to, or says that the model has no file yet.

=cut

sub behaviour_file ( $class, $beh, $model, $series ) {
    return $beh->path ? ( Cwd::abs_path( $beh->path ) // $beh->path ) : "behaviours/$model/$series.yaml (the model has no behaviour file yet)";
}

sub refuse_unlisted ( $class, $ctx, $model, $what, $message ) {
    my $beh    = $ctx->behaviour($model);
    my $series = $beh->series || $ctx->config->get('profile_series') || $ctx->client->server_series;
    my $file   = $class->behaviour_file( $beh, $model, $series );
    my $list   = $what eq 'wizard' ? 'wizards' : 'actions';
    my $fix = "add it under '$list:' in $file if Odoo's own method is the one meant; oom-ops describe core.$what --set "
        . ( $what eq 'wizard' ? 'for' : 'model' ) . "=$model lists what is there";
    if ( $what eq 'wizard' ) {
        Odoo::Error->throw( kind => 'refused', code => 'unlisted-wizard', message => $message, fix => $fix );
    }
    Odoo::Error->throw( kind => 'refused', code => 'unlisted-action', message => $message, fix => $fix );
}

=head2 refuse_module($ctx, $op, $subject, $module)

The module check of an entry: C<refused/not-applicable> (via
L<Odoo::Ops::Modules>) when the module is not installed here, naming the
module. Nothing is claimed when the module table cannot be read.
C<$module> is the entry's own module or, when it names none, its model's.

=cut

sub refuse_module ( $class, $ctx, $op, $subject, $module ) {
    my $why = Odoo::Ops::Modules->missing( $ctx, $module ) // return;
    Odoo::Ops::Modules->refuse( $op, $subject, $why );
}

=head2 resolve_records($client, $op, $model, $fields, $record, $ids, \@read)

The records a call names, as C<< ( \@want, \%by_id ) >>: C<@want> holds
C<[ $id ]> for a record asked for by id and C<[ undef, $label ]> for a
C<field=value> that matched nothing; C<%by_id> the rows read (archived ones
included). C<$record> is an id or C<field=value> (a value that matches more
than one record is refused, naming the ids); C<$ids> a list of ids. Exactly
one of the two is given.

=cut

sub resolve_records ( $class, $client, $op, $model, $fields, $record, $ids, $read ) {
    my $have_ids = $ids && @$ids;
    Odoo::Error->throw( kind => 'usage', message => "$op: give exactly one of record and records" )
        if ( defined $record && length $record ? 1 : 0 ) + ( $have_ids ? 1 : 0 ) != 1;
    my @bad = $have_ids ? grep { !/^\d+\z/ } @$ids : ();
    Odoo::Error->throw( kind => 'usage', message => "$op: records must be whole numbers, got '$bad[0]'" ) if @bad;
    my $m   = $client->model($model);
    my $all = { active_test => JSON::PP::false };
    my ( @want, $found );
    if ($have_ids) {
        my %seen;
        my @u = grep { !$seen{$_}++ } map { 0 + $_ } @$ids;
        @want  = map { [$_] } @u;
        $found = $m->search_read( [ [ 'id', 'in', \@u ] ], $read, context => $all );
    }
    elsif ( $record =~ /^\s*(\d+)\s*\z/ ) {
        @want  = ( [ 0 + $1 ] );
        $found = $m->search_read( [ [ 'id', '=', 0 + $1 ] ], $read, context => $all );
    }
    elsif ( my ( $f, $val ) = $record =~ /^(\w+)=(.*)\z/s ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: $model has no field '$f'",
            fix => "oom-ops run core.skeleton --conf <conf> --set model=$model lists the fields" ) if !$fields->{$f};
        $found = $m->search_read( [ [ $f, '=', $val ] ], $read, limit => 6, context => $all );
        Odoo::Error->throw( kind => 'usage', message => "$op: $record matches $model records " . join( ', ', map { $_->{id} } @$found ),
            fix => 'pass --set records=' . join( ',', map { $_->{id} } @$found ) . ' (the ones meant)' ) if @$found > 1;
        @want = $found->[0] ? ( [ $found->[0]{id} ] ) : ( [ undef, $record ] );
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => "$op: record '$record' is neither an id nor field=value" );
    }
    return ( \@want, { map { $_->{id} => $_ } @$found } );
}

=head2 creates_specs($ctx, $entry)

What an entry's C<creates:> asks apply to look for, as C<< [ { model, link?, state_fields } ] >>:
the model, the field of the acted-on record that names what was made, and the
state fields of the made model's own behaviour file that exist on the server.
Empty when the entry lists none.

=cut

sub creates_specs ( $class, $ctx, $entry ) {
    my @out;
    for my $c ( @{ $entry->{creates} // [] } ) {
        my $fields = eval { $ctx->client->model( $c->{model} )->fields } // {};
        push @out, {
            model        => $c->{model},
            state_fields => [ grep { $fields->{$_} } $ctx->behaviour( $c->{model} )->state_fields ],
            ( defined $c->{link} ? ( link => $c->{link} ) : () ),
        };
    }
    return \@out;
}

=head2 creates_words($specs)

The plan line's statement of what is looked for: C<creates: hr.expense.sheet>,
or C<creates: not listed> when the entry names nothing (so a caller can tell
"nothing listed" from "nothing made").

=cut

sub creates_words ( $class, $specs ) {
    return 'creates: ' . ( @{ $specs // [] } ? join( ', ', map { $_->{model} } @$specs ) : 'not listed' );
}

=head2 creates_scope($entry)

The reads apply needs to find what a call made: C<search_read> on each model the
entry lists, and on C<ir.model> (which models are transient).

=cut

sub creates_scope ( $class, $entry ) {
    my @m = map { $_->{model} } @{ $entry ? $entry->{creates} // [] : [] };
    return () if !@m;
    return ( 'ir.model' => ['search_read'], map { $_ => ['search_read'] } @m );
}

my $NO_ACTIVE = { active_test => JSON::PP::false };

=head2 creates_before($client, $specs)

Before the call: the highest id in each listed model, read with C<active_test>
off. A transient model is left out (its records are Odoo's own bookkeeping, never
news), as is a model that cannot be read; the reason is in C<unread>.
Returns C<< { max => { model => id }, unread => { model => reason } } >>.

=cut

sub creates_before ( $class, $client, $specs ) {
    my ( %max, %unread );
    return { max => \%max, unread => \%unread } if !@{ $specs // [] };
    my @models = do { my %s; grep { !$s{$_}++ } map { $_->{model} } @$specs };
    my %transient;
    my $t = eval { $client->model('ir.model')->search_read( [ [ 'model', 'in', \@models ] ], [ 'model', 'transient' ] ) };
    if ($t) { $transient{ $_->{model} } = 1 for grep { $_->{transient} } @$t }
    else    { $unread{ir_model} = _why($@) }
    for my $m (@models) {
        next if $transient{$m};
        my $rows = eval { $client->model($m)->search_read( [], ['id'], limit => 1, order => 'id desc', context => $NO_ACTIVE ) };
        if ($rows) { $max{$m} = $rows->[0] ? 0 + $rows->[0]{id} : 0 }
        else       { $unread{$m} = _why($@) }
    }
    return { max => \%max, unread => \%unread };
}

sub _why ($err) {
    my $m = blessed($err) && $err->can('message') ? $err->message : "$err";
    ($m) = split /\n/, $m, 2;
    return $m;
}

=head2 creates_after($client, $specs, $before, $model, $ids)

After the call: the records in each listed model with an id above the one read
before and C<create_uid> the session's uid, with their C<display_name> and the
first non-empty state field. These are the records made by this login in that
model while the action ran; a record another process made as the same login in
the same moment would match too, and nothing more is claimed.

When an entry names a C<link>, the link field of the records acted on (C<$model>,
C<$ids>) is read back: a record it names that the search found is C<set to>;
one it names that the search did not find is C<linked, not made in this call>.
Returns C<< { created => [ { model, id, name, state } ], links => [ { field,
model, id, name, made } ], unread => { model => reason } } >>; a model that could
not be searched is named in C<unread>, never silently dropped.

=cut

sub creates_after ( $class, $client, $specs, $before, $model, $ids ) {
    my ( @created, @links, %unread );
    %unread = %{ $before->{unread} // {} };
    return { created => [], links => [], unread => \%unread } if !@{ $specs // [] };
    my $uid = $client->uid;
    my %made;
    my %done;
    for my $s (@$specs) {
        my $m = $s->{model};
        next if $done{$m}++ || !exists $before->{max}{$m};
        my @sf   = @{ $s->{state_fields} // [] };
        my $rows = eval {
            $client->model($m)->search_read( [ [ 'id', '>', $before->{max}{$m} ], [ 'create_uid', '=', $uid ] ],
                [ 'display_name', @sf ], order => 'id', context => $NO_ACTIVE );
        };
        if ( !$rows ) { $unread{$m} = _why($@); next }
        for my $r (@$rows) {
            my ($state) = grep { defined } map { my $v = $r->{$_}; $class->state_text($v) eq 'none' ? undef : $class->state_text($v) } @sf;
            push @created, { model => $m, id => 0 + $r->{id}, name => ( $r->{display_name} // '' ), state => $state };
            $made{$m}{ $r->{id} } = 1;
        }
    }
    my $acted = [ grep { defined } @{ $ids // [] } ];
    for my $s ( grep { defined $_->{link} && !$unread{ $_->{model} } && exists $before->{max}{ $_->{model} } } @$specs ) {
        next if !@$acted;
        my ( $m, $f ) = ( $s->{model}, $s->{link} );
        my $def = eval { $client->model($model)->fields->{$f} };
        if ( !$def || ( $def->{relation} // '' ) ne $m ) {
            $unread{"$model.$f"} = $def ? "$f points at " . ( $def->{relation} // 'no model' ) . ", not $m" : "$model has no field $f";
            next;
        }
        my $read = eval { $client->model($model)->read( $acted, [$f] ) };
        if ( !$read ) { $unread{"$model.$f"} = _why($@); next }
        my %seen;
        for my $row (@$read) {
            my $v = $row->{$f};
            my @link = ref $v eq 'ARRAY' ? ( $def->{type} eq 'many2one' ? ( $v->[0] ) : @$v ) : ();
            for my $lid ( grep { defined && /\A\d+\z/ && !$seen{$_}++ } @link ) {
                if ( $made{$m}{$lid} ) {
                    my ($c) = grep { $_->{model} eq $m && $_->{id} == $lid } @created;
                    push @links, { field => $f, model => $m, id => 0 + $lid, name => $c->{name}, made => JSON::PP::true };
                    next;
                }
                my $r = eval { $client->model($m)->search_read( [ [ 'id', '=', $lid ] ], ['display_name'], context => $NO_ACTIVE )->[0] };
                push @links, { field => $f, model => $m, id => 0 + $lid, name => ( $r ? ( $r->{display_name} // '' ) : '' ), made => JSON::PP::false };
            }
        }
    }
    return { created => \@created, links => \@links, unread => \%unread };
}

=head2 creates_lines($found)

The words for a change that made records: C<made: M id (name, state)>
per record, C<F set to M id> per link the search found, C<F names M id (name),
linked, not made in this call> per link it did not, and what could not be
searched. Plain strings, one per fact.

=cut

sub made_text ($class, $c) { return Odoo::Ops::PlanPrint::made_text($c) }

sub creates_lines ( $class, $found ) {
    my @out;
    push @out, map { 'made: ' . $class->made_text($_) } @{ $found->{created} // [] };
    for my $l ( @{ $found->{links} // [] } ) {
        push @out, $l->{made}
            ? "$l->{field} set to $l->{model} $l->{id}"
            : "$l->{field} names $l->{model} $l->{id}" . ( length( $l->{name} // '' ) ? " ($l->{name})" : '' ) . ': linked, not made in this call (it is not among the records this login made while the action ran)';
    }
    push @out, map { "could not look for what $_ made: $found->{unread}{$_}" } sort keys %{ $found->{unread} // {} };
    return @out;
}

=head2 window_note($ans, $specs, $before)

A window Odoo answered with that names a record (C<res_id>) in a model the search
did not cover adds C<Odoo's answer names M id>; it does not say the record was
made. A window on a model the search covered adds nothing.

=cut

sub window_note ( $class, $ans, $specs, $before ) {
    my $w = $ans->{window} or return '';
    return '' if !defined $w->{res_model} || !defined $w->{res_id} || $w->{res_id} !~ /\A[1-9]\d*\z/;
    return '' if exists $before->{max}{ $w->{res_model} };
    return "Odoo's answer names $w->{res_model} $w->{res_id}";
}

=head2 found_returned($found) / found_created($found)

The keys a handler adds to its C<returned> block (C<created>, C<links>,
C<unread>, each only when it has something) and to its result (C<created>
alone, only when something was made).

=cut

sub found_returned ( $class, $found ) {
    my @out;
    push @out, created => $found->{created} if @{ $found->{created} // [] };
    push @out, links   => $found->{links}   if @{ $found->{links}   // [] };
    push @out, unread  => $found->{unread}  if %{ $found->{unread}  // {} };
    return @out;
}

sub found_created ( $class, $found ) { return @{ $found->{created} // [] } ? ( created => $found->{created} ) : () }

=head2 name_of($row)

C<" (display name)"> for a plan line, or an empty string.

=cut

sub name_of ($class, $row) {
    my $n = $row->{display_name};
    return defined $n && !ref $n && length $n ? " ($n)" : '';
}

=head2 state_text($value)

A state as the plan prints it: the value, C<none> for an empty one.

=cut

sub state_text ($class, $v) {
    return 'none' if !defined $v || ( !ref $v && ( $v eq '' || $v eq '0' ) ) || ( blessed($v) && !$v );
    return ref $v eq 'ARRAY' ? ( defined $v->[1] ? $v->[1] : $v->[0] ) : ( ref $v ? JSON::PP->new->canonical->encode($v) : "$v" );
}

=head2 answer($returned, $wizard, $model, $wizard_method)

Odoo's answer to a method, in words, with the parts a caller acts on:

    nothing                                   the method returned nothing
    true / false                              reported as that (the transports read a boolean and the numbers 1 and 0 alike)
    Odoo answered with a window: M (modes)    an ir.actions.act_window: Odoo wants a
                                              wizard or shows a record; OOM does not follow
    Odoo answered with an action: TYPE (tag)  any other action dictionary
    Odoo answered: VALUE                      anything else

When the behaviour file names the wizard for the method, a window answer also
says to use C<core.wizard>. Returns C<< { says => TEXT, window => {...} } >>.

=cut

sub answer ( $class, $ret, $wizard = undef, $model = undef, $wizard_method = undef ) {
    return { says => 'Odoo answered with nothing' } if !defined $ret;
    # the transports read a server boolean as 1 or 0, so those two words are what a boolean arrives as
    if ( ( blessed($ret) && $ret->isa('JSON::PP::Boolean') ) || ( !ref $ret && $ret =~ /\A[01]\z/ ) ) {
        return { says => 'Odoo answered with ' . ( $ret ? 'true' : 'false' ) };
    }
    if ( ref $ret eq 'HASH' && ( $ret->{type} // '' ) eq 'ir.actions.act_window' ) {
        my $mode = $ret->{view_mode} // 'form';
        my $says = "Odoo answered with a window: " . ( $ret->{res_model} // 'unknown model' ) . " ($mode)";
        $says .= "; it is a wizard: use core.wizard --set model=$wizard --set for=$model"
            . ( defined $wizard_method ? " --set method=$wizard_method" : '' )
            if defined $wizard;
        return {
            says   => $says,
            window => { map { $_ => $ret->{$_} } grep { defined $ret->{$_} && !ref $ret->{$_} } qw(res_model view_mode res_id name target) },
        };
    }
    if ( ref $ret eq 'HASH' && defined $ret->{type} ) {
        my $tag = defined $ret->{tag} && !ref $ret->{tag} ? " ($ret->{tag})" : '';
        return { says => "Odoo answered with an action: $ret->{type}$tag" };
    }
    my $text = ref $ret ? JSON::PP->new->canonical->encode($ret) : "$ret";
    $text = substr( $text, 0, 200 ) . '...' if length $text > 200;
    return { says => "Odoo answered: $text" };
}

# models/methods a revert has asked this process to undo: the revert plans its
# scope from a handler built with no parameters, so the call is not known to it
our %UNDO_SCOPE;

sub add_undo_scope ( $class, $model, $method ) { $UNDO_SCOPE{$model}{$method} = 1 }

sub undo_scope ($class) {
    return { map { my $m = $_; ( $m => [ sort keys %{ $UNDO_SCOPE{$m} } ] ) } keys %UNDO_SCOPE };
}

=head2 describe_entries($ctx, $model, $kind)

The document C<oom-ops describe core.action|core.wizard --set model=M> prints.
C<$kind> is C<actions> or C<wizards>. With a context (a connection) the server's
series picks the behaviour file, each entry says C<here: applies> or C<here:
not applicable here (module X)>, and a model the server does not have is
refused C<not-applicable> (L<Odoo::Ops::Modules/absent_model>); without a
context the newest file is read and nothing is claimed about the server.

=cut

sub describe_entries ( $class, $ctx, $model, $kind ) {
    require Odoo::Ops::Behaviour;
    my $beh;
    my $op = "describe core." . ( $kind eq 'wizards' ? 'wizard' : 'action' );
    if ($ctx) {
        $beh = $ctx->behaviour($model);
        # a model of a module this server lacks is not described: it is not applicable here
        if ( my $why = Odoo::Ops::Modules->missing( $ctx, $beh->module ) ) {
            Odoo::Ops::Modules->refuse_model( $op, $model, $why );
        }
        # a model with no file for the module to say: ask the server whether it has the model at all
        if ( !defined $beh->module ) {
            my $f = eval { $ctx->client->model($model)->fields };
            Odoo::Ops::Modules->absent_model( $ctx, $op, $model, $@ ) if !$f;
        }
    }
    else {
        my $latest = Odoo::Ops::Behaviour->latest($model);
        $beh = defined $latest ? Odoo::Ops::Behaviour->load( model => $model, series => $latest ) : Odoo::Ops::Behaviour->load( model => $model, series => 1 );
    }
    my $here = sub ($module) {
        return () if !$ctx;
        return ( here => Odoo::Ops::Modules->missing( $ctx, $module ) ? "not applicable here (module $module)" : 'applies' );
    };
    my %mh      = defined $beh->module ? $here->( $beh->module ) : ();
    my @entries = map { +{ %$_, $here->( $_->{module} // $beh->module ) } } @{ $beh->$kind };
    return {
        model          => $model,
        series         => $beh->series || undef,
        behaviour_file => $beh->path,
        ( defined $beh->module ? ( module => $beh->module, ( $mh{here} ? ( module_here => $mh{here} ) : () ) ) : () ),
        ( $beh->state_info ? ( state => $beh->state_info ) : () ),
        $kind => \@entries,
        ( $beh->known ? () : ( note => "no behaviour file for $model: nothing is listed, so core." . ( $kind eq 'wizards' ? 'wizard' : 'action' ) . ' refuses every call on it' ) ),
    };
}

1;

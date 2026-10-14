package Odoo::Ops::CRM::Import;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Match;
use Odoo::Ops::Source;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Import - plan loading a source into crm.lead

=head1 DESCRIPTION

C<crm.import>: reads a source through its mapping
(L<Odoo::Ops::Source>), matches each row against every existing lead
- archived included - on exact normalised keys (L<Odoo::Ops::Match>),
and plans. It never writes; apply the plan.

Every source row lands in exactly one bucket:

    create             no existing lead shares a key
    no-key             nothing to match on (no email/phone) - held,
                       because a created one would be re-created on
                       every re-run; with no_key=create it is created
                       instead, as create-no-key
    update             matched one active lead; the field policies
                       leave something to change
    unchanged          matched one active lead; nothing to change
                       (so a re-run after apply is all unchanged)
    matches-archived   matched an archived lead - held for a person
    ambiguous          keys point at more than one lead - held
    duplicate-in-source  an earlier row of this source has the same key
    unresolved         a stage/team/salesperson/country name that does
                       not exist, and is not one this run may create
    held-flag          the source flagged it (e.g. self_test) - held
    held-rule          a mapping hold_when rule matched (e.g. an enquiry
                       that belongs in another company's CRM)
    held-override      a person decided so in the source's overrides
                       (e.g. spam), with the reason
    invalid            the mapping failed, or the lead title is empty

Tags, sources, mediums and campaigns named by rows but missing in Odoo
are planned as support creates (outside the row count) before the rows
that use them; C<create_missing> narrows that list.

Field policies on a matched lead come from the mapping's C<on_match>;
the default is C<fill> (write only where the lead is empty), and
C<add> for many2many (tags are added, never removed). C<append> adds
text not already present; C<overwrite> replaces; C<ignore> never
touches the field.

=cut

sub op_name ($class) { 'crm.import' }
sub summary ($class) { 'Plan loading a mapped source into leads (match, fill, tag)' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    {   mapping        => { type => 'path', required => 1, help => 'mapping.yaml of the source' },
        match          => { type => 'list', help => 'match keys, default from the mapping or email,phone' },
        phone_cc       => { type => 'str',  help => 'country code for national phone numbers (e.g. 44)' },
        create_missing => { type => 'list', default => 'tag,source,medium,campaign',
            help => 'satellite models whose missing names may be created' },
        notify => { type => 'bool', default => 0,
            help => 'let Odoo email "you have been assigned" to the salesperson (off: the owner distributes)' },
        no_key => { type => 'str', default => 'hold',
            help => 'row with nothing to match on: hold (default) or create - a created one is re-created on every re-run' },
    };
}
sub read_scope ($class) {
    {   lead        => ['search_read'],
        tag         => ['search_read'],
        source      => ['search_read'],
        medium      => ['search_read'],
        campaign    => ['search_read'],
        stage       => ['search_read'],
        team        => ['search_read'],
        country     => ['search_read'],
        'res.users' => ['search_read'],
    };
}
sub write_scope ($class) {
    {   lead     => [qw(create write)],
        tag      => ['create'],
        source   => ['create'],
        medium   => ['create'],
        campaign => ['create'],
    };
}

sub plan ($self) {
    my $p   = $self->profile;
    my $v   = $p->validate( $self->client );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'profile',
        message => 'crm profile does not match this server: ' . join( '; ', @{ $v->{missing} } ),
    ) if !$v->{ok};

    my $src = Odoo::Ops::Source->load( $self->param('mapping') );
    Odoo::Error->throw( kind => 'config', message => 'crm.import loads leads; mapping target is ' . $src->target )
        if $src->target ne 'lead';
    $self->_load_policies($src);
    for my $lf ( $src->fields ) {
        Odoo::Error->throw( kind => 'config', message => "mapping field '$lf' is not a lead field in the crm profile" )
            if !$p->has_field( lead => $lf );
    }
    my $mcfg = $src->mapping->{match} // {};
    my $keys = $self->param('match') // $mcfg->{keys} // [qw(email phone)];
    my $cc   = $self->param('phone_cc') // $mcfg->{phone_cc};
    $self->{create_ok} = { map { $_ => 1 } @{ $self->param('create_missing') } };

    # existing leads, archived included, with every field we may compare
    my %want = map { $_ => 1 } $src->fields, @$keys, 'active', 'title';
    my @pf   = map { $p->field( lead => $_ ) } grep { $p->has_field( lead => $_ ) } sort keys %want;
    my $existing = $self->model('lead')->all(
        [ [ $p->field( lead => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] ], \@pf );
    my %by_id = map { $_->{id} => $_ } @$existing;
    my $match = Odoo::Ops::Match->new( keys => $keys, phone_cc => $cc );
    $match->add( $_->{id}, $p->to_logical( lead => $_ ) ) for @$existing;
    my $seen = Odoo::Ops::Match->new( keys => $keys, phone_cc => $cc );

    my $rows = $src->rows;
    my ( @decisions, %needed );
    for my $row (@$rows) {
        my $d = $self->_decide( $row, $match, $seen, \%by_id );
        push @decisions, $d;
        if ( $d->{action} eq 'create' || $d->{action} eq 'write' ) {
            $needed{$_} = 1 for Odoo::Ops::Plan::_refs_in( $d->{vals} );
        }
        # Only rows that will stand count for "duplicate in source"; a
        # held self-test must not shadow the real row behind it.
        $seen->add( scalar(@decisions), $row->{values} ) if $d->{action} ne 'hold';
    }

    my $plan = $self->new_plan( input_count => scalar @$rows );
    $plan->note( 'source ' . $src->name . ': ' . scalar(@$rows) . ' rows; match on ' . join( ', ', @$keys )
        . ( defined $cc ? " (phone country code $cc)" : '' ) );
    $plan->note( 'existing leads considered: ' . scalar(@$existing) . ' (archived included)' );
    for my $ref ( sort keys %needed ) {
        my $s = $self->{support}{$ref};
        $plan->add( %$s, support => 1, ref => $ref );
    }
    for my $d (@decisions) {
        $d->{context} = { mail_auto_subscribe_no_notify => 1 }
            if !$self->param('notify') && ( $d->{action} eq 'create' || $d->{action} eq 'write' );
        $plan->add(%$d);
    }
    return $plan;
}

sub _hold ($bucket, $row, $reason) {
    return { bucket => $bucket, action => 'hold', key => "src:$row->{key}", reason => $reason };
}

sub _decide ($self, $row, $match, $seen, $by_id) {
    my $p = $self->profile;
    return _hold( 'invalid', $row, $row->{error} ) if $row->{error};
    if ( my $h = $row->{held} ) {
        my ($kind) = $h =~ /^(\w+):/;
        return _hold( 'held-' . ( $kind // 'flag' ), $row, $h );
    }
    my $vals = $row->{values};
    return _hold( 'invalid', $row, 'lead title is empty' )
        if !defined $vals->{title} || $vals->{title} !~ /\S/;

    my $dup = $seen->find($vals);
    return _hold( 'duplicate-in-source', $row, 'same ' . join( '/', @{ $dup->{via} } ) . ' as source row #'
            . join( ', #', @{ $dup->{ids} } ) ) if $dup->{status} ne 'none';

    my ( %resolved, @unresolved );
    for my $lf ( sort keys %$vals ) {
        my $v = $vals->{$lf};
        next if !defined $v || ( ref $v eq 'ARRAY' && !@$v );
        my $d    = $p->descriptor( lead => $lf );
        my $type = $d->{type} // '';
        if ( $type eq 'many2one' || $type eq 'many2many' ) {
            my @names = ref $v eq 'ARRAY' ? @$v : ($v);
            my @ids;
            for my $n (@names) {
                my $id = $self->_resolve( $lf, $d->{relation}, $n );
                if ( !defined $id ) { push @unresolved, "$lf '$n'"; next }
                push @ids, $id;
            }
            $resolved{$lf} = $type eq 'many2one' ? $ids[0] : \@ids;
        }
        elsif ( $type eq 'html' ) {
            $resolved{$lf} = _to_html($v);
        }
        else {
            $resolved{$lf} = $v;
        }
    }
    return _hold( 'unresolved', $row, 'unknown ' . join( ', ', @unresolved ) ) if @unresolved;

    my $m = $match->find($vals);
    if ( $m->{status} eq 'many' ) {
        return _hold( 'ambiguous', $row, 'matches leads ' . join( ', ', @{ $m->{ids} } )
                . ' via ' . join( '/', @{ $m->{via} } ) );
    }
    if ( $m->{status} eq 'none' ) {
        my $keyed = $match->has_key($vals);
        return _hold( 'no-key', $row, 'nothing to match on (' . join( ', ', $match->keys_used )
                . ') - a created lead could not be recognised on a re-run' )
            if !$keyed && $self->param('no_key') ne 'create';
        my %phys;
        for my $lf ( keys %resolved ) {
            my $type = $p->descriptor( lead => $lf )->{type} // '';
            $phys{ $p->field( lead => $lf ) } =
                $type eq 'many2many' ? [ [ 6, 0, $resolved{$lf} ] ] : $resolved{$lf};
        }
        # Re-checked at apply: a lead created with this email since planning
        # (another plan, a person) is reused, not duplicated. Phone-only rows
        # are protected at plan time only.
        my $email_pf = $p->field( lead => 'email' );
        return {
            bucket => $keyed ? 'create' : 'create-no-key',
            action => 'create', model => $p->model_name('lead'),
            key    => "src:$row->{key}", vals => \%phys,
            ( defined $phys{$email_pf} && !ref $phys{$email_pf} ? ( unique_by => $email_pf ) : () ),
        };
    }

    my $id   = $m->{ids}[0];
    my $lead = $by_id->{$id};
    my $active_pf = $p->field( lead => 'active' );
    return _hold( 'matches-archived', $row, "matches archived lead $id via " . join( '/', @{ $m->{via} } ) )
        if !$lead->{$active_pf};

    my ( %set, %before );
    for my $lf ( sort keys %resolved ) {
        my $pf   = $p->field( lead => $lf );
        my $type = $p->descriptor( lead => $lf )->{type} // '';
        my $policy = $self->_policy( $lf, $type );
        next if $policy eq 'ignore';
        my ( $old, $new ) = ( $lead->{$pf}, $resolved{$lf} );
        my $write;
        if ( $type eq 'many2many' ) {
            my %have = map { $_ => 1 } @{ $old // [] };
            my @add  = grep { ref $_ || !$have{$_} } @$new;
            if ( $policy eq 'overwrite' ) {
                my $same = !grep( { ref } @$new )
                    && join( ',', sort { $a <=> $b } @$new ) eq join( ',', sort { $a <=> $b } keys %have );
                $write = [ [ 6, 0, $new ] ] if !$same;
            }
            elsif (@add) {
                $write = [ map { [ 4, $_, 0 ] } @add ];
            }
        }
        elsif ( $type eq 'many2one' ) {
            my $old_id = ref $old eq 'ARRAY' ? $old->[0] : undef;
            if ( ref $new || !defined $old_id || $old_id != $new ) {
                $write = $new if !$old_id || $policy eq 'overwrite';
            }
        }
        else {
            if ( _empty( $old, $type ) ) {
                $write = $new;
            }
            elsif ( $policy eq 'overwrite' && "$old" ne "$new" ) {
                $write = $new;
            }
            elsif ( $policy eq 'append' && index( _text($old), _text($new) ) < 0 ) {
                $write = $type eq 'html' ? "$old$new" : "$old\n\n$new";
            }
        }
        next if !defined $write;
        $set{$pf}    = $write;
        $before{$pf} = $old;
    }
    return { bucket => 'unchanged', action => 'skip', key => "src:$row->{key}", id => $id,
        reason => "matches lead $id via " . join( '/', @{ $m->{via} } ) } if !%set;
    return {
        bucket => 'update', action => 'write', model => $p->model_name('lead'),
        id     => $id, key => "src:$row->{key}", vals => \%set, before => \%before,
        reason => "matches lead $id via " . join( '/', @{ $m->{via} } ),
    };
}

sub _policy ($self, $lf, $type) {
    my $src_policy = $self->{source_policy}{$lf};
    return $src_policy if $src_policy;
    return $type eq 'many2many' ? 'add' : 'fill';
}

# Name -> id (or a $ref to a planned support create) for a relational
# lead field; undef when it neither exists nor may be created.
sub _resolve ($self, $lf, $relation, $name) {
    my $p = $self->profile;
    my $norm = lc( $name =~ s/^\s+|\s+\z//gr );
    if ( $relation eq 'res.users' ) {
        my $users = $self->{cache}{'res.users'} //= $self->model('res.users')->search_read( [], [qw(login name)] );
        my ($u) = grep { lc $_->{login} eq $norm || lc $_->{name} eq $norm } @$users;
        return $u ? $u->{id} : undef;
    }
    my ($lm) = grep { $p->model_name($_) eq $relation } $p->models;
    Odoo::Error->throw( kind => 'config', message => "lead.$lf relates to $relation, which the crm profile does not map" )
        if !$lm;
    my $name_pf = $p->field( $lm => 'name' );
    my $index   = $self->{cache}{$lm} //= do {
        my @f = ($name_pf);
        push @f, $p->field( $lm => 'code' ) if $p->has_field( $lm => 'code' );
        my %i;
        for my $r ( @{ $self->model($lm)->search_read( [], \@f ) } ) {
            $i{ lc $r->{$name_pf} } //= $r->{id};
            $i{ lc $r->{ $f[1] } } //= $r->{id} if $f[1] && $r->{ $f[1] };
        }
        \%i;
    };
    return $index->{$norm} if $index->{$norm};
    return undef if !$self->{create_ok}{$lm};
    my $ref = "$lm:$norm";
    $self->{support}{$ref} //= {
        bucket => "new-$lm", action => 'create', model => $relation,
        vals   => { $name_pf => $name =~ s/^\s+|\s+\z//gr }, unique_by => $name_pf,
    };
    return { '$ref' => $ref };
}

sub _empty ($v, $type) {
    return 1 if !defined $v;
    return 0 if $type =~ /^(integer|float|monetary|boolean)\z/;
    return 1 if !ref $v && ( $v eq '0' || $v eq '' );
    return 1 if $type eq 'html' && _text($v) eq '';
    return 0;
}

sub _text ($v) {
    return '' if !defined $v || ref $v;
    my $t = $v =~ s/<[^>]*>/ /gr;
    $t =~ s/&nbsp;/ /g;
    $t =~ s/\s+/ /g;
    return $t =~ s/^ | \z//gr;
}

sub _to_html ($v) {
    return $v if $v =~ /^\s*</;
    my $e = $v =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr =~ s/"/&quot;/gr;
    return join '', map { '<p>' . ( s/\n/<br>/gr ) . '</p>' } split /\n{2,}/, $e;
}

my %POLICY = map { $_ => 1 } qw(fill add append overwrite ignore);

sub _load_policies ($self, $src) {
    for my $lf ( $src->fields ) {
        my $pol = $src->field_policy($lf) // next;
        Odoo::Error->throw( kind => 'config', message => "mapping field '$lf': unknown on_match '$pol'" )
            if !$POLICY{$pol};
        $self->{source_policy}{$lf} = $pol;
    }
}

1;

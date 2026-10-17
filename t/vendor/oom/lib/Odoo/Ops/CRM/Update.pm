package Odoo::Ops::CRM::Update;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Update - per-lead updates from a reviewed file

=head1 DESCRIPTION

C<crm.update>: applies per-lead changes prepared elsewhere (research
findings, a person's corrections). C<file> is JSON lines, one per lead:

    {"id": 97,
     "fill":    {"website": "www.example.com", "country": "AE"},
     "correct": {"contact_name": "Samir Baerli"},
     "add_tags": ["OCA member"],
     "append_notes": "<p>...</p>",
     "why": "research 2026-09-28, sources in research/findings/97.json"}

C<fill> sets a field only where the lead has it empty - a filled field
is left alone and counted as C<kept> in the plan notes. C<correct>
overwrites, and is meant for clear errors only. C<add_tags> adds tags
by name (missing tags are created). C<append_notes> is added to the
lead's internal notes unless that text is already there. Relational
fields resolve by name (country by ISO code or name); an unknown name
refuses the plan by name, it is never invented.

Buckets: C<update>, C<unchanged>, C<lead-gone> (id not readable).

=cut

sub op_name ($class) { 'crm.update' }
sub summary ($class) { 'Apply reviewed per-lead updates (fill / correct / tags / notes)' }
sub pack    ($class) { 'crm' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'update', meaning => 'fill, correct, add_tags and append_notes are applied to the lead' },
        { name => 'new-tag', meaning => 'a tag named in add_tags that does not exist is made first (a support row)' },
        { name => 'unchanged', meaning => 'nothing in the row differs from the lead' },
    ];
}
sub holds ($class) {
    return [
        { name => 'lead-gone', meaning => 'the lead is not readable' },
    ];
}

sub params ($class) {
    {   file   => { type => 'path', required => 1, help => 'JSON lines: {id, fill, correct, add_tags, append_notes, why}' },
        notify => { type => 'bool', default => 0, help => 'let Odoo send assignment notices' },
    };
}
sub read_scope ($class) {
    {   lead        => [qw(search_read read)],
        tag         => ['search_read'],
        country     => ['search_read'],
        stage       => ['search_read'],
        team        => ['search_read'],
        source      => ['search_read'],
        'res.users' => ['search_read'],
    };
}
sub write_scope ($class) { { lead => ['write'], tag => ['create'] } }

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'crm profile does not match: '
            . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};

    my @rows = $self->_read_file( $self->param('file') );
    my %need;
    for my $r (@rows) {
        for my $lf ( keys %{ $r->{fill} // {} }, keys %{ $r->{correct} // {} } ) {
            my $pf = $p->has_field( lead => $lf ) ? $p->field( lead => $lf )
                : Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: '$lf' is not a lead field in the crm profile" );
            $need{$pf} = 1;
        }
    }
    my $tags_f  = $p->field( lead => 'tags' );
    my $notes_f = $p->field( lead => 'notes' );
    $need{$tags_f} = $need{$notes_f} = 1;
    my %lead = map { $_->{id} => $_ } @{ $self->model('lead')->read( [ map { 0 + $_->{id} } @rows ], [ sort keys %need ] ) };

    my $plan = $self->new_plan( input_count => scalar @rows );
    my ( %support, @changes, $kept );
    for my $r (@rows) {
        my $cur = $lead{ $r->{id} };
        if ( !$cur ) {
            push @changes, { bucket => 'lead-gone', action => 'hold', key => "lead:$r->{id}", reason => 'lead not readable' };
            next;
        }
        my ( %set, %before );
        for my $mode (qw(fill correct)) {
            for my $lf ( sort keys %{ $r->{$mode} // {} } ) {
                my $pf   = $p->field( lead => $lf );
                my $type = $p->descriptor( lead => $lf )->{type} // '';
                my $new  = $self->_value( $lf, $type, $r->{$mode}{$lf} );
                my $old  = $cur->{$pf};
                my $old_cmp = ref $old eq 'ARRAY' ? $old->[0] : $old;
                next if defined $old_cmp && defined $new && "$old_cmp" eq "$new";
                next if $mode eq 'fill' && ( !defined $new || $new eq '' );    # filling with nothing
                if ( $mode eq 'fill' && !_empty( $old, $type ) ) { $kept++; next }
                $set{$pf} = $new;
                $before{$pf} = $old;
            }
        }
        if ( my @add = @{ $r->{add_tags} // [] } ) {
            my %have = map { $_ => 1 } @{ $cur->{$tags_f} // [] };
            my @cmd;
            for my $name (@add) {
                my $id = $self->_tag_id($name);
                if ( !defined $id ) {
                    my $ref = 'tag:' . lc $name;
                    $support{$ref} //= { bucket => 'new-tag', action => 'create', model => $p->model_name('tag'),
                        vals => { $p->field( tag => 'name' ) => $name }, ref => $ref, support => 1,
                        unique_by => $p->field( tag => 'name' ) };
                    push @cmd, [ 4, { '$ref' => $ref }, 0 ];
                }
                elsif ( !$have{$id} ) { push @cmd, [ 4, $id, 0 ] }
            }
            if (@cmd) { $set{$tags_f} = \@cmd; $before{$tags_f} = $cur->{$tags_f} }
        }
        if ( my $n = $r->{append_notes} ) {
            my $old = $cur->{$notes_f};
            my $old_s = defined $old && !ref $old ? $old : '';
            if ( index( _plain($old_s), _plain($n) ) < 0 ) {
                $set{$notes_f}    = $old_s . $n;
                $before{$notes_f} = $old;
            }
        }
        if (%set) {
            push @changes, { bucket => 'update', action => 'write', model => $p->model_name('lead'), id => $cur->{id},
                vals => \%set, before => \%before, key => "lead:$cur->{id}", ( $r->{why} ? ( reason => $r->{why} ) : () ),
                ( $self->param('notify') ? () : ( context => { mail_auto_subscribe_no_notify => 1 } ) ) };
        }
        else {
            push @changes, { bucket => 'unchanged', action => 'skip', id => $cur->{id}, key => "lead:$cur->{id}" };
        }
    }
    $plan->note("$kept fill value(s) kept: the lead already had a value") if $kept;
    my %used = map { ( $_ => 1 ) } map { Odoo::Ops::Plan::_refs_in( $_->{vals} ) } @changes;
    $plan->add( %{ $support{$_} } ) for grep { $used{$_} } sort keys %support;
    $plan->add(%$_) for @changes;
    return $plan;
}

sub _read_file ($self, $path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
    my @rows;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        my $r = eval { Odoo::Ops::json()->decode($line) }
            // Odoo::Error->throw( kind => 'usage', message => "$path line $.: not JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
        Odoo::Error->throw( kind => 'usage', message => "$path line $.: needs a numeric id", fix => 'correct the file; oom-ops describe <op> shows what it holds' ) if ( $r->{id} // '' ) !~ /^\d+\z/;
        push @rows, $r;
    }
    close $fh;
    return @rows;
}

sub _value ($self, $lf, $type, $v) {
    return $v if $type ne 'many2one';
    return undef if !defined $v || $v eq '';
    my $p = $self->profile;
    my $d = $p->descriptor( lead => $lf );
    my ($lm) = grep { $p->model_name($_) eq $d->{relation} } $p->models;
    Odoo::Error->throw( kind => 'usage', message => "lead.$lf relates to $d->{relation}, which the crm profile does not map" ) if !$lm;
    my $nf  = $p->field( $lm => 'name' );
    my @dom = ( [ $nf, '=ilike', $v ] );
    @dom = ( '|', [ $p->field( $lm => 'code' ), '=ilike', $v ], @dom ) if $p->has_field( $lm => 'code' );
    my $hits = $self->model($lm)->search_read( \@dom, ['id'] );
    Odoo::Error->throw( kind => 'usage', message => "lead.$lf '$v' matches " . scalar(@$hits) . " $lm records" ) if @$hits != 1;
    return $hits->[0]{id};
}

sub _tag_id ($self, $name) {
    my $nf = $self->profile->field( tag => 'name' );
    $self->{tags} //= { map { lc $_->{$nf} => $_->{id} } @{ $self->model('tag')->search_read( [], [$nf] ) } };
    return $self->{tags}{ lc $name };
}

sub _empty ($v, $type) {
    return 1 if !defined $v;
    return 0 if $type =~ /^(integer|float|monetary|boolean)\z/;
    return 1 if !ref $v && $v eq '';
    return 1 if $type eq 'html' && _plain($v) eq '';
    return 0;
}

sub _plain ($v) {
    return '' if !defined $v || ref $v;
    my $t = $v =~ s/<[^>]*>/ /gr;
    $t =~ s/&nbsp;/ /g;
    $t =~ s/\s+/ /g;
    return $t =~ s/^ | \z//gr;
}

1;

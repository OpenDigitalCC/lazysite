package Odoo::Model;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Record;
use Odoo::RecordSet;

=head1 NAME

Odoo::Model - a lazy, introspected handle on one Odoo model

=head1 SYNOPSIS

    my $so = $odoo->model('sale.order');

    # discovery - no pre-knowledge of the schema needed
    my @names  = $so->field_names;
    my $state  = $so->describe('state');
    my $values = $so->selections('state');    # [[value, label], ...]
    my $rels   = $so->relations;              # field => {type, relation}

    # read path
    my $ids  = $so->search([['state', '=', 'sale']], limit => 10);
    my $rows = $so->search_read([['state', '=', 'sale']],
                                ['name', 'partner_id'], limit => 10);
    my $row  = $so->read_one($ids->[0], ['name', 'date_order']);
    my $all  = $so->all([['state', '=', 'sale']], ['name']);

    # write path (x2many values via Odoo::Commands)
    my $id = $so->create({ partner_id => 7, note => 'from Perl' });
    $so->write($id, { note => 'updated' });
    $so->unlink($id);

=head1 DESCRIPTION

Field metadata comes from the server's own C<fields_get> and is
cached per handle for the life of the process (C<refresh_fields>
drops it). There is no generated class to go stale: a field added in
Odoo yesterday is visible here today.

All read results are plain hashrefs; typed record objects are a later
milestone. Relational values arrive as Odoo sends them: many2one as
C<[id, display_name]> or undef, x2many as an arrayref of ids. Odoo
sends C<false> for an empty char, text, html, date, datetime, selection,
binary or many2one; L<Odoo::Client/execute_kw> reads those by their
C<fields_get> type and gives undef, so a string C<"0"> is a value and an
empty field is not. A boolean is C<1> or C<0>, a number is a number.

Every method accepts a trailing C<< context => \%ctx >> option which
is merged over the client's default context.

=cut

# The attribute subset worth caching; fields_get silently ignores
# names a given Odoo version doesn't know.
my @FIELD_ATTRS = qw(
    string help type required readonly store
    relation relation_field selection
);

my %RELATIONAL = map { $_ => 1 } qw(many2one one2many many2many);

sub new ($class, %args) {
    for my $req (qw(client name)) {
        Odoo::Error->throw(kind => 'config', message => "$req required")
            if !$args{$req};
    }
    return bless { client => $args{client}, name => $args{name} }, $class;
}

sub name   ($self) { $self->{name} }
sub client ($self) { $self->{client} }

#--- schema discovery ---------------------------------------------------------

sub fields ($self) {
    return $self->{fields} //= do {
        my $c     = $self->{client};
        my $fetch = sub { $c->execute_kw( $self->{name}, 'fields_get', [], { attributes => \@FIELD_ATTRS } ) };
        $c->can('fields_cached') ? $c->fields_cached( $self->{name}, $fetch ) : $fetch->();
    };
}

sub refresh_fields ($self) {
    delete $self->{fields};
    $self->{client}->forget_fields( $self->{name} ) if $self->{client}->can('forget_fields');
    return $self->fields;
}

sub field_names ($self) {
    return sort keys %{ $self->fields };
}

sub describe ($self, $field) {
    return $self->fields->{$field} // Odoo::Error->throw(
        kind    => 'usage',
        message => "model $self->{name} has no field '$field'",
    );
}

sub selections ($self, $field) {
    my $d = $self->describe($field);
    Odoo::Error->throw(
        kind    => 'usage',
        message => "field '$field' on $self->{name} is type '$d->{type}', not selection",
    ) if ($d->{type} // '') ne 'selection';
    return $d->{selection} // [];
}

sub relations ($self) {
    my $fields = $self->fields;
    return {
        map {
            $_ => {
                type     => $fields->{$_}{type},
                relation => $fields->{$_}{relation},
            }
        }
        grep { $RELATIONAL{ $fields->{$_}{type} // '' } }
        keys %$fields
    };
}

sub required_fields ($self) {
    my $fields = $self->fields;
    return sort grep { $fields->{$_}{required} } keys %$fields;
}

#--- read path ----------------------------------------------------------------

sub search ($self, $domain = [], %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'search',
        [$domain],
        _kwargs(\%opts, qw(offset limit order)),
    );
}

sub count ($self, $domain = [], %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'search_count',
        [$domain],
        _kwargs(\%opts),
    );
}

sub search_read ($self, $domain = [], $fields = undef, %opts) {
    my $kw = _kwargs(\%opts, qw(offset limit order));
    $kw->{fields} = $fields if $fields;
    return $self->{client}->execute_kw(
        $self->{name}, 'search_read',
        [$domain],
        $kw,
    );
}

sub read ($self, $ids, $fields = undef, %opts) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'read takes an arrayref of ids (see read_one)',
    ) if ref $ids ne 'ARRAY';
    return [] if !@$ids;
    my $kw = _kwargs(\%opts);
    $kw->{fields} = $fields if $fields;
    my $rows = $self->{client}->execute_kw(
        $self->{name}, 'read',
        [$ids],
        $kw,
    );
    # Odoo does not promise result order; restore input order.
    my %by_id = map { $_->{id} => $_ } @$rows;
    return [ grep { defined } map { $by_id{$_} } @$ids ];
}

sub read_one ($self, $id, $fields = undef, %opts) {
    my $rows = $self->read([$id], $fields, %opts);
    return $rows->[0];
}

=head2 all(\@domain, \@fields, %opts)

Fetches every matching row, paging on C<id> so the walk is stable
even while other sessions insert rows. Options: C<page_size>
(default 500), C<context>. Returns an arrayref ordered by id.

=cut

sub all ($self, $domain = [], $fields = undef, %opts) {
    my $page_size = delete $opts{page_size} // 500;
    my (@rows, $last_id);
    while (1) {
        my $page_domain =
            defined $last_id ? [ @$domain, [ 'id', '>', $last_id ] ] : $domain;
        my $page = $self->search_read(
            $page_domain, $fields,
            limit => $page_size,
            order => 'id asc',
            %opts,
        );
        last if !@$page;
        push @rows, @$page;
        $last_id = $page->[-1]{id};
        last if @$page < $page_size;
    }
    return \@rows;
}

=head2 name_get(\@ids, %opts)

C<[id, label]> pairs for the given ids. Odoo removed the server-side
C<name_get> method in the 17 series in favour of the C<display_name>
field; this method detects that once per client and transparently
reads C<display_name> instead, so callers get the same shape on every
supported series.

=cut

sub name_get ($self, $ids, %opts) {
    return $self->_labels_via_read( $ids, %opts )
        if $self->{client}{_no_name_get};
    my $pairs;
    my $ok = eval {
        $pairs = $self->{client}->execute_kw(
            $self->{name}, 'name_get',
            [$ids],
            _kwargs(\%opts),
        );
        1;
    };
    return $pairs if $ok;
    my $err = $@;
    if ( blessed($err) && $err->isa('Odoo::Error') && $err->is_fault
        && $err->message =~ /name_get/ )
    {
        $self->{client}{_no_name_get} = 1;
        return $self->_labels_via_read( $ids, %opts );
    }
    die $err;
}

sub _labels_via_read ($self, $ids, %opts) {
    my $rows = $self->read( $ids, ['display_name'], %opts );
    return [ map { [ $_->{id}, $_->{display_name} ] } @$rows ];
}

sub name_search ($self, $text, %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'name_search',
        [$text],
        _kwargs(\%opts, qw(operator limit)),
    );
}

sub default_get ($self, $fields, %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'default_get',
        [$fields],
        _kwargs(\%opts),
    );
}

=head2 defaults(\@fields?, %opts)

The server's suggested default values as a hashref - what a fresh
form would be pre-filled with. Without an explicit field list it asks
over C<default_fields>; pass C<context> to get context-dependent
defaults (C<default_partner_id> and friends work here too).

=cut

sub defaults ($self, $fields = undef, %opts) {
    return $self->default_get( $fields // $self->default_fields, %opts );
}

sub read_group ($self, $domain, $fields, $groupby, %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'read_group',
        [ $domain, $fields, $groupby ],
        _kwargs(\%opts, qw(offset limit orderby lazy)),
    );
}

#--- records ------------------------------------------------------------------

=head2 browse($id) / browse(\@ids)

A lazy L<Odoo::Record> for one id (no RPC until a field is touched),
or a lazy L<Odoo::RecordSet> for an arrayref of ids. C<< fields =>
\@list >> narrows what loads; the default is every stored non-binary
field.

=cut

sub browse ($self, $ids, %opts) {
    if ( ref $ids eq 'ARRAY' ) {
        return Odoo::RecordSet->new(
            model  => $self,
            ids    => $ids,
            fields => $opts{fields},
        );
    }
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'browse takes a record id or an arrayref of ids',
    ) if !defined $ids || ref $ids;
    return $self->record_class->new(
        model  => $self,
        id     => $ids,
        fields => $opts{fields},
    );
}

=head2 find(\@domain, %opts)

The first matching record, loaded in a single RPC, or undef.

=cut

sub find ($self, $domain = [], %opts) {
    my $fields = delete $opts{fields};
    my $rows   = $self->search_read( $domain, $fields // $self->default_fields,
        limit => 1, %opts );
    return undef if !@$rows;
    return $self->record_from_row( $rows->[0], fields => $fields );
}

=head2 search_rs(\@domain, %opts)

Like C<search>, but the ids come back as an L<Odoo::RecordSet>.

=cut

sub search_rs ($self, $domain = [], %opts) {
    my $fields = delete $opts{fields};
    my $ids    = $self->search( $domain, %opts );
    return Odoo::RecordSet->new(
        model  => $self,
        ids    => $ids,
        fields => $fields,
    );
}

sub record_from_row ($self, $row, %opts) {
    return $self->record_class->new(
        model  => $self,
        id     => $row->{id},
        data   => $row,
        fields => $opts{fields},
    );
}

=head2 default_fields

What records load unless narrowed: stored scalar and many2one
fields. Three kinds stay out of the bulk read, all fetched on demand
the moment something asks for them:

    binary      - attachments and images are heavyweight
    non-stored  - computing them can touch models the user has no
                  rights to (the group-gated counters on res.partner)
    x2many      - resolved by searching the comodel, which both costs
                  a query per field and faults outright when the user
                  cannot read that comodel (invoice_ids for a
                  stock-only user, say)

So a lean default read succeeds for restricted users, and an access
error can only come from a field the caller actually touched.

A stored C<properties> field (C<crm.lead.lead_properties> from Odoo 16's
CRM on) stays in the default read: probed live on 16, 18 and 19, it
reads without a fault and answers a list of definition hashes, each with
its C<value>. It has no portable type (see L<Odoo::Portable>).

=cut

my %ON_DEMAND_TYPE = map { $_ => 1 } qw(binary one2many many2many);

sub default_fields ($self) {
    return $self->{default_fields} //= do {
        my $fields = $self->fields;
        [   sort grep {
                $fields->{$_}{store}
                    && !$ON_DEMAND_TYPE{ $fields->{$_}{type} // '' }
            } keys %$fields
        ];
    };
}

=head2 record_class

The package records of this model bless into. Plain Odoo::Record
unless the client was built with an C<overlay> namespace and
C<< <overlay>::<CamelizedModel> >> exists (C<sale.order.line> looks
for C<...::SaleOrderLine>), in which case that class is put in front
of Odoo::Record in the ISA chain - its methods win over field
accessors, and it may override the base methods deliberately.

=cut

sub record_class ($self) {
    return $self->{record_class} //= do {
        my $suffix = _camelize( $self->{name} );
        # Distinct generated package per overlay namespace, so clients
        # with different (or no) overlays never share an ISA chain.
        my $ns  = ( $self->{client}->overlay // '_plain' ) =~ s/::/_/gr;
        my $pkg = "Odoo::Record::_auto::${ns}::$suffix";
        no strict 'refs';
        if ( !@{"${pkg}::ISA"} ) {
            my @isa = ('Odoo::Record');
            if ( my $ns = $self->{client}->overlay ) {
                my $overlay = "${ns}::$suffix";
                unshift @isa, $overlay if _try_load($overlay);
            }
            @{"${pkg}::ISA"} = @isa;
        }
        $pkg;
    };
}

sub _camelize ($model) {
    return join '',
        map { join '', map { ucfirst lc $_ } split /_/ } split /\./, $model;
}

# Missing overlay modules are fine; broken ones must not be silently
# ignored.
sub _try_load ($pkg) {
    ( my $file = "$pkg.pm" ) =~ s{::}{/}g;
    return 1 if $INC{$file};
    my $ok = eval { require $file; 1 };
    return 1 if $ok;
    return 0 if $@ =~ /^Can't locate \Q$file\E/;
    die $@;
}

#--- write path ---------------------------------------------------------------

=head2 create(\%vals, %opts) / create(\@vals_list, %opts)

Creates a record and returns its id. With an arrayref of hashrefs,
batch-creates and returns an arrayref of ids (Odoo's own semantics,
passed through). Values for x2many fields take command triplets -
build them with L<Odoo::Commands> rather than writing bare numbers.
To clear a field, pass C<undef>: it goes to the server as false/null,
which is Odoo's empty value.

=cut

sub create ($self, $vals, %opts) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'create takes a hashref of values, or an arrayref of them',
    ) if ref $vals ne 'HASH' && ref $vals ne 'ARRAY';
    return $self->{client}->execute_kw(
        $self->{name}, 'create',
        [$vals],
        _kwargs(\%opts),
    );
}

=head2 call($method, \@args, %kwargs)

Any model method over RPC, for the long tail the named methods do
not cover (a button action such as C<action_confirm>, a wizard step,
C<message_post>): positional C<@args> (the ids first when the method
expects a recordset) and keyword arguments as given; C<context> is
merged with the client's as everywhere.

    $so->call( 'action_confirm', [$id] );
    $lead->call( 'message_post', [$id], body => 'Called back', message_type => 'comment' );

=cut

sub call ($self, $method, $args = undef, %kwargs) {
    Odoo::Error->throw( kind => 'usage', message => 'call takes an arrayref of positional args' )
        if defined $args && ref $args ne 'ARRAY';
    return $self->{client}->execute_kw( $self->{name}, $method, $args // [], \%kwargs );
}

=head2 create_record(\%vals, %opts)

C<create> followed by C<browse>: returns the new row as a lazy
L<Odoo::Record> (or, for a batch, an L<Odoo::RecordSet>).

=cut

sub create_record ($self, $vals, %opts) {
    return $self->browse( $self->create( $vals, %opts ) );
}

=head2 write($ids, \%vals, %opts)

Writes the same values to one id or an arrayref of ids. Returns true
on success (a failure is a fault, not a return value).

=cut

sub write ($self, $ids, $vals, %opts) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'write takes a hashref of values',
    ) if ref $vals ne 'HASH';
    return $self->{client}->execute_kw(
        $self->{name}, 'write',
        [ _ids($ids), $vals ],
        _kwargs(\%opts),
    );
}

=head2 unlink($ids, %opts)

Deletes one id or an arrayref of ids. Named after the Odoo method.

=cut

sub unlink ($self, $ids, %opts) {
    return $self->{client}->execute_kw(
        $self->{name}, 'unlink',
        [ _ids($ids) ],
        _kwargs(\%opts),
    );
}

=head2 copy($id, \%defaults, %opts)

Duplicates one record, optionally overriding fields, and returns the
new id. Odoo 18 and later answer C<copy> with a list of ids (the method
became multi-record, live 2026-10-13 on 19.0); a single-id copy still
returns one id here on every series.

=cut

sub copy ($self, $id, $defaults = undef, %opts) {
    my $kw = _kwargs(\%opts);
    $kw->{default} = $defaults if $defaults;
    my $ret = $self->{client}->execute_kw(
        $self->{name}, 'copy',
        [ _ids($id) ],
        $kw,
    );
    return $ret->[0] if ref $ret eq 'ARRAY' && @$ret == 1 && !ref $id;
    return $ret;
}

sub _ids ($ids) {
    return $ids if ref $ids eq 'ARRAY';
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'expected a record id or an arrayref of ids',
    ) if !defined $ids || ref $ids;
    return [$ids];
}

=head2 execute($method, \@args, \%kwargs)

Escape hatch for any other model method, pre-filled with the model
name - button actions (C<action_confirm>), wizards, and the rest.

=cut

sub execute ($self, $method, $args = [], $kwargs = {}) {
    return $self->{client}->execute_kw($self->{name}, $method, $args, $kwargs);
}

# Build kwargs from %opts: pass through context plus the listed keys,
# and refuse anything else so a typo fails loudly instead of being
# silently dropped.
sub _kwargs ($opts, @allowed) {
    my %allowed = map { $_ => 1 } @allowed, 'context';
    my %kw;
    for my $k (keys %$opts) {
        Odoo::Error->throw(
            kind    => 'usage',
            message => "unknown option '$k' (allowed: " . join(', ', sort keys %allowed) . ')',
        ) if !$allowed{$k};
        $kw{$k} = $opts->{$k} if defined $opts->{$k};
    }
    return \%kw;
}

1;

package Odoo::Test::FakeOdoo;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use JSON::PP ();
use MIME::Base64 ();

use Odoo::Error;

# A small in-memory Odoo behind the transport interface: enough ORM
# (fields_get, search/search_read/search_count/read, create, write,
# unlink, x2many commands, many2one [id, name] reads, simple domains)
# to exercise the ops layer end to end without a server. Every call is
# recorded in ->calls, like MockTransport.
#
#   my $fake = Odoo::Test::FakeOdoo->new(
#       series => 16,
#       fields => { 'crm.lead' => { name => { type => 'char', store => 1 }, ... } },
#       records => { 'crm.lead' => [ { name => 'x' }, ... ] },
#   );

sub new ($class, %args) {
    my $self = bless {
        series  => $args{series} // 16,
        fields  => $args{fields} // {},
        data    => {},
        next_id => {},
        calls   => [],
        fail    => $args{fail} // {},     # "model.method" => Odoo::Error
        methods => $args{methods} // {},  # "model.method" => sub ($fake, $ids, @args)
        # which key read_group rows carry the group size under: "default" is
        # what 16, 18 and 19 were probed to do (live 2026-10-13: <field>_count
        # for a lazy grouping, __count for lazy=false); "field", "__count" and
        # "both" force a shape so a reader is tested against each
        count_key => $args{count_key} // q(default),
        # credentials: with secrets (login => password) common.authenticate
        # answers a uid only for a login and password (or a minted key) it
        # knows; without, it answers 2 for anything
        pw          => { %{ $args{secrets} // {} } },
        keys        => {},
        strict_auth => $args{secrets} ? 1 : 0,
        # what the test user may not read (see refuse_model, unreadable_field), and
        # require_fields: a search_read or read with no field list is a fault of
        # the test, as it would be a call that lets Odoo choose the fields
        refused        => {},
        unreadable     => {},
        require_fields => $args{require_fields} ? 1 : 0,
        fieldless      => [],
    }, $class;
    for my $m ( keys %{ $args{records} // {} } ) {
        $self->insert( $m, $_ ) for @{ $args{records}{$m} };
    }
    return $self;
}

sub name  ($self) { 'fake' }
sub calls ($self) { $self->{calls} }

sub object_calls ($self, $method = undef) {
    return [ grep { $_->[1] eq 'execute_kw' && ( !defined $method || $_->[6] eq $method ) }
            @{ $self->{calls} } ];
}

sub insert ($self, $model, $vals) {
    my $id = $vals->{id} // ++$self->{next_id}{$model};
    $self->{next_id}{$model} = $id if $id > ( $self->{next_id}{$model} // 0 );
    $self->{data}{$model}{$id} = { active => 1, %$vals, id => $id };
    # what Odoo computes from a file's content, for a row seeded with datas
    if ( $model eq 'ir.attachment' && defined $vals->{datas} && !defined $vals->{checksum} ) {
        my $bytes = MIME::Base64::decode_base64( $vals->{datas} );
        @{ $self->{data}{$model}{$id} }{qw(file_size checksum)} = ( length $bytes, Digest::SHA::sha1_hex($bytes) );
    }
    return $id;
}

# A model the test user has no rights on: every read of it faults the way Odoo
# words it (fields_get stays open, as on a real server).
sub refuse_model ($self, $model, $label, @groups) {
    $self->{refused}{$model} = { label => $label, groups => [@groups] };
    return $self;
}
sub allow_model ($self, $model) { delete $self->{refused}{$model}; return $self }

# Models the server does not have at all (their module is not installed): any call on them fails
# with a KeyError, as a registry lookup does, and not as an access refusal.
sub no_such_model ($self, @models) {
    $self->{no_model}{$_} = 1 for @models;
    return $self;
}

# A computed field whose compute reads a model the test user may not: reading
# the field (named, or by a read that names none) faults; any other field reads.
sub unreadable_field ($self, $model, $field, $label, $relation, @groups) {
    $self->{unreadable}{$model}{$field} = { label => $label, relation => $relation, groups => [@groups] };
    return $self;
}

# Narrows an unreadable_field to some records: the compute faults only for a read that
# reaches one of these ids (a mailing on partners filtered by invoices, among others).
sub unreadable_rows ($self, $model, $field, @ids) {
    $self->{unreadable}{$model}{$field}{ids} = { map { $_ => 1 } @ids };
    return $self;
}

sub _access_fault ($self, $label, $relation, $groups) {
    _fault( 'AccessError', "You are not allowed to access '$label' ($relation) records.\n"
        . ( @$groups ? "This operation is allowed for the following groups:\n" . join( '', map { "\t- $_\n" } @$groups ) : '' ) );
}

# the read calls that named no fields, as "model.method"
sub fieldless ($self) { $self->{fieldless} }

sub record ($self, $model, $id) { $self->{data}{$model}{$id} }
sub all_ids ($self, $model) { [ sort { $a <=> $b } keys %{ $self->{data}{$model} // {} } ] }

# the uid of the user whose login and password (or minted key) these are, else 0
# "field [asc|desc], field ..." on fields the fake models.
# A many2one sorts by its id, an empty value before any other, ties by id ascending (Odoo's own tie-break).
sub _ordered ($self, $model, $ids, $order) {
    my @terms = map { /\A\s*(\w+)(?:\s+(asc|desc))?\s*\z/i ? [ $1, lc( $2 // 'asc' ) ] : die "fake: unsupported order '$order'\n" } split /,/, $order;
    # a field the fake does not model is not sorted on (as before this sorted at all): the ids stay as they are
    return @$ids if grep { $_->[0] ne 'id' && !$self->{fields}{$model}{ $_->[0] } } @terms;
    my $key = sub ($id, $f) {
        my $v = $f eq 'id' ? $id : $self->{data}{$model}{$id}{$f};
        $v = $v->[0] if ref $v eq 'ARRAY';
        return defined $v && !ref $v ? $v : '';
    };
    return sort {
        my $r = 0;
        for my $t (@terms) {
            my ( $x, $y ) = ( $key->( $a, $t->[0] ), $key->( $b, $t->[0] ) );
            $r = ( $x =~ /\A-?\d+(?:\.\d+)?\z/ && $y =~ /\A-?\d+(?:\.\d+)?\z/ ) ? $x <=> $y : $x cmp $y;
            $r = -$r if $t->[1] eq 'desc';
            last if $r;
        }
        $r || $a <=> $b;
    } @$ids;
}

sub _authenticate ($self, $login, $secret) {
    return 0 if !defined $login || !defined $secret;
    my ($user) = grep { $_->{login} eq $login } values %{ $self->{data}{'res.users'} // {} };
    return 0 if !$user || !$user->{active};
    # like Odoo, a user with two-factor on cannot RPC-authenticate by password, only by key
    my $by_pw = ( $self->{pw}{$login} // '' ) eq $secret && !$user->{totp_enabled};
    return 0 if !( $by_pw || $self->{keys}{$login}{$secret} );
    return $user->{id};
}

# a key Odoo would have minted for a login
sub add_key ($self, $login, $key) { $self->{keys}{$login}{$key} = 1 }
sub password_of ($self, $login) { $self->{pw}{$login} }

# a web session as one user, for the operations that need one
sub web_session ($self) { Odoo::Test::FakeOdoo::Session->new($self) }

sub _fault ($class, $msg) {
    Odoo::Error->throw( kind => 'fault', message => $msg, fault_class => "odoo.exceptions.$class" );
}

sub call ($self, $service, $method, @args) {
    push @{ $self->{calls} }, [ $service, $method, @args ];
    if ( $service eq 'common' ) {
        return { server_version => "$self->{series}.0", server_serie => "$self->{series}.0" }
            if $method eq 'version';
        if ( $method eq 'authenticate' ) {
            return 2 if !$self->{strict_auth};
            my ( undef, $login, $secret ) = @args;
            return $self->_authenticate( $login, $secret );
        }
    }
    my ( $db, $uid, $key, $model, $m, $margs, $kw ) = @args;
    local $self->{caller_uid} = $uid;
    $margs //= [];
    $kw    //= {};
    if ( my $r = $self->{refused}{ $model // '' } ) {
        $self->_access_fault( $r->{label}, $model, $r->{groups} ) if $m ne 'fields_get';
    }
    if ( $m eq 'search_read' || $m eq 'read' ) {
        my $named = $kw->{fields} && @{ $kw->{fields} };
        if ( !$named ) {
            push @{ $self->{fieldless} }, "$model.$m";
            _fault( 'UserError', "fake: $model.$m with no fields (require_fields): the read lets Odoo choose them" ) if $self->{require_fields};
        }
        if ( my $u = $self->{unreadable}{$model} ) {
            my @want = $named ? @{ $kw->{fields} } : keys %{ $self->{fields}{$model} // {} };
            my @reach;
            for my $f ( sort grep { $u->{$_} } @want ) {
                if ( my $only = $u->{$f}{ids} ) {
                    @reach = $m eq 'read' ? @{ $margs->[0] } : $self->_search( $model, $margs->[0] // [], $kw->{context} )
                        if !@reach;
                    next if !grep { $only->{$_} } @reach;
                }
                $self->_access_fault( $u->{$f}{label}, $u->{$f}{relation}, $u->{$f}{groups} );
            }
        }
    }
    if ( my $e = $self->{fail}{"$model.$m"} ) { die $e }
    if ( my $impl = $self->{methods}{"$model.$m"} ) { return $impl->( $self, $margs, $kw ) }
    # The configured user reads itself; other users are read from the
    # data when the test defines res.users.
    if ( $model eq 'res.users' && $m eq 'read' && !grep { $self->{data}{'res.users'}{$_} } @{ $margs->[0] } ) {
        return [ { id => 2, login => 'tester', name => 'Test User', email => 'tester@ours.example',
                partner_id => [ 7, 'Test User' ] } ];
    }
    # a model of a module the server lacks: Odoo's registry lookup fails with a KeyError, which is no access fault
    Odoo::Error->throw( kind => 'fault', message => "KeyError: '$model'", fault_class => 'builtins.KeyError' ) if $self->{no_model}{$model};
    my $f = $self->{fields}{$model} or _fault( 'AccessError', "unknown model $model" );
    return {%$f} if $m eq 'fields_get';
    # Odoo's defaults: a field whose definition carries a default has one (what a new record would get)
    return { map { $_ => $f->{$_}{default} } grep { exists $f->{$_}{default} } @{ $margs->[0] // [] } } if $m eq 'default_get';

    if ( $m eq 'search_read' || $m eq 'search' || $m eq 'search_count' ) {
        my @ids = $self->_search( $model, $margs->[0] // [], $kw->{context} );
        # order: the one the operations ask for, id (ascending) or id desc
        @ids = reverse @ids if ( $kw->{order} // '' ) =~ /\Aid desc\z/i;
        @ids = $self->_ordered( $model, \@ids, $kw->{order} ) if ( $kw->{order} // '' ) =~ /,|\A(?!id\b)\w/;
        @ids = @ids[ ( $kw->{offset} // 0 ) .. $#ids ] if $kw->{offset};
        @ids = @ids[ 0 .. $kw->{limit} - 1 ] if $kw->{limit} && @ids > $kw->{limit};
        return scalar @ids if $m eq 'search_count';
        return \@ids if $m eq 'search';
        return [ map { $self->_read_row( $model, $_, $kw->{fields} ) } @ids ];
    }
    # a write of any kind moves the model's newest write_date (to the second, as Odoo reports it) off the fake's clock
    $self->{wd}{$model} = _wd_stamp( $self->{clock} // 1_800_000_000 )
        if $m =~ /\A(?:create|write|unlink|action_archive|action_unarchive)\z/;
    # the data cache's signal: no grouping, the newest write_date and every record, archived ones too
    if ( $m eq 'read_group' && ref $margs->[2] eq 'ARRAY' && !@{ $margs->[2] } ) {
        my @all = $self->_search( $model, [], { active_test => 0 } );
        my $n = scalar @all;
        return [ { __count => $n, write_date => $self->{wd}{$model} // JSON::PP::false } ];
    }
    # read_group with aggregates, several levels or a date granularity (lazy off): the row shape met live on 16 and 18 -
    # the groupby values (a many2one as [id, label], a date as the granularity's label), the aggregates under their field
    # names, __count, __domain and, for a date, __range; 18 answers id:count under id, 16 does not
    if ( $m eq 'read_group' && $self->_rich_group($margs) ) {
        return $self->_read_group_rich( $model, $f, $margs, $kw );
    }
    if ( $m eq 'read_group' ) {
        # 16-series row shape: <field>_count; many2many groups per member.
        my ( $domain, undef, $groupby ) = @$margs;
        my $g    = ref $groupby ? $groupby->[0] : $groupby;
        my $type = $f->{$g}{type} // '';
        my %n;
        for my $id ( $self->_search( $model, $domain ) ) {
            my $v = $self->{data}{$model}{$id}{$g};
            my @keys = $type eq 'many2many' ? ( @{ $v // [] } ? @$v : ('') ) : ( $v // '' );
            $n{$_}++ for @keys;
        }
        return [ map {
            my $k = $_;
            my $val = $k eq '' ? 0
                : $type =~ /^many2/ ? [ $k, $self->{data}{ $f->{$g}{relation} }{$k}{name} // "#$k" ]
                : $k;
            +{ $g => $val, $self->_count_keys( $kw, $g, $n{$k} ) }
        } sort keys %n ];
    }
    if ( $m eq 'read' ) {
        return [ map { $self->_read_row( $model, $_, $kw->{fields} ) }
                grep { $self->{data}{$model}{$_} } @{ $margs->[0] } ];
    }
    if ( $m eq 'create' ) {
        my $v = $margs->[0];
        return [ map { $self->_create( $model, $_ ) } @$v ] if ref $v eq 'ARRAY';
        return $self->_create( $model, $v );
    }
    if ( $m eq 'write' ) {
        my ( $ids, $vals ) = @$margs;
        for my $id (@$ids) {
            my $r = $self->{data}{$model}{$id} or _fault( 'MissingError', "record $id gone" );
            $self->_assign( $model, $r, $vals );
        }
        return 1;
    }
    if ( $m eq 'unlink' ) {
        $self->_unlink( $model, $_ ) for @{ $margs->[0] };
        return 1;
    }
    # Odoo's own archive actions (the active mixin): a model without an active field has none
    if ( $m eq 'action_archive' || $m eq 'action_unarchive' ) {
        _fault( 'AttributeError', "type object '$model' has no attribute '$m'" ) if !$f->{active};
        for my $id ( @{ $margs->[0] } ) {
            my $r = $self->{data}{$model}{$id} or _fault( 'MissingError', "record $id gone" );
            $r->{active} = $m eq 'action_archive' ? 0 : 1;
        }
        return JSON::PP::true;
    }
    _fault( 'UserError', "fake has no method $model.$m" );
}

# What deleting a record does to the rows that point at it, from the
# ir.model.fields rows a test declares (ttype many2one with on_delete, or
# many2many): restrict refuses as Odoo does, set null clears the pointer,
# cascade deletes the referencing row, a many2many link is dropped. A test
# that seeded no ir.model.fields gets a plain delete.
sub _unlink ($self, $model, $id) {
    my @refs = grep { ( $_->{relation} // '' ) eq $model && $self->{fields}{ $_->{model} }{ $_->{name} } }
        values %{ $self->{data}{'ir.model.fields'} // {} };
    my $points = sub ($r, $f) { defined $r->{$f} && !ref $r->{$f} && $r->{$f} == $id };
    for my $ref (@refs) {
        next if ( $ref->{ttype} // '' ) ne 'many2one' || ( $ref->{on_delete} // '' ) ne 'restrict';
        for my $rid ( @{ $self->all_ids( $ref->{model} ) } ) {
            _fault( 'UserError', "Unable to delete this document because it is used as a value in $ref->{model} (field $ref->{name}) with restrict" )
                if $points->( $self->{data}{ $ref->{model} }{$rid}, $ref->{name} );
        }
    }
    for my $ref (@refs) {
        my ( $rm, $rf ) = @$ref{qw(model name)};
        for my $rid ( @{ $self->all_ids($rm) } ) {
            my $r = $self->{data}{$rm}{$rid} or next;
            if ( ( $ref->{ttype} // '' ) eq 'many2many' ) {
                $r->{$rf} = [ grep { $_ != $id } @{ $r->{$rf} // [] } ];
            }
            elsif ( $points->( $r, $rf ) ) {
                if ( ( $ref->{on_delete} // '' ) eq 'cascade' ) { $self->_unlink( $rm, $rid ) }
                else { $r->{$rf} = undef }
            }
        }
    }
    delete $self->{data}{$model}{$id};
}

sub _rich_group ($self, $margs) {
    my ( undef, $fields, $groupby ) = @$margs;
    my @g = ref $groupby ? @$groupby : ($groupby);
    return 1 if @g > 1 || grep { /:/ } @g;
    return 1 if grep { /:|\A__count\z/ } @{ $fields // [] };
    return 0;
}

my @MONTHS = qw(January February March April May June July August September October November December);

# "date:month" of a date: the label Odoo shows, the first day, the first day after
sub _date_bucket ($self, $gran, $v) {
    return ( 0, undef, undef ) if !defined $v || $v eq '';
    my ( $y, $mo, $d ) = split /-/, $v;
    if ( $gran eq 'month' ) {
        my ( $ny, $nm ) = $mo == 12 ? ( $y + 1, 1 ) : ( $y, $mo + 1 );
        return ( "$MONTHS[$mo-1] $y", sprintf( '%04d-%02d-01', $y, $mo ), sprintf( '%04d-%02d-01', $ny, $nm ) );
    }
    if ( $gran eq 'year' ) { return ( "$y", "$y-01-01", sprintf( '%04d-01-01', $y + 1 ) ) }
    die "fake: read_group granularity $gran is not modelled\n";
}

sub _read_group_rich ($self, $model, $f, $margs, $kw) {
    my ( $domain, $fields, $groupby ) = @$margs;
    my @g = map { my ( $n, $gr ) = split /:/, $_, 2; { name => $n, gran => $gr, key => $_ } } ref $groupby ? @$groupby : ($groupby);
    my @agg = map { my ( $n, $fn ) = split /:/, $_, 2; { name => $n, fn => $fn } } grep { $_ ne '__count' } @{ $fields // [] };
    my ( %group, @order );
    for my $id ( $self->_search( $model, $domain // [], $kw->{context} ) ) {
        my $r = $self->{data}{$model}{$id};
        my @key = map {
            my $v = $r->{ $_->{name} };
            $_->{gran} ? ( ( $self->_date_bucket( $_->{gran}, $v ) )[0] ) : ( ref $v eq 'ARRAY' ? $v->[0] : ( $v // 0 ) )
        } @g;
        my $k = join "\0", @key;
        if ( !$group{$k} ) { $group{$k} = { recs => [], key => \@key }; push @order, $k }
        push @{ $group{$k}{recs} }, $r;
    }
    my @rows;
    for my $k (@order) {
        my $grp = $group{$k};
        my %row = ( __count => scalar @{ $grp->{recs} } );
        my @dom;
        for my $i ( 0 .. $#g ) {
            my ( $gi, $v0 ) = ( $g[$i], $grp->{recs}[0]{ $g[$i]{name} } );
            my $def = $f->{ $gi->{name} } // {};
            if ( $gi->{gran} ) {
                my ( $label, $from, $to ) = $self->_date_bucket( $gi->{gran}, $v0 );
                $row{ $gi->{key} } = $label;
                $row{__range}{ $gi->{key} } = { from => $from, to => $to };
                push @dom, [ $gi->{name}, '>=', $from ], [ $gi->{name}, '<', $to ];
            }
            elsif ( ( $def->{type} // '' ) eq 'many2one' ) {
                my $id = ref $v0 eq 'ARRAY' ? $v0->[0] : $v0;
                $row{ $gi->{name} } = $id ? [ $id, $self->{data}{ $def->{relation} }{$id}{name} // "#$id" ] : JSON::PP::false;
                push @dom, [ $gi->{name}, '=', $id || JSON::PP::false ];
            }
            else {
                $row{ $gi->{name} } = defined $v0 && $v0 ne '' ? $v0 : JSON::PP::false;
                push @dom, [ $gi->{name}, '=', $row{ $gi->{name} } ];
            }
        }
        $row{__domain} = [ @dom, @{ $domain // [] } ];
        for my $ag (@agg) {
            my @v = map { my $x = $_->{ $ag->{name} }; ref $x eq 'ARRAY' ? $x->[0] : ( $x // 0 ) } @{ $grp->{recs} };
            my $fn = $ag->{fn} // 'sum';
            if    ( $fn eq 'sum' ) { my $t = 0; $t += $_ for @v; $row{ $ag->{name} } = $t }
            elsif ( $fn eq 'avg' ) { my $t = 0; $t += $_ for @v; $row{ $ag->{name} } = @v ? $t / @v : 0 }
            elsif ( $fn eq 'min' ) { my ($x) = sort { $a <=> $b } @v; $row{ $ag->{name} } = $x }
            elsif ( $fn eq 'max' ) { my ($x) = sort { $b <=> $a } @v; $row{ $ag->{name} } = $x }
            elsif ( $fn eq 'count' ) { $row{ $ag->{name} } = scalar @v if $self->{series} >= 18 }
            elsif ( $fn eq 'count_distinct' ) { $row{ $ag->{name} } = scalar keys %{ { map { ( $_ => 1 ) } @v } } }
            else  { die "fake: read_group aggregate $fn is not modelled\n" }
        }
        push @rows, \%row;
    }
    if ( defined $kw->{orderby} && length $kw->{orderby} ) {
        my @terms = map { /\A\s*(\S+)(?:\s+(asc|desc))?\s*\z/i ? [ $1, lc( $2 // 'asc' ) ] : die "fake: unsupported orderby\n" } split /,/, $kw->{orderby};
        my $val = sub ($row, $n) { my $v = $row->{$n}; $v = $v->[0] if ref $v eq 'ARRAY'; return defined $v && !ref $v ? $v : '' };
        @rows = sort {
            my $r = 0;
            for my $t (@terms) {
                my ( $x, $y ) = ( $val->( $a, $t->[0] ), $val->( $b, $t->[0] ) );
                $r = ( $x =~ /\A-?\d+(?:\.\d+)?\z/ && $y =~ /\A-?\d+(?:\.\d+)?\z/ ) ? $x <=> $y : $x cmp $y;
                $r = -$r if $t->[1] eq 'desc';
                last if $r;
            }
            $r;
        } @rows;
    }
    @rows = $kw->{offset} > $#rows ? () : @rows[ $kw->{offset} .. $#rows ] if $kw->{offset};
    @rows = @rows[ 0 .. $kw->{limit} - 1 ] if $kw->{limit} && @rows > $kw->{limit};
    return \@rows;
}

sub _count_keys ($self, $kw, $g, $n) {
    my $shape = $self->{count_key};
    $shape = ( !exists $kw->{lazy} || $kw->{lazy} ) ? q(field) : q(__count) if $shape eq q(default);
    return ( ( $shape eq q(field) || $shape eq q(both) ? ( "${g}_count" => $n ) : () ),
        ( $shape eq q(__count) || $shape eq q(both) ? ( __count => $n ) : () ) );
}

sub _create ($self, $model, $vals) {
    my $id = ++$self->{next_id}{$model};
    my $r  = { id => $id, active => 1 };
    $self->{data}{$model}{$id} = $r;
    $self->_assign( $model, $r, $vals );
    # Odoo stamps who made a record, as the session's uid
    $r->{create_uid} = $self->{caller_uid} if $self->{fields}{$model}{create_uid} && !exists $vals->{create_uid};
    return $id;
}

sub _assign ($self, $model, $r, $vals) {
    my $f = $self->{fields}{$model};
    for my $k ( keys %$vals ) {
        my $type = $f->{$k}{type} // _fault( 'ValidationError', "no field $k on $model" );
        my $v    = $vals->{$k};
        if ( $type eq 'many2many' || $type eq 'one2many' ) {
            my %set = map { $_ => 1 } @{ $r->{$k} // [] };
            for my $cmd (@$v) {
                my ( $op, $id, $arg ) = @$cmd;
                if    ( $op == 6 ) { %set = map { $_ => 1 } @$arg }
                elsif ( $op == 4 ) { $set{$id} = 1 }
                elsif ( $op == 3 ) { delete $set{$id} }
                elsif ( $op == 5 ) { %set = () }
                elsif ( $op == 0 ) {
                    # a one2many create points the child back at its parent (relation_field)
                    my %child = %$arg;
                    $child{ $f->{$k}{relation_field} } = $r->{id} if $type eq 'one2many' && $f->{$k}{relation_field};
                    $set{ $self->_create( $f->{$k}{relation}, \%child ) } = 1;
                }
            }
            $r->{$k} = [ sort { $a <=> $b } keys %set ];
        }
        elsif ( $model eq 'res.users' && $k eq 'password' ) {
            $self->{pw}{ $r->{login} } = $v;
        }
        else {
            # Like Odoo: a false or null clears a text or date field; a number
            # written to a char is stored as its text ("0", not empty)
            if ( $type =~ /^(char|text|html|selection|date|datetime)\z/ ) {
                my $falsy = !defined $v || ( ref $v && eval { $v->isa('JSON::PP::Boolean') } && !$v );
                if    ($falsy)                                    { $v = undef }
                elsif ( $type =~ /^(date|datetime)\z/ && !$v ) { $v = undef }    # a falsy date is no date
                elsif ( !ref $v ) { $v = "$v" }
            }
            $r->{$k} = $v;
        }
    }
    # what Odoo computes from a file's content
    if ( $model eq 'ir.attachment' && defined $vals->{datas} ) {
        my $bytes = MIME::Base64::decode_base64( $vals->{datas} );
        $r->{file_size} = length $bytes;
        $r->{checksum}  = Digest::SHA::sha1_hex($bytes);
    }
}

sub _read_row ($self, $model, $id, $fields) {
    my $r = $self->{data}{$model}{$id};
    my $f = $self->{fields}{$model};
    my @want = $fields && @$fields ? @$fields : keys %$f;
    my %row = ( id => $id );
    for my $k (@want) {
        next if $k eq 'id';
        my $type = $f->{$k}{type} // next;
        my $v    = $r->{$k};
        if ( $type eq 'many2one' ) {
            my $rel = $v ? $self->{data}{ $f->{$k}{relation} }{$v} : undef;
            $row{$k} = $rel ? [ $v, $rel->{name} // "#$v" ] : 0;
        }
        elsif ( $type eq 'many2many' || $type eq 'one2many' ) {
            $row{$k} = [ @{ $v // [] } ];
        }
        else {
            $row{$k} = defined $v && $v ne '' ? $v : 0;
        }
    }
    return \%row;
}

sub _wd_stamp ($t) {
    my @g = gmtime $t;
    return sprintf '%04d-%02d-%02d %02d:%02d:%02d', $g[5] + 1900, $g[4] + 1, @g[ 3, 2, 1, 0 ];
}

sub _search ($self, $model, $domain, $context = undef) {
    my @ids  = @{ $self->all_ids($model) };
    my @dom  = @$domain;
    # active_test => false lifts the implicit "active only" filter, as in Odoo
    my $has_active = ( grep { ref $_ eq 'ARRAY' && $_->[0] eq 'active' } @dom )
        || ( ref $context eq 'HASH' && exists $context->{active_test} && !$context->{active_test} );
    @dom = ( '&', [ 'active', '=', JSON::PP::true ], @dom ) if !$has_active && exists $self->{fields}{$model}{active} && @dom;
    @dom = ( [ 'active', '=', JSON::PP::true ] ) if !$has_active && exists $self->{fields}{$model}{active} && !@dom;
    # a dotted field ("location_id.usage") is followed through the many2one
    # the model declares; the row is matched with the value added beside it
    my %dotted = map { ref $_ eq 'ARRAY' && $_->[0] =~ /\./ ? ( $_->[0] => 1 ) : () } @dom;
    my $follow = sub ($path, $r) {
        my @p = split /\./, $path;
        my ( $rec, $m ) = ( $r, $model );
        while ( @p > 1 ) {
            my $fld = shift @p;
            my $def = $self->{fields}{$m}{$fld} // die "fake: no field $fld on $m for dotted domain $path\n";
            my $id  = ref $rec->{$fld} eq 'ARRAY' ? $rec->{$fld}[0] : $rec->{$fld};
            return undef if !defined $id || ref $id;
            $m   = $def->{relation} // die "fake: $fld on $model is not a relation ($path)\n";
            $rec = $self->{data}{$m}{$id} or return undef;
        }
        return $rec->{ $p[0] };
    };
    my $view = sub ($r) {
        return $r if !%dotted;
        return { %$r, map { $_ => $follow->( $_, $r ) } keys %dotted };
    };
    return grep { _eval_domain( $view->( $self->{data}{$model}{$_} ), [@dom] ) } @ids;
}

# Odoo domains: prefix '|', '&', '!' over terms; implicit '&' between
# consecutive top-level expressions.
sub _eval_domain ($r, $dom) {
    my $ok = 1;
    while (@$dom) { $ok = _eval_expr( $r, $dom ) && $ok }
    return $ok;
}

sub _eval_expr ($r, $dom) {
    my $t = shift @$dom;
    return !_eval_expr( $r, $dom ) if !ref $t && $t eq '!';
    if ( !ref $t && ( $t eq '|' || $t eq '&' ) ) {
        my $a = _eval_expr( $r, $dom );
        my $b = _eval_expr( $r, $dom );
        return $t eq '|' ? ( $a || $b ) : ( $a && $b );
    }
    return _match( $r, @$t );
}

# a SQL LIKE pattern as an anchored regex
sub _like_re ($pattern, $fold) {
    my $re = '';
    my @c  = split //, $pattern;
    while (@c) {
        my $c = shift @c;
        if    ( $c eq '\\' && @c ) { $re .= quotemeta shift @c }
        elsif ( $c eq '%' )        { $re .= '.*' }
        elsif ( $c eq '_' )        { $re .= '.' }
        else                       { $re .= quotemeta $c }
    }
    return $fold ? qr/^$re\z/is : qr/^$re\z/s;
}

sub _match ($r, $field, $op, $want) {
    my $v = $r->{$field};
    $v = $v->[0] if ref $v eq 'ARRAY' && $op ne 'in';
    my $s = defined $v ? "$v" : '';
    # Like Odoo, only a real boolean means "empty/set"; a bare 0 is a
    # value, so a domain written with 0 for false misbehaves here too.
    my $is_bool = ref $want && eval { $want->isa('JSON::PP::Boolean') };
    if ($is_bool) {
        return !!$v == !!$want if $op eq '=';
        return !!$v != !!$want if $op eq '!=';
    }
    return $s eq ( $want // '' ) if $op eq '=';
    return $s ne ( $want // '' ) if $op eq '!=';
    # Like Odoo's SQL LIKE: with =like and =ilike the value is the pattern,
    # so _ and % are wildcards and a backslash escapes the next character;
    # like and ilike wrap the value in %...% (unescaped, as Odoo does)
    return $s =~ _like_re( $want // '', $op eq '=ilike' ) if $op eq '=like' || $op eq '=ilike';
    return $s =~ _like_re( "%$want%", $op eq 'ilike' ) if $op eq 'like' || $op eq 'ilike';
    # ordering: dates (YYYY-MM-DD, with or without a time) compare as text, numbers as numbers
    if ( $op =~ /\A(?:>|<|>=|<=)\z/ ) {
        my $by_text = defined $want && $want =~ /\A\d{4}-\d{2}-\d{2}/;
        my ( $x, $y ) = $by_text ? ( $s, "$want" ) : ( $v // 0, $want );
        my $cmp = $by_text ? $x cmp $y : $x <=> $y;
        return $op eq '>' ? $cmp > 0 : $op eq '<' ? $cmp < 0 : $op eq '>=' ? $cmp >= 0 : $cmp <= 0;
    }
    if ( $op eq 'in' ) {
        my %w = map { $_ => 1 } @$want;
        return ref $r->{$field} eq 'ARRAY'
            ? scalar( grep { $w{$_} } @{ $r->{$field} } )
            : $w{ $s };
    }
    return !_match( $r, $field, 'in', $want ) if $op eq 'not in';
    die "fake: unsupported domain operator $op\n";
}

# A web session on the fake: authenticates a login and password, then
# carries the calls to the fake as that user.
package Odoo::Test::FakeOdoo::Session;

sub new ($class, $fake) { bless { fake => $fake, sid => undef, identity => undef }, $class }
sub name       ($self) { 'session' }
sub session_id ($self) { $self->{sid} }
sub identity   ($self) { $self->{identity} }

sub authenticate ($self, $db, $login, $password) {
    my $fake = $self->{fake};
    my ($user) = grep { $_->{login} eq $login } values %{ $fake->{data}{'res.users'} // {} };
    my $pw_ok = $user && ( $fake->{pw}{$login} // '' ) eq ( $password // '' );
    # the web login route: a right password with two-factor on opens no session
    return { second_factor => 'totp', pending => 1 }
        if $pw_ok && $user->{active} && $user->{totp_enabled};
    my $uid = $user && $user->{active} && ( $pw_ok || $fake->{keys}{$login}{ $password // '' } ) ? $user->{id} : 0;
    Odoo::Error->throw( kind => 'fault', message => 'authentication failed', fault_class => 'odoo.exceptions.AccessDenied' ) if !$uid;
    delete $fake->{idchecked}{$login};
    $self->{sid}      = "fake-session-$uid";
    $self->{identity} = { uid => $uid, login => $login };
    push @{ $self->{fake}{sessions} }, $login;
    return $self->{identity};
}

sub destroy ($self) {
    $self->{sid} = $self->{identity} = undef;
    $self->{fake}{destroyed}++;
    return 1;
}

sub call ($self, $service, $method, @params) {
    return $self->{identity}{uid} if $service eq 'common' && $method eq 'authenticate' && $self->{identity};
    # the version answer needs no session (version_info), as on the real route
    return $self->{fake}->call( $service, $method, @params ) if $service eq 'common' && $method eq 'version';
    Odoo::Error->throw( kind => 'fault', message => 'no session', fault_class => 'odoo.http.SessionExpiredException' ) if !defined $self->{sid};
    $self->{fake}{session_user} = $self->{identity}{login};
    return $self->{fake}->call( $service, $method, @params );
}

package Odoo::Test::FakeOdoo;

# --- the public password-reset page (auth_signup's /web/reset_password) ---------------------------------
# add_reset_token($token, login => , name => , db => [, expired => 1]): a link Odoo mailed. GET answers the
# form (or the "Invalid signup token" alert for a token it does not hold or that was used), POST checks the
# csrf token of the session's cookie, the two passwords and the token, sets the user's password and uses the
# token up. 16 and 18 redirect (303 to /web) on success; 19 renders the success message.
sub add_reset_token ($self, $token, %o) { $self->{reset}{$token} = { db => 'd', %o } }
sub reset_posts ($self) { $self->{reset_posts} // [] }

sub _reset_page ($self, $csrf, $token, $error, $info) {
    my $esc = sub ($s) { $s =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/"/&quot;/gr =~ s/'/&#39;/gr };
    my $html = qq(<html><body><form class="oe_reset_password_form" role="form" method="post">\n)
        . qq(<input type="hidden" name="csrf_token" value="$csrf"/>\n);
    if ($info && $self->{series} >= 19) {
        $html .= qq(<div class="mb-3 field-password pt-2"><input type="password" name="password" id="password" required="required"/></div>\n)
            . qq(<div class="mb-3 field-confirm_password"><input type="password" name="confirm_password" id="confirm_password" required="required"/></div>\n);
    }
    elsif ($info) {
        $html .= qq(<div class="mb-3 field-login"><label for="login">Your Email</label>\n)
            . qq(<input type="text" name="login" value="@{[ $esc->($info->{login}) ]}" id="login" class="form-control form-control-sm" autofocus="autofocus" autocapitalize="off" required="required" readonly="readonly"/></div>\n)
            . qq(<div class="mb-3 field-name"><input type="text" name="name" value="@{[ $esc->($info->{name} // '') ]}" id="name" required="required" readonly="readonly"/></div>\n)
            . qq(<div class="mb-3 field-password pt-2"><input type="password" name="password" id="password" required="required"/></div>\n)
            . qq(<div class="mb-3 field-confirm_password"><input type="password" name="confirm_password" id="confirm_password" required="required"/></div>\n);
    }
    $html .= qq(<p class="alert alert-danger" role="alert">\n    @{[ $esc->($error) ]}\n</p>\n) if defined $error;
    $html .= qq(<input type="hidden" name="redirect" value=""/>\n<input type="hidden" name="token" value="@{[ $esc->($token) ]}"/>\n)
        . qq(<button type="submit" class="btn btn-primary">Reset Password</button></form></body></html>\n);
    return $html;
}

package Odoo::Test::FakeOdoo::Session;

sub _csrf ($self) { $self->{csrf} //= 'csrf-' . ++$self->{fake}{csrf_n} }

sub get ($self, $path, %opts) {
    my $fake = $self->{fake};
    my ( $route, $q ) = split /\?/, $path, 2;
    return { status => 404, headers => {}, content => 'Not Found' } if $route ne '/web/reset_password';
    my %q = map { my ( $k, $v ) = split /=/, $_, 2; ( $k => ( $v // '' ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ger ) } split /&/, $q // '';
    my $info = $fake->{reset}{ $q{token} // '' };
    return { status => 200, headers => {}, content => $fake->_reset_page( $self->_csrf, $q{token} // '', 'Invalid signup token', undef ) }
        if !$info || $info->{used} || ( defined $q{db} && $q{db} ne $info->{db} );
    return { status => 200, headers => {}, content => $fake->_reset_page( $self->_csrf, $q{token}, undef, $info ) };
}

sub post_form ($self, $path, $f, %opts) {
    my $fake = $self->{fake};
    push @{ $fake->{reset_posts} }, { path => $path, fields => { %$f, password => '<hidden>', confirm_password => '<hidden>' } };
    return { status => 400, headers => {}, content => 'Session expired (invalid CSRF token)' } if ( $f->{csrf_token} // '' ) ne ( $self->{csrf} // '' );
    my $info = $fake->{reset}{ $f->{token} // '' };
    my $again = sub ($err) { { status => 200, headers => {}, content => $fake->_reset_page( $self->_csrf, $f->{token} // '', $err, $info ) } };
    return $again->('Invalid signup token') if !$info || $info->{used};
    return $again->('Passwords do not match; please retype them.') if ( $f->{password} // '' ) ne ( $f->{confirm_password} // '' );
    return $again->("Signup token '$f->{token}' is no longer valid") if $info->{expired};
    $fake->{pw}{ $info->{login} } = $f->{password};
    $info->{used} = 1;
    return { status => 200, headers => {}, content => '<html><p class="alert alert-success" role="status">Your password has been reset successfully.</p></html>' }
        if $fake->{series} >= 19;
    return { status => 303, headers => { location => '/web' }, content => '' };
}

1;

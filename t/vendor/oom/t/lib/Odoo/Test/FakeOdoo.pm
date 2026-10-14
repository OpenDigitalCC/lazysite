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
    return $id;
}

sub record ($self, $model, $id) { $self->{data}{$model}{$id} }
sub all_ids ($self, $model) { [ sort { $a <=> $b } keys %{ $self->{data}{$model} // {} } ] }

# the uid of the user whose login and password (or minted key) these are, else 0
sub _authenticate ($self, $login, $secret) {
    return 0 if !defined $login || !defined $secret;
    my $ok = ( $self->{pw}{$login} // '' ) eq $secret || $self->{keys}{$login}{$secret};
    return 0 if !$ok;
    for my $u ( values %{ $self->{data}{'res.users'} // {} } ) { return $u->{id} if $u->{login} eq $login }
    return 0;
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
    $margs //= [];
    $kw    //= {};
    if ( my $e = $self->{fail}{"$model.$m"} ) { die $e }
    if ( my $impl = $self->{methods}{"$model.$m"} ) { return $impl->( $self, $margs, $kw ) }
    # The configured user reads itself; other users are read from the
    # data when the test defines res.users.
    if ( $model eq 'res.users' && $m eq 'read' && !grep { $self->{data}{'res.users'}{$_} } @{ $margs->[0] } ) {
        return [ { id => 2, login => 'tester', name => 'Test User', email => 'tester@ours.example',
                partner_id => [ 7, 'Test User' ] } ];
    }
    my $f = $self->{fields}{$model} or _fault( 'AccessError', "unknown model $model" );
    return {%$f} if $m eq 'fields_get';

    if ( $m eq 'search_read' || $m eq 'search' || $m eq 'search_count' ) {
        my @ids = $self->_search( $model, $margs->[0] // [] );
        @ids = @ids[ ( $kw->{offset} // 0 ) .. $#ids ] if $kw->{offset};
        @ids = @ids[ 0 .. $kw->{limit} - 1 ] if $kw->{limit} && @ids > $kw->{limit};
        return scalar @ids if $m eq 'search_count';
        return \@ids if $m eq 'search';
        return [ map { $self->_read_row( $model, $_, $kw->{fields} ) } @ids ];
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
        delete $self->{data}{$model}{$_} for @{ $margs->[0] };
        return 1;
    }
    _fault( 'UserError', "fake has no method $model.$m" );
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

sub _search ($self, $model, $domain) {
    my @ids  = @{ $self->all_ids($model) };
    my @dom  = @$domain;
    my $has_active = grep { ref $_ eq 'ARRAY' && $_->[0] eq 'active' } @dom;
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
    return lc $s eq lc( $want // '' ) if $op eq '=ilike';
    if ( $op eq '=like' || $op eq 'like' ) {
        my $re = join '.*', map { quotemeta } split /%/, ( $op eq 'like' ? "%$want%" : $want ), -1;
        return $s =~ /^$re\z/;
    }
    return index( lc $s, lc $want ) >= 0 if $op eq 'ilike';
    return ( $v // 0 ) > $want if $op eq '>';
    return ( $v // 0 ) < $want if $op eq '<';
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
    my $uid = $self->{fake}->_authenticate( $login, $password );
    Odoo::Error->throw( kind => 'fault', message => 'authentication failed', fault_class => 'odoo.exceptions.AccessDenied' ) if !$uid;
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
    return $self->{identity}{uid} if $service eq 'common' && $method eq 'authenticate';
    Odoo::Error->throw( kind => 'fault', message => 'no session', fault_class => 'odoo.http.SessionExpiredException' ) if !defined $self->{sid};
    $self->{fake}{session_user} = $self->{identity}{login};
    return $self->{fake}->call( $service, $method, @params );
}

1;

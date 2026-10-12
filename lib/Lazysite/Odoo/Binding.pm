package Lazysite::Odoo::Binding;

# SM747 CU: A BINDING - WHICH NAMED OPERATION A PAGE, A FORM OR THE SCHEDULE MAY
# RUN, WHAT IT MAY BE GIVEN, AND BY WHOM.
#
# A binding is a handler of type `odoo` (Lazysite::Handlers), so it is made,
# listed, gated and deleted where every other destination is. This module turns
# the stored record into the shape the engine runs, and decides the one thing
# that makes an anonymous write path safe to have: WHAT A REQUEST MAY SET.
#
# THE PARAMETERS COME FROM THREE PLACES, AND ONLY ONE OF THEM IS THE REQUEST:
#
#   params         `field=parameter` - the request's field, renamed. Only these
#                  may come from outside, and only into a parameter the
#                  operation declares as a plain value (str, int, bool). A json,
#                  list or path parameter is a domain, a set or a file on this
#                  server: it can be FIXED by the operator and never fed by a
#                  visitor. That is the parameter-injection line.
#   fixed          `parameter=value` - the operator's, and the request cannot
#                  override one.
#   visitor_param  the parameter that receives the visitor's key - minted by
#                  the server (Lazysite::Odoo::Visitor), never read from input.
#                  This is what keeps a visitor to their own basket.
#
# A name in two of the three is refused at save: the order of precedence would
# otherwise be a security property nobody wrote down.
use strict;
use warnings;

our @MODES = qw(scheduled authenticated public);

my $FIELD = qr/\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z/;
my $PARAM = qr/\A[a-z][a-z0-9_]{0,63}\z/;
my $GROUP = qr/\A[a-z0-9][a-z0-9_-]{0,63}\z/;
my $OP    = qr/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/;

# The types a request may feed. Everything else is the operator's to fix.
our %FROM_INPUT = map { $_ => 1 } qw(str int bool);

# How long a plain value from a request may be. A basket line is a few
# characters; this bounds what a script can push through one parameter.
our $MAX_VALUE = 1000;

sub _pairs {
    my ( $text, $what, $left, $right ) = @_;
    my %m;
    for my $pair ( split /\s*,\s*/, ( $text // '' ) ) {
        next unless length $pair;
        my ( $k, $v ) = split /\s*=\s*/, $pair, 2;
        return ( undef, "$what: '$pair' is not name=value" )
            unless defined $v && length $k && length $v;
        return ( undef, "$what: '$k' is not $left" ) unless $k =~ $right->[0];
        return ( undef, "$what: '$v' is not $right->[2]" )
            unless !defined $right->[1] || $v =~ $right->[1];
        return ( undef, "$what: '$k' is named twice" ) if exists $m{$k};
        $m{$k} = $v;
    }
    return ( \%m, '' );
}

# parse( \%handler ) -> ( \%binding, '' ) or ( undef, why, field )
#
# The SHAPE only - no OOM needed. Whether the operation exists and declares the
# parameters is check_against(), which needs the registry.
sub parse {
    my ($h) = @_;
    return ( undef, 'a binding is required', 'id' ) unless ref $h eq 'HASH';
    my %b = ( id => $h->{id} // '' );

    my $op = $h->{operation} // '';
    return ( undef, 'operation is required - the name of an OOM operation, such as pack.action',
        'operation' )
        unless length $op;
    return ( undef, "operation '$op' is not an operation name (dotted, lower case)", 'operation' )
        unless $op =~ $OP;
    $b{operation} = $op;

    my ( $in, $why ) = _pairs( $h->{params}, 'params', 'a field name', [ $FIELD, $PARAM, 'a parameter name' ] );
    return ( undef, $why, 'params' ) unless $in;
    $b{params} = $in;    # field => parameter

    my ( $fixed, $fwhy ) = _pairs( $h->{fixed}, 'fixed', 'a parameter name', [ $PARAM, undef ] );
    return ( undef, $fwhy, 'fixed' ) unless $fixed;
    $b{fixed} = $fixed;    # parameter => value

    my $vp = $h->{visitor_param} // '';
    return ( undef, "visitor_param '$vp' is not a parameter name", 'visitor_param' )
        if length $vp && $vp !~ $PARAM;
    $b{visitor_param} = $vp;

    # ONE SOURCE PER PARAMETER.
    my %src;
    push @{ $src{$_} },  'params' for values %$in;
    push @{ $src{$_} },  'fixed'  for keys %$fixed;
    push @{ $src{$vp} }, 'visitor_param' if length $vp;
    for my $p ( sort keys %src ) {
        return ( undef, "parameter '$p' is set by " . join( ' and ', @{ $src{$p} } )
                . ' - each parameter has one source', 'params' )
            if @{ $src{$p} } > 1;
    }

    my %modes = map { $_ => 0 } @MODES;
    for my $m ( grep { length } split /\s*,\s*/, ( $h->{modes} // 'authenticated' ) ) {
        return ( undef, "modes: '$m' is not one of " . join( ', ', @MODES ), 'modes' )
            unless exists $modes{$m};
        $modes{$m} = 1;
    }
    return ( undef, 'modes must name at least one of ' . join( ', ', @MODES ), 'modes' )
        unless grep { $_ } values %modes;
    $b{modes} = \%modes;

    my @callers = grep { length } split /\s*,\s*/, ( $h->{callers} // '' );
    for (@callers) { return ( undef, "callers: '$_' is not a group name", 'callers' ) unless $_ =~ $GROUP }
    $b{callers} = \@callers;

    my $apply = $h->{apply} // 'confirm';
    $apply = 'confirm' unless length $apply;
    return ( undef, "apply must be confirm or immediate (got '$apply')", 'apply' )
        unless $apply =~ /\A(?:confirm|immediate)\z/;
    $b{apply} = $apply;

    for my $k (qw(rate_per_visitor_hour rate_per_hour)) {
        my $v = $h->{$k};
        $v = $k eq 'rate_per_hour' ? 200 : 20 unless defined $v && length $v;
        return ( undef, "$k must be a whole number", $k ) unless $v =~ /\A[0-9]+\z/;
        $b{$k} = 0 + $v;
    }

    # A visitor key exists only where a visitor does: a scheduled run has none.
    return ( undef, 'a binding with a visitor_param cannot be scheduled - there is no '
            . 'visitor on the timer', 'modes' )
        if length $vp && $modes{scheduled};
    return ( \%b, '' );
}

# check_against( \%binding, $op_class ) -> '' or why
#
# The binding against the operation's OWN declaration, when the registry can be
# read: every parameter it names is one the operation declares, a parameter fed
# from the request is a plain value, nothing names a path, and every required
# parameter has a source. Run at save, so a binding that cannot work is refused
# when it is made rather than at a visitor's request (SM807).
sub check_against {
    my ( $b, $class ) = @_;
    my $spec = $class->params || {};
    for my $p ( sort( values %{ $b->{params} } ), sort( keys %{ $b->{fixed} } ),
        ( length $b->{visitor_param} ? $b->{visitor_param} : () ) )
    {
        return "parameter '$p' is not one $b->{operation} declares (it takes: "
            . ( join( ', ', sort keys %$spec ) || 'none' ) . ')'
            unless $spec->{$p};
        return "parameter '$p' names a file on this server; a binding cannot set one"
            if ( $spec->{$p}{type} // 'str' ) eq 'path';
    }
    for my $p ( sort values %{ $b->{params} } ) {
        my $t = $spec->{$p}{type} // 'str';
        return "parameter '$p' is $t - a request may feed only a plain value (str, int, bool); "
            . 'fix it with fixed: instead'
            unless $FROM_INPUT{$t};
    }
    my %covered = map { $_ => 1 } values %{ $b->{params} }, keys %{ $b->{fixed} },
        ( length $b->{visitor_param} ? $b->{visitor_param} : () );
    for my $p ( sort keys %$spec ) {
        return "$b->{operation} requires '$p' and the binding gives it no source"
            if $spec->{$p}{required} && !defined $spec->{$p}{default} && !$covered{$p};
    }
    return "$b->{operation} writes, and a scheduled run has nobody to confirm its plan - set "
        . 'apply: immediate (Q1), or take scheduled off the modes'
        if $class->writes && $b->{modes}{scheduled} && $b->{apply} ne 'immediate';
    if ( length $b->{visitor_param} ) {
        my $t = $spec->{ $b->{visitor_param} }{type} // 'str';
        return "visitor_param '$b->{visitor_param}' is $t - the visitor key is text (str)"
            unless $t eq 'str';
    }
    return '';
}

# assemble( \%binding, $op_class, \%input, %o ) -> ( \%params, '' ) or ( undef, why )
#
#   visitor  the visitor key, for the visitor parameter
#   strict   refuse an input field the binding does not map (the endpoint);
#            without it unmapped fields are dropped (a form, which posts
#            every field it has)
#
# Every value from the request is checked against the operation's declared type
# HERE, before OOM is called, so a refusal names the field the visitor sent
# rather than an operation parameter they have never heard of.
sub assemble {
    my ( $b, $class, $input, %o ) = @_;
    $input = {} unless ref $input eq 'HASH';
    my $spec = $class->params || {};
    my %out;

    my @unmapped = sort grep { !/\A_/ && !exists $b->{params}{$_} } keys %$input;
    return ( undef, 'this binding does not take: ' . join( ', ', @unmapped )
            . ( %{ $b->{params} } ? '. It takes: ' . join( ', ', sort keys %{ $b->{params} } ) : '' ) )
        if $o{strict} && @unmapped;

    for my $field ( sort keys %{ $b->{params} } ) {
        next unless exists $input->{$field};
        my $v = $input->{$field};
        my $p = $b->{params}{$field};
        my $t = $spec->{$p}{type} // 'str';
        return ( undef, "'$field' must be a single value" ) if ref $v;
        next unless defined $v;
        return ( undef, "'$field' is longer than $MAX_VALUE characters" ) if length $v > $MAX_VALUE;
        return ( undef, "'$field' contains a control character" ) if $v =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
        return ( undef, "'$field' must be a whole number" ) if $t eq 'int' && $v !~ /\A-?[0-9]{1,15}\z/;
        return ( undef, "'$field' must be yes or no" )
            if $t eq 'bool' && $v !~ /\A(?:1|0|yes|no|true|false)\z/i;
        return ( undef, "'$field' cannot be given by a request" ) unless $FROM_INPUT{$t};
        $out{$p} = "$v";
    }
    $out{$_} = $b->{fixed}{$_} for keys %{ $b->{fixed} };
    if ( length $b->{visitor_param} ) {
        return ( undef, 'this binding works for a visitor, and the request carries no visitor '
                . 'key - fetch a token from the Odoo endpoint first' )
            unless defined $o{visitor} && length $o{visitor};
        $out{ $b->{visitor_param} } = $o{visitor};
    }
    for my $p ( sort keys %$spec ) {
        next if exists $out{$p} || defined $spec->{$p}{default};
        my ($field) = grep { $b->{params}{$_} eq $p } keys %{ $b->{params} };
        return ( undef, ( defined $field ? "'$field' is required" : "the operation's '$p' is required" ) )
            if $spec->{$p}{required};
    }
    return ( \%out, '' );
}

1;

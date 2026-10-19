package Odoo::Ops::Core::ReadContext;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::JSON ();

=head1 NAME

Odoo::Ops::Core::ReadContext - the context a read may send, from a short list

=head1 DESCRIPTION

C<core.read> and C<core.get> take C<context>, a JSON object of Odoo context keys, so a read can ask
Odoo for a figure that depends on one (the free quantity of a product in one warehouse, a price on one
pricelist). Only these keys are allowed; any other is refused C<usage>, naming it and the list:

    warehouse location lot_id pricelist partner_id   a whole number above 0 (an id)
    quantity                                        a number
    lang tz                                         text
    active_test                                     true or false
    to_date from_date                               YYYY-MM-DD or YYYY-MM-DD HH:MM:SS

The existing C<pricelist> parameter is the same as C<context.pricelist>; both given and different is
refused. C<archived> is C<active_test> false; C<archived> with C<active_test> true is refused.

=head2 allowed

The allowed keys, sorted.

=cut

my %KEY = (
    warehouse => 'id', location => 'id', lot_id => 'id', pricelist => 'id', partner_id => 'id',
    quantity => 'number', lang => 'str', tz => 'str', active_test => 'bool', to_date => 'date', from_date => 'date',
);

sub allowed ($class) { return sort keys %KEY }

=head2 check($op_name, $raw)

The context as a hash of typed values, or C<usage>. C<$raw> is a hash (a JSON object decoded) or undef.

=cut

sub check ($class, $name, $raw) {
    return {} if !defined $raw;
    my $bad = sub ($why) { Odoo::Error->throw( kind => 'usage', message => "$name: $why", fix => "oom-ops describe $name lists the parameters; context takes " . join( ', ', $class->allowed ) ) };
    ref $raw eq 'HASH' or $bad->('context must be a JSON object, such as {"warehouse": 2}');
    my %out;
    for my $k ( sort keys %$raw ) {
        my $type = $KEY{$k} or $bad->( "context key '$k' is not allowed (the keys are: " . join( ', ', $class->allowed ) . ')' );
        my $v = $raw->{$k};
        $bad->("context.$k must not be empty") if !defined $v || ( !ref $v && $v eq '' );
        if ( $type eq 'id' ) {
            !ref $v && $v =~ /\A[1-9]\d*\z/ or $bad->("context.$k must be a whole number above 0 (an id)");
            $out{$k} = 0 + $v;
        }
        elsif ( $type eq 'number' ) {
            !ref $v && $v =~ /\A-?\d+(?:\.\d+)?\z/ or $bad->("context.$k must be a number");
            $out{$k} = 0 + $v;
        }
        elsif ( $type eq 'str' ) {
            !ref $v && $v =~ /\A[\w.\/@+-]{1,64}\z/ or $bad->("context.$k must be text of letters, digits and . _ - / @ +, up to 64 characters");
            $out{$k} = "$v";
        }
        elsif ( $type eq 'bool' ) {
            if    ( ref $v && Odoo::JSON::is_bool($v) ) { $out{$k} = $v ? JSON::PP::true : JSON::PP::false }
            elsif ( !ref $v && $v =~ /\A(?:1|true|yes)\z/i ) { $out{$k} = JSON::PP::true }
            elsif ( !ref $v && $v =~ /\A(?:0|false|no)\z/i ) { $out{$k} = JSON::PP::false }
            else { $bad->("context.$k must be true or false") }
        }
        else {
            !ref $v && $v =~ /\A\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?\z/ or $bad->("context.$k must be a date, YYYY-MM-DD or YYYY-MM-DD HH:MM:SS");
            $out{$k} = "$v";
        }
    }
    return \%out;
}

=head2 resolve($op_name, context =E<gt> $raw, pricelist =E<gt> $id, archived =E<gt> 0|1)

C<< ( \%send, $pricelist, \%keyed ) >>: the context to send with the read, the pricelist it is priced
with (the parameter or C<context.pricelist>), and the part of the context the data cache keys on
besides the pricelist and C<archived> (which it keys on already).

=cut

sub resolve ($class, $name, %a) {
    my $c  = $class->check( $name, $a{context} );
    my $pl = $a{pricelist};
    Odoo::Error->throw( kind => 'usage', message => "$name: pricelist $pl and context.pricelist $c->{pricelist} are different",
        fix => 'the pricelist parameter is the same as context.pricelist: give one' )
        if defined $pl && defined $c->{pricelist} && $pl != $c->{pricelist};
    $pl //= $c->{pricelist};
    my %keyed = %$c;
    delete $keyed{pricelist};
    my %send = %$c;
    $send{pricelist} = $pl if defined $pl;
    if ( $a{archived} ) {
        Odoo::Error->throw( kind => 'usage', message => "$name: archived includes inactive records and context.active_test is true",
            fix => 'give one of them' ) if exists $c->{active_test} && $c->{active_test};
        $send{active_test} = JSON::PP::false;
        delete $keyed{active_test};
    }
    return ( \%send, $pl, \%keyed );
}

1;

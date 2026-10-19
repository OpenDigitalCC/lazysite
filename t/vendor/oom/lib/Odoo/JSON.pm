package Odoo::JSON;

use v5.36;
use strict;
use warnings;
no warnings 'experimental::builtin';

use Scalar::Util qw(blessed);
use JSON::PP ();

our $VERSION = '0.34';

=head1 NAME

Odoo::JSON - the one place OOM picks its JSON encoder

=head1 SYNOPSIS

    my $j   = Odoo::JSON->new( canonical => 1 );     # utf8, allow_nonref
    my $out = $j->encode($data);
    my $in  = $j->decode($bytes);

    Odoo::JSON->backend;                              # 'Cpanel::JSON::XS'
    Odoo::JSON::is_bool($v);                          # an encoder-neutral boolean test

=head1 DESCRIPTION

OOM decodes every answer Odoo gives and every plan, journal and cache file it
reads. L<JSON::PP> is pure Perl and slow; L<Cpanel::JSON::XS> (Debian
C<libcpanel-json-xs-perl>, a Recommends of C<libodoo-oom-perl>) decodes the
same answers a hundred times faster. This module returns an encoder object of
the first of these that loads:

    Cpanel::JSON::XS, JSON::PP

OOM works with C<JSON::PP> alone. The environment variable C<ODOO_OOM_JSON>
(C<pp> or C<cpanel>) names the encoder to use instead; a name whose module is
not installed is ignored and the order above applies.

L<JSON::XS> is never chosen. Its 4.04 predates the Perl 5.36 number flags: a
number that has been printed once (an id put in a message, a hash key) is
written as a string (C<"2"> for C<2>), where C<JSON::PP> and
C<Cpanel::JSON::XS> keep it a number, so the same plan would send Odoo other
JSON and a test of the suite, run on it, differs in a dozen places.

Every object is UTF-8 (bytes in and out) and C<allow_nonref>, and canonical
(keys sorted) unless C<< canonical => 0 >> is given, so the bytes a plan is
sealed over are the same under each encoder. A decoded JSON C<true> or C<false>
is a L<JSON::PP::Boolean> object under every encoder, and an encoder writes
C<JSON::PP::true>, C<JSON::PP::false>, a C<\1> or C<\0> and a Perl core boolean
as C<true> and C<false>. C<is_bool> tests the objects.

=head1 FUNCTIONS

=head2 backend

The module the encoders come from: C<Cpanel::JSON::XS> or C<JSON::PP>. C<doctor> reports it.

=cut

my $BACKEND;

sub _load ($want) {
    my %mod = ( cpanel => 'Cpanel::JSON::XS', pp => 'JSON::PP' );
    my @order = ( 'Cpanel::JSON::XS', 'JSON::PP' );
    unshift @order, $mod{ lc $want } if defined $want && $mod{ lc $want };
    for my $m (@order) {
        return $m if $m eq 'JSON::PP' || eval "require $m; 1";    ## no critic (ProhibitStringyEval)
    }
    return 'JSON::PP';
}

sub require_module ($m) { eval "require $m; 1" or die $@ }    ## no critic (ProhibitStringyEval)

sub backend ($class = undef) { $BACKEND //= _load( $ENV{ODOO_OOM_JSON} ) }

=head2 new(%options)

A new encoder object. Options: C<canonical> (default 1), C<utf8> (default 1; 0 for a text in characters), C<pretty>,
C<indent_length> (with C<pretty>; an encoder that cannot indent by a given
width is replaced by C<JSON::PP> for that object, so the text is the same),
C<plain_bools> (decode a JSON boolean to a plain 1 or 0, as the transports
read Odoo's answers), C<backend> (a module name, for tests).

=cut

sub new ($class, %o) {
    my $be = $o{backend} // backend();
    require_module($be) if $o{backend};
    $be = 'JSON::PP' if $o{indent_length} && !$be->can('indent_length');
    my $j = $be->new->allow_nonref;
    $j->utf8( $o{utf8} // 1 ? 1 : 0 );
    $j->canonical( $o{canonical} // 1 ? 1 : 0 );
    $j->pretty if $o{pretty};
    $j->indent_length( $o{indent_length} ) if $o{indent_length};
    if ( $o{plain_bools} ) {
        # JSON::PP takes the two values; Cpanel::JSON::XS has no such option (its unblessed_bool
        # hands out Perl core booleans, which an encoder writes back as true and false where JSON::PP wrote 1
        # and 0), so its answer is walked once for them
        if ( $j->can('boolean_values') ) { $j->boolean_values( 0, 1 ) }
        else                             { $j->unblessed_bool(1) if $j->can('unblessed_bool'); return bless { json => $j }, 'Odoo::JSON::Plain' }
    }
    return $j;
}

=head2 json

One shared canonical encoder, for fingerprints. This is what C<Odoo::Ops::json()> returns.

=cut

my $SHARED;
sub json ($class = undef) { $SHARED //= __PACKAGE__->new }

=head2 sealer

The encoder every digest is taken over: C<JSON::PP>, canonical, UTF-8, always,
whichever encoder reads and writes the files. The encoders agree on strings,
integers and booleans but not on every float: C<Cpanel::JSON::XS> writes the
value read from C<5.0> as C<5.0> and C<JSON::PP> writes C<5>, and negative
zero is C<-0>, C<-0.0> or C<0>. A plan sealed under one encoder must verify
under another, and a plan sealed by an earlier OOM must verify now, so the
seal (C<Odoo::Ops::seal_json>, the plan's fingerprint, the run keys) is
always the text C<JSON::PP> writes. Only digests go through it; reading and
writing use the fast encoder.

=cut

my $SEALER;
sub sealer ($class = undef) { $SEALER //= __PACKAGE__->new( backend => 'JSON::PP' ) }

=head2 encode($data), decode($bytes)

UTF-8 JSON text of C<$data> and its inverse, on the shared encoder.

=cut

sub encode ($data) { json()->encode($data) }
sub decode ($bytes) { json()->decode($bytes) }

=head2 true, false

The boolean objects every encoder writes as C<true> and C<false> (the
C<JSON::PP> ones, which the other encoders know).

=head2 is_bool($v)

True for a JSON boolean of any of the encoders (C<JSON::PP::Boolean>,
C<Types::Serialiser::Boolean>, C<Cpanel::JSON::XS::Boolean>). A plain 0 or 1
and a Perl core boolean (C<builtin::is_bool>) are not.

=cut

sub true ()  { JSON::PP::true() }
sub false () { JSON::PP::false() }

sub is_bool ($v) {
    return 0 if !blessed $v;
    return ( $v->isa('JSON::PP::Boolean') || $v->isa('Types::Serialiser::Boolean') || $v->isa('Cpanel::JSON::XS::Boolean') ) ? 1 : 0;
}


# The encoder of the transports when the real one cannot decode a boolean to a plain 1 or 0.
package Odoo::JSON::Plain;

sub encode ($self, $data) { $self->{json}->encode($data) }

sub decode ($self, $text) {
    my $d = $self->{json}->decode($text);
    return builtin::is_bool($d) ? ( $d ? 1 : 0 ) : $d if !ref $d;
    my @todo = ($d);
    while ( defined( my $n = pop @todo ) ) {
        my $r = ref $n;
        if ( $r eq 'HASH' ) {
            for my $v ( values %$n ) {
                if    ( ref $v )                { push @todo, $v }
                elsif ( builtin::is_bool($v) ) { $v = $v ? 1 : 0 }
            }
        }
        elsif ( $r eq 'ARRAY' ) {
            for my $v (@$n) {
                if    ( ref $v )                { push @todo, $v }
                elsif ( builtin::is_bool($v) ) { $v = $v ? 1 : 0 }
            }
        }
    }
    return $d;
}

1;

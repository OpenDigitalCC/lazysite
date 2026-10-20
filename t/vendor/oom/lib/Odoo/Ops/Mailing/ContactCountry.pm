package Odoo::Ops::Mailing::ContactCountry;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::ContactCountry - set the country of mailing contacts in bulk

=head1 SYNOPSIS

    oom-ops run mailing.contact_country --conf ops.conf --set rows=countries.csv
    oom-ops run mailing.contact_country --conf ops.conf --set rows=countries.csv --check

=head1 DESCRIPTION

C<mailing.contact_country> takes rows with C<email> and C<country> (an ISO
3166 alpha-2 code) from C<rows> (a C<.csv> with that header, a C<.json> or
a C<.jsonl> file), C<records> (a list) or C<mapping> (a Source mapping
whose target is C<contact>), and writes the country on the
C<mailing.contact> records that have the address. A country filter on a
mailing (C<mailing.create> C<country_in> / C<country_not_in>) reads the
contact's own country, so a contact has to carry one before a filter can
see it.

The contacts with an address are every C<mailing.contact> whatever its
lists, found by the address as Odoo normalises it (trimmed, lower-cased,
C<email_normalized>), never by name. Every row lands in one bucket:

    set               the contact's country changes (or is set for the first time)
    same              the contact already has that country
    no-contact        no mailing contact has the address
    unknown-country   held: res.country has no such code (named)
    ambiguous         held: the address is on more than one contact and they
                      do not have the same country now (named); say which by
                      correcting one in Odoo, or give the country of the one
                      you mean once the contacts agree
    invalid-email     held: the text is not an address
    invalid-row       held: the row has no country, or the source could not map it
    duplicate-in-input  held: an earlier row carries the same address
    held-*            held by the source or the caller

An address on several contacts that all have the same country now (or
none) is one row: the first contact is the row's change and the others
are changes of the same row, outside the bucket count. Writes carry the
quiet context (no chatter, no tracking) and the before-image of
C<country_id>, so a revert puts back the country each contact had,
or none. A second run of the same file plans C<same> throughout.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.contact_country' }
sub summary ($class) { 'Plan setting the country of mailing contacts in bulk, from a file of email and country code' }
sub pack    ($class) { 'mailing' }
sub buckets ($class) {
    return [
        { name => 'set', meaning => 'the contact\'s country is written' },
        { name => 'same', meaning => 'nothing to do: the contact already has that country' },
        { name => 'no-contact', meaning => 'nothing to do: no mailing contact has the address' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-country', meaning => 'res.country has no such code' },
        { name => 'ambiguous', meaning => 'the address is on more than one contact and they do not have the same country now' },
        { name => 'invalid-email', meaning => 'the text is not an address' },
        { name => 'invalid-row', meaning => 'the row has no country, or the source could not map it' },
        { name => 'duplicate-in-input', meaning => 'an earlier row carries the same address' },
        { name => 'held-<kind>', meaning => 'the source or the caller held the row, with the reason' },
    ];
}

sub params ($class) {
    return +{ Odoo::Ops::Mailing::Common::rows_params() };
}
sub read_scope ($class) {
    {   contact => ['search_read'],
        country => ['search_read'],
    };
}
sub write_scope ($class) { { contact => [qw(write read)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my $QUIET = sub () { { tracking_disable => JSON::PP::true, mail_create_nolog => JSON::PP::true, mail_notrack => JSON::PP::true, mail_create_nosubscribe => JSON::PP::true } };

sub plan ($self) {
    my $p    = Odoo::Ops::Mailing::Common::ready($self);
    my $f    = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $rows = Odoo::Ops::Mailing::Common::rows($self);
    my $country = $f->( contact => 'country' );
    my $norm    = $f->( contact => 'email_normalized' );

    my ( %addr, %code );
    for my $r (@$rows) {
        next if ref $r->{values} ne 'HASH';
        my $e = Odoo::Ops::Mailing::Common::email( $r->{values}{email} );
        $addr{$e} = 1 if defined $e;
        my $c = Odoo::Ops::Mailing::Common::text( $r->{values}{country} ) =~ s/^\s+|\s+\z//gr;
        $code{ uc $c } = 1 if length $c;
    }
    my %contacts;
    if (%addr) {
        my $cs = $self->model('contact')->all( [ [ $norm, 'in', [ sort keys %addr ] ] ], [ $norm, $country ] );
        push @{ $contacts{ $_->{$norm} } }, $_ for sort { $a->{id} <=> $b->{id} } @$cs;
    }
    my ( %by_code, %name_of );
    if (%code) {
        my ( $cc, $cn ) = map { $f->( country => $_ ) } qw(code name);
        for my $c ( @{ $self->model('country')->search_read( [ [ $cc, 'in', [ sort keys %code ] ] ], [ $cc, $cn ] ) } ) {
            $by_code{ uc $c->{$cc} } = $c->{id};
            $name_of{ $c->{id} } = $c->{$cn};
        }
    }

    # the names of the countries the contacts have now, for a reason that names them
    my @now_ids = grep { !$name_of{$_} } keys %{ { map { $_ => 1 } grep { $_ } map { Odoo::Ops::Mailing::Common::id_of( $_->{$country} ) } map { @$_ } values %contacts } };
    if (@now_ids) {
        my $cn = $f->( country => 'name' );
        $name_of{ $_->{id} } = $_->{$cn} for @{ $self->model('country')->search_read( [ [ 'id', 'in', [ sort { $a <=> $b } @now_ids ] ] ], [$cn] ) };
    }

    my $plan = $self->new_plan( input_count => scalar @$rows );
    my %seen;
    my $n = 0;
    for my $row (@$rows) {
        $n++;
        my $key  = "row:$row->{key}";
        my $hold = sub ( $bucket, $reason ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $reason ); 1 };
        my $skip = sub ( $bucket, $reason ) { $plan->add( bucket => $bucket, action => 'skip', key => $key, reason => $reason ); 1 };
        next if defined $row->{error} && $hold->( 'invalid-row', $row->{error} );
        if ( my $h = $row->{held} ) {
            my ($kind) = $h =~ /^(\w+):/;
            $hold->( 'held-' . ( $kind // 'flag' ), $h );
            next;
        }
        my $v = $row->{values};
        next if ref $v ne 'HASH' && $hold->( 'invalid-row', 'the row has no values' );
        my $e = Odoo::Ops::Mailing::Common::email( $v->{email} );
        next if !defined $e && $hold->( 'invalid-email', "'" . Odoo::Ops::Mailing::Common::text( $v->{email} ) . "' is not an email address" );
        next if $seen{$e} && $hold->( 'duplicate-in-input', "same address as row #$seen{$e}" );
        $seen{$e} = $n;
        my $code = uc( Odoo::Ops::Mailing::Common::text( $v->{country} ) =~ s/^\s+|\s+\z//gr );
        next if !length $code && $hold->( 'invalid-row', "$e has no country in the row" );
        my $cid = $by_code{$code};
        next if !$cid && $hold->( 'unknown-country', "'$code' is not a country code res.country holds (ISO 3166 alpha-2, as for $e)" );
        my @cs = @{ $contacts{$e} // [] };
        next if !@cs && $skip->( 'no-contact', "no mailing contact has the address $e" );

        my %now = map { $_->{id} => Odoo::Ops::Mailing::Common::id_of( $_->{$country} ) // 0 } @cs;
        my %kinds = map { $_ => 1 } values %now;
        if ( keys %kinds > 1 ) {
            $hold->( 'ambiguous', "$e is on contacts " . join( ', ', map { "$_->{id} (" . ( $now{ $_->{id} } ? $name_of{ $now{ $_->{id} } } // "country $now{$_->{id}}" : 'no country' ) . ')' } @cs )
                . ", which do not have the same country now; correct one in Odoo, then run this again" );
            next;
        }
        my @todo = grep { $now{ $_->{id} } != $cid } @cs;
        if ( !@todo ) {
            $skip->( 'same', 'contact' . ( @cs > 1 ? 's ' . join( ', ', map { $_->{id} } @cs ) . ' already have' : " $cs[0]{id} already has" ) . " $name_of{$cid} ($code)" );
            next;
        }
        my $first = 1;
        for my $c (@todo) {
            $plan->add(
                bucket => 'set', action => 'write', model => $p->model_name('contact'), id => $c->{id},
                key => $first ? $key : "$key:contact$c->{id}", ( $first ? () : ( support => 1 ) ),
                vals => { $country => $cid }, before => { $country => $now{ $c->{id} } || undef }, context => $QUIET->(),
                reason => "contact $c->{id} ($e): country " . ( $now{ $c->{id} } ? $name_of{ $now{ $c->{id} } } // $now{ $c->{id} } : 'none' ) . " -> $name_of{$cid} ($code)",
            );
            $first = 0;
        }
    }
    $plan->note( scalar(@$rows) . ' rows; the contacts are found by the address as Odoo normalises it, whatever their lists; a contact\'s linked partner is not consulted or written' );
    return $plan;
}

1;

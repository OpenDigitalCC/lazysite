package Odoo::Ops::Mailing::Partition;

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

Odoo::Ops::Mailing::Partition - do the parts of one mailing cover every contact of its lists once

=head1 SYNOPSIS

    oom-ops run mailing.partition --conf ops.conf --set lists=Distributors,Customers \
        --set parts_file=parts.json
    oom-ops run mailing.partition --conf ops.conf --set lists=7,8 --set check=1 \
        --set 'parts=[{"name":"apac","country_in":["AU","JP"]},{"name":"rest","country_not_in":["AU","JP"]}]'

=head1 DESCRIPTION

A message sent in several parts, each a mailing to the same lists with
its own country filter (C<mailing.create> C<country_in> or
C<country_not_in>), reaches everyone once only when the filters leave no
contact out and none in two. C<mailing.partition> reads that before the
parts are scheduled. It writes nothing.

C<lists> (names or ids, comma-separated) and the parts, either C<parts> (a
JSON list) or C<parts_file> (a JSON file holding it). A part is C<name>
and C<country_in> or C<country_not_in>, a list of ISO country codes (or
text, comma-separated); an unknown code is refused C<usage>, naming it.

The report is C<< { lists, parts, whole, ok } >>. Each part has
C<contacts> (the number of C<mailing.contact> records Odoo's own domain for
the lists and that filter gives, which is what the part's mailing reads as
its C<total>), C<blacklisted> and C<recipients> (the contacts that are not
blacklisted). C<whole> has C<contacts> of the lists, C<blacklisted>,
C<recipients> (after the blacklist), C<without_address> (contacts with no
address, which no mailing reaches, left out of the checks below),
C<in_no_part> and C<in_several_parts>, each C<< { count, emails } >> with
up to 20 addresses, and C<addresses_in_several_parts>: addresses held by
contacts that fall in different parts, who would get one mail from each
part. C<ok> is true when all three counts are zero.

C<check=1> refuses with C<not-a-partition> (exit 1) when C<ok> is false,
the message carrying the counts and the first addresses. A contact is
checked by its own country; its linked partner is not consulted.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.partition' }
sub summary ($class) { 'Check that the country-filtered parts of one mailing cover every contact of its lists exactly once' }
sub pack    ($class) { 'mailing' }
sub fields ($class) {
    return [
        { name => 'lists', meaning => 'The lists the parts go to' },
        { name => 'parts', meaning => 'Each part: its filter, the contacts Odoo\'s domain gives, those blacklisted, the recipients' },
        { name => 'whole', meaning => 'The lists\' contacts, those in no part, those in more than one, and the addresses spread over parts' },
        { name => 'ok', meaning => 'True when no contact is in no part or in two, and no address is in two parts' },
    ];
}

sub params ($class) {
    {   lists      => { type => 'list', required => 1, help => 'the lists, names or ids, comma-separated' },
        parts      => { type => 'json', help => 'the parts: [{"name":"apac","country_in":["AU","JP"]},{"name":"rest","country_not_in":["AU","JP"]}]' },
        parts_file => { type => 'path', help => 'a JSON file holding the parts list, instead of parts' },
        check      => { type => 'bool', default => 0, help => 'refuse (exit 1) when a contact is in no part or in two' },
    };
}
sub read_scope ($class) {
    {   list    => ['search_read'],
        contact => [qw(search_read)],
        country => ['search_read'],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };

    # the lists
    my ( @lists, @unknown );
    for my $ref ( @{ $self->param('lists') // [] } ) {
        my $found = Odoo::Ops::Mailing::Common::lists_by( $self, $ref );
        if    ( !@$found )    { push @unknown, $ref }
        elsif ( @$found > 1 ) { push @unknown, "$ref (names " . scalar(@$found) . ' lists; give the id)' }
        else                  { push @lists, { id => $found->[0]{id}, name => $found->[0]{ $f->( list => 'name' ) } } }
    }
    Odoo::Error->throw( kind => 'refused', code => 'unknown-list', message => 'mailing.partition: no list ' . join( ', ', map { "'$_'" } @unknown ),
        fix => 'oom-ops run mailing.lists --conf <conf> lists the mailing lists' ) if @unknown;
    Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: give at least one list (lists)' ) if !@lists;
    my @ids = sort { $a <=> $b } map { $_->{id} } @lists;

    # the parts
    my $given = $self->_parts_input;
    my ( @parts, %name );
    for my $i ( 0 .. $#$given ) {
        my $g = $given->[$i];
        Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: part #' . ( $i + 1 ) . ' is not a map with a name and country_in or country_not_in' ) if ref $g ne 'HASH';
        my $nm = Odoo::Ops::Mailing::Common::text( $g->{name} );
        Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: part #' . ( $i + 1 ) . ' has no name' ) if !length $nm;
        Odoo::Error->throw( kind => 'usage', message => "mailing.partition: two parts are named '$nm'" ) if $name{$nm}++;
        my ( $in, $not ) = @$g{qw(country_in country_not_in)};
        Odoo::Error->throw( kind => 'usage', message => "mailing.partition: part '$nm' needs country_in or country_not_in, not both and not neither",
            fix => 'country_in lists the countries of the part; country_not_in is every other country and no country' ) if ( defined $in ? 1 : 0 ) == ( defined $not ? 1 : 0 );
        my $mode  = defined $in ? 'in' : 'not_in';
        my @codes = ref( $in // $not ) eq 'ARRAY' ? @{ $in // $not } : split /\s*,\s*/, $in // $not;
        my $countries = Odoo::Ops::Mailing::Common::countries( $self, \@codes );
        push @parts, { name => $nm, mode => $mode, countries => $countries,
            domain => Odoo::Ops::Mailing::Common::country_domain( $self, \@ids, $mode, [ map { $_->{id} } @$countries ] ) };
    }
    Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: give the parts (parts or parts_file)' ) if !@parts;

    # every contact of the lists once, then Odoo's own domain for each part
    my ( $ne, $bl, $em ) = map { $f->( contact => $_ ) } qw(email_normalized blacklisted email);
    my $all = $self->model('contact')->all( [ [ $f->( contact => 'lists' ), 'in', \@ids ] ], [ $ne, $bl, $em ] );
    my %c = map { $_->{id} => $_ } @$all;
    my %member;    # contact id -> [part indexes]
    for my $k ( 0 .. $#parts ) {
        my $dom = Odoo::Ops::Mailing::Common::parse_domain( $parts[$k]{domain} );
        $parts[$k]{ids} = [ map { $_->{id} } @{ $self->model('contact')->all( $dom, ['id'] ) } ];
        push @{ $member{$_} }, $k for @{ $parts[$k]{ids} };
    }

    my ( @none, @several, %addr_parts, $without );
    for my $id ( sort { $a <=> $b } keys %c ) {
        my $r = $c{$id};
        next if $r->{$bl};
        my $e = Odoo::Ops::Mailing::Common::text( $r->{$ne} );
        if ( !length $e ) { $without++; next }
        my $n = @{ $member{$id} // [] };
        push @none, $e if !$n;
        push @several, $e if $n > 1;
        $addr_parts{$e}{$_} = 1 for @{ $member{$id} // [] };
    }
    my @spread = sort grep { keys %{ $addr_parts{$_} } > 1 } keys %addr_parts;
    my $list = sub (@e) { +{ count => scalar @e, emails => [ @e[ 0 .. ( $#e > 19 ? 19 : $#e ) ] ] } };
    my $whole = {
        contacts        => scalar keys %c,
        blacklisted     => scalar( grep { $_->{$bl} } values %c ),
        recipients      => scalar( grep { !$_->{$bl} } values %c ),
        without_address => $without // 0,
        in_no_part      => $list->( sort @none ),
        in_several_parts => $list->( sort @several ),
        addresses_in_several_parts => $list->(@spread),
    };
    my $ok = !$whole->{in_no_part}{count} && !$whole->{in_several_parts}{count} && !$whole->{addresses_in_several_parts}{count} ? 1 : 0;
    my @out = map {
        my $part = $_;
        my $black = scalar grep { $c{$_} && $c{$_}{$bl} } @{ $part->{ids} };
        +{ name => $part->{name}, ( $part->{mode} eq 'in' ? 'country_in' : 'country_not_in' ) => [ map { $_->{code} } @{ $part->{countries} } ],
           filter => Odoo::Ops::Mailing::Common::country_words( $part->{mode}, $part->{countries} ), domain => $part->{domain},
           contacts => scalar @{ $part->{ids} }, blacklisted => $black, recipients => @{ $part->{ids} } - $black };
    } @parts;

    if ( $self->param('check') && !$ok ) {
        my $words = sub ( $what, $h ) { $h->{count} ? "$h->{count} $what (" . join( ', ', @{ $h->{emails} } ) . ( $h->{count} > @{ $h->{emails} } ? ', ...' : '' ) . ')' : () };
        Odoo::Error->throw( kind => 'refused', code => 'not-a-partition',
            message => 'mailing.partition: the parts are not a partition of the lists: '
                . join( '; ', $words->( 'contact(s) in no part', $whole->{in_no_part} ), $words->( 'contact(s) in more than one part', $whole->{in_several_parts} ),
                    $words->( 'address(es) in different parts', $whole->{addresses_in_several_parts} ) ),
            fix => 'change the parts\' countries so each contact lands in one, or set the contacts\' countries (oom-ops run mailing.contact_country); run again without check=1 for the counts' );
    }
    return {
        lists => \@lists, parts => \@out, whole => $whole, ok => $ok ? JSON::PP::true : JSON::PP::false,
        fields => {
            lists => { portable_type => 'list', string => 'The lists the parts go to' },
            parts => { portable_type => 'list', string => 'Each part: name, filter in words, domain, contacts (Odoo\'s count for the domain, what the mailing\'s total reads), blacklisted, recipients' },
            whole => { portable_type => 'object', string => 'contacts of the lists, blacklisted, recipients, without_address, and in_no_part, in_several_parts, addresses_in_several_parts as { count, emails (up to 20) }' },
            ok    => { portable_type => 'boolean', string => 'No contact in no part or in two, no address in two parts' },
        },
    };
}

sub _parts_input ($self) {
    my ( $inline, $file ) = map { $self->param($_) } qw(parts parts_file);
    Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: give parts or parts_file, not both' ) if defined $inline && defined $file;
    if ( defined $file ) {
        open my $fh, '<:raw', $file or Odoo::Error->throw( kind => 'usage', message => "mailing.partition: cannot read $file: $!", fix => 'check the path exists and this user can read it' );
        my $raw = do { local $/; <$fh> };
        close $fh;
        $inline = eval { Odoo::Ops::json()->decode($raw) };
        Odoo::Error->throw( kind => 'usage', message => "mailing.partition: $file is not JSON: a list of parts" ) if ref $inline ne 'ARRAY';
    }
    Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: give the parts (parts or parts_file)' ) if !defined $inline;
    Odoo::Error->throw( kind => 'usage', message => 'mailing.partition: parts must be a list of parts' ) if ref $inline ne 'ARRAY';
    return $inline;
}

1;

package Odoo::Ops::Match;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

=head1 NAME

Odoo::Ops::Match - exact-key matching of incoming rows to existing records

=head1 SYNOPSIS

    my $m = Odoo::Ops::Match->new(keys => ['email', 'phone'], phone_cc => '44');
    $m->add(17, { email => 'A@x.example ', phone => '07700 900123' });
    my $r = $m->find({ email => 'a@x.example' });
    # { status => 'one', ids => [17], via => ['email'] }

=head1 DESCRIPTION

Records are joined on normalised keys, compared for equality only -
never substrings, never "similar". An email is trimmed and lowercased.
A phone field may hold several numbers (split on C</ , ;> and the word
"or"); each becomes digits with a leading C<+>, a leading C<00> read as
C<+>, and - when C<phone_cc> is given - a leading single C<0> read as
C<+cc>. A phone key with fewer than 7 digits is ignored as too weak to
join on.

C<find> answers C<none>, C<one> (every key that matched agrees on one
record) or C<many> (keys point at different records, or one key at
several) - the last is for a person to decide.

=cut

my %NORM = (
    email => \&norm_email,
    phone => undef,    # needs phone_cc; bound in new
);

sub new ($class, %args) {
    my $keys = $args{keys} // ['email'];
    for my $k (@$keys) {
        Odoo::Error->throw( kind => 'usage', message => "unknown match key '$k' (email, phone)", fix => 'correct the parameter or the file the message names, then plan again' )
            if !exists $NORM{$k};
    }
    return bless { keys => $keys, cc => $args{phone_cc}, index => {} }, $class;
}

sub keys_used ($self) { @{ $self->{keys} } }

sub norm_email ($v) {
    return () if !defined $v;
    my $e = lc( $v =~ s/^\s+|\s+\z//gr );
    return $e =~ /^[^@\s]+@[^@\s]+\.[^@\s]+\z/ ? ($e) : ();
}

sub norm_phones ($self, $v) {
    return () if !defined $v;
    my @out;
    for my $part ( split m{\s*(?:[/,;]|\bor\b)\s*}i, $v ) {
        my $plus = $part =~ /^\s*\+/;
        my $d    = $part =~ s/\D//gr;
        next if !length $d;
        if    ($plus)                           { $d = "+$d" }
        elsif ( $d =~ s/^00// )                 { $d = "+$d" }
        elsif ( defined $self->{cc} && $d =~ s/^0(?=[1-9])// ) { $d = "+$self->{cc}$d" }
        next if ( $d =~ tr/0-9// ) < 7;
        push @out, $d;
    }
    return @out;
}

sub _norm ($self, $key, $v) {
    return $key eq 'phone' ? $self->norm_phones($v) : $NORM{$key}->($v);
}

sub add ($self, $id, $values) {
    for my $k ( @{ $self->{keys} } ) {
        push @{ $self->{index}{$k}{$_} }, $id for $self->_norm( $k, $values->{$k} );
    }
    return;
}

sub find ($self, $values) {
    my ( %ids, @via, $multi );
    for my $k ( @{ $self->{keys} } ) {
        my %hit;
        for my $n ( $self->_norm( $k, $values->{$k} ) ) {
            $hit{$_} = 1 for @{ $self->{index}{$k}{$n} // [] };
        }
        next if !%hit;
        push @via, $k;
        $multi = 1 if keys %hit > 1;
        $ids{$_} = 1 for keys %hit;
    }
    my @ids = sort { $a <=> $b } keys %ids;
    return { status => 'none', ids => [], via => [] } if !@ids;
    return { status => ( $multi || @ids > 1 ? 'many' : 'one' ), ids => \@ids, via => \@via };
}

sub has_key ($self, $values) {
    return scalar grep { $self->_norm( $_, $values->{$_} ) } @{ $self->{keys} };
}

1;

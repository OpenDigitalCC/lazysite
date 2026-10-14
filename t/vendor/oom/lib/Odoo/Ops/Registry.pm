package Odoo::Ops::Registry;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;

use Odoo::Error;

=head1 NAME

Odoo::Ops::Registry - discover named operations by namespace

=head1 SYNOPSIS

    my $reg = Odoo::Ops::Registry->new;              # default namespaces
    say for $reg->names;                             # crm.export, ...
    my $class = $reg->class_for('crm.export');

=head1 DESCRIPTION

Loads every C<.pm> directly under each namespace's directory on
C<@INC> and keeps the ones that are L<Odoo::Ops::Operation>
subclasses, keyed by C<op_name>. A new function pack is a new
namespace - pass C<namespaces>, or add it to C<$ENV{ODOO_OPS_NAMESPACES}>
(comma-separated). Two operations claiming one name is an error, not a
last-one-wins.

=cut

my @DEFAULT = qw(Odoo::Ops::Core Odoo::Ops::CRM Odoo::Ops::Comms Odoo::Ops::Stock);

sub new ($class, %args) {
    my @ns = @{ $args{namespaces} // [
        @DEFAULT, grep { length } split /\s*,\s*/, $ENV{ODOO_OPS_NAMESPACES} // ''
    ] };
    my $self = bless { ops => {} }, $class;
    $self->_scan($_) for @ns;
    return $self;
}

sub _scan ($self, $ns) {
    my $rel = File::Spec->catdir( split /::/, $ns );
    my %seen;
    for my $inc ( grep { !ref } @INC ) {
        my $dir = File::Spec->catdir( $inc, $rel );
        next if !-d $dir;
        opendir my $dh, $dir or next;
        for my $f ( sort grep { /^\w+\.pm\z/ } readdir $dh ) {
            my $pkg = $ns . '::' . ( $f =~ s/\.pm\z//r );
            next if $seen{$pkg}++;
            require( File::Spec->catfile( $rel, $f ) );
            next if !$pkg->isa('Odoo::Ops::Operation');
            my $name = $pkg->op_name;
            Odoo::Error->throw(
                kind    => 'config',
                message => "operation '$name' claimed by both $self->{ops}{$name} and $pkg",
            ) if $self->{ops}{$name} && $self->{ops}{$name} ne $pkg;
            $self->{ops}{$name} = $pkg;
        }
        closedir $dh;
    }
}

sub names ($self) { sort keys %{ $self->{ops} } }

sub class_for ($self, $name) {
    return $self->{ops}{$name} // Odoo::Error->throw(
        kind    => 'usage',
        message => "no operation '$name' (known: " . join( ', ', $self->names ) . ')',
    );
}

1;

package Odoo::Ops::Utf8;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Encode ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Utf8 - the command line and the standard handles as UTF-8 text, once

=head1 SYNOPSIS

    Odoo::Ops::Utf8->start( \@ARGV );    # first thing in a bin/ script

=head1 DESCRIPTION

Perl hands a program its arguments as bytes. A value typed as C<--set
set.name='Zoe - cafe'> with an accent or a dash reaches the JSON encoder as
bytes read as characters, and is encoded a second time on the wire: the stored
text is garbled and the program warns "Wide character". C<start> decodes every
argument from UTF-8 once, and puts C<:encoding(UTF-8)> on C<STDOUT> and
C<STDERR> so text leaves encoded once. Whatever prints a JSON document on those
handles builds it as characters (C<< Odoo::JSON->new( utf8 => 0 ) >>).

An argument that is not valid UTF-8 is a usage error naming its position, not
a guess at another encoding. An argument that is already text (a test that
sets C<@ARGV> from characters) is left as it is.

=head2 start(\@argv)

Decodes the array in place and sets the handles. Throws C<usage> when an
argument is not UTF-8.

=cut

sub start ($class, $argv) {
    my @out;
    for my $i ( 0 .. $#$argv ) {
        my $a = $argv->[$i];
        if ( !defined $a || utf8::is_utf8($a) ) { push @out, $a; next }
        my $t = eval { Encode::decode( 'UTF-8', $a, Encode::FB_CROAK() | Encode::LEAVE_SRC() ) };
        Odoo::Error->throw( kind => 'usage', message => 'argument ' . ( $i + 1 ) . ' is not valid UTF-8',
            fix => 'give text as UTF-8 (a terminal set to a legacy encoding sends other bytes), or read it from a file with --rows or --file' ) if !defined $t;
        push @out, $t;
    }
    @$argv = @out;
    binmode STDOUT, ':encoding(UTF-8)';
    binmode STDERR, ':encoding(UTF-8)';
    return;
}

1;

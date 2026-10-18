package Odoo::Ops::Stock::Validate;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

=head1 NAME

Odoo::Ops::Stock::Validate - validate a picking through Odoo's wizards, each one a decision

=head1 SYNOPSIS

    my $wizards = Odoo::Ops::Stock::Validate->run( $client, $profile, $picking_id,
        backorder => 'create', allow_expired => 0 );

=head1 DESCRIPTION

C<button_validate> returns C<true> or a window action naming a wizard
(SD3). This module loops over them, and answers only the ones the
caller's plan decided:

    stock.backorder.confirmation   answered as the caller chose with
                                   backorder: 'create' (process: the
                                   remainder becomes a backorder) or
                                   'cancel' (process_cancel_backorder: the
                                   paper is the whole truth, the remainder
                                   is closed). With no choice nothing is
                                   answered: it refuses with code
                                   backorder-choice, naming the moves that
                                   are short
    expiry.picking.confirmation    process when allow_expired is set,
                                   otherwise a fault
    stock.immediate.transfer       always a fault: it fills the done
                                   quantities from the reservation, the
                                   system's guess becoming the record (SA9);
                                   the plan always stages quantities
    anything else                  a fault

A wizard C<create> may answer a list of ids on XML-RPC; it is unwrapped
before the wizard is processed (SD2). More than four rounds is a fault.
It returns the models of the wizards it answered, and dies unless the
picking is C<done> afterwards.

The backorder wizard is answered Odoo's own way: created with the context of
the action that opened it, then C<process> or C<process_cancel_backorder>.
There is no default. When Odoo opens the wizard and the caller gave no
C<backorder>, the picking is left staged and not validated, and the refusal
(C<refused/backorder-choice>) names the picking, its id and the short moves
(product, demand, done). L<Odoo::Ops::Runner> records such a change as held,
not failed: it is information for the caller, who validates again with a
choice. C<backorder> is C<create>, C<cancel> or absent; anything else is
C<usage>.

=cut

sub run ($class, $client, $profile, $pid, %o) {
    Odoo::Error->throw( kind => 'usage', message => "backorder is 'create' or 'cancel', got '" . $o{backorder} . "'" )
        if defined $o{backorder} && $o{backorder} !~ /\A(?:create|cancel)\z/;
    my $picking = $client->model( $profile->model_name('picking') );
    my $ret     = $picking->call( 'button_validate', [ [$pid] ] );
    my ( $round, @answered ) = (0);
    my %immediate = map { $_ => 1 } grep { $_ eq 'immediate_wizard' } $profile->models;
    my $immediate = $immediate{immediate_wizard} ? $profile->model_name('immediate_wizard') : 'stock.immediate.transfer';
    while ( ref $ret eq 'HASH' && $ret->{res_model} ) {
        Odoo::Error->throw( kind => 'fault', message => "validating picking $pid opened more than four wizards" ) if ++$round > 4;
        my $m   = $ret->{res_model};
        my $ctx = $ret->{context} // {};
        my $method;
        if ( $m eq $immediate ) {
            Odoo::Error->throw( kind => 'fault', message => "validating picking $pid opened $m: no quantity was staged and the plan allows no wizard to fill it from the reservation (SA9)" );
        }
        elsif ( $m eq $profile->model_name('backorder_wizard') ) {
            $class->_backorder_choice( $client, $profile, $pid ) if !$o{backorder};
            $method = $o{backorder} eq 'create' ? 'process' : 'process_cancel_backorder';
        }
        elsif ( $m eq 'expiry.picking.confirmation' ) {
            Odoo::Error->throw( kind => 'fault', message => "validating picking $pid opened $m: a lot is expired and the plan did not allow it" ) if !$o{allow_expired};
            $method = 'process';
        }
        else {
            Odoo::Error->throw( kind => 'fault', message => "validating picking $pid opened an unknown wizard $m" );
        }
        my $wiz = $client->model($m);
        my $wid = $wiz->create( {}, context => $ctx );
        $wid = $wid->[0] if ref $wid eq 'ARRAY';    # SD2
        push @answered, $m;
        $ret = $wiz->call( $method, [ [$wid] ], context => $ctx );
    }
    my $state = $picking->read_one( $pid, [ $profile->field( picking => 'state' ) ] );
    my $s = $state ? $state->{ $profile->field( picking => 'state' ) } : undef;
    Odoo::Error->throw( kind => 'fault', message => "picking $pid is '" . ( $s // 'gone' ) . "' after validation, not done" ) if ( $s // '' ) ne 'done';
    return \@answered;
}

# The refusal when Odoo asks for a backorder and the caller chose nothing: which moves are short,
# read from the picking as it stands (nothing is guessed about what Odoo will do).
sub _backorder_choice ($class, $client, $profile, $pid) {
    my $f  = sub ($lm, $lf) { $profile->field( $lm => $lf ) };
    my ( $name, @short ) = ( $pid );
    eval { ( $name, @short ) = $class->_short_moves( $client, $profile, $pid ); 1 };
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'backorder-choice',
        message => "validating picking $name (id $pid) opened the backorder wizard: short " . ( @short ? join( '; ', @short ) : 'by Odoo\'s count' )
            . '; the picking is staged and not validated',
        fix     => 'validate it again with backorder=create (the remainder becomes a backorder) or backorder=cancel (the remainder is closed)',
    );
}

# The picking's name and its short moves, as 'product demand D done G'.
sub _short_moves ($class, $client, $profile, $pid) {
    my $f  = sub ($lm, $lf) { $profile->field( $lm => $lf ) };
    my $pk = $client->model( $profile->model_name('picking') )->read_one( $pid, [ $f->( picking => 'name' ) ] );
    my $mv = $client->model( $profile->model_name('move') );
    my $ln = $client->model( $profile->model_name('move_line') );
    my $picked = $profile->has_field( move_line => 'picked' ) ? $f->( move_line => 'picked' ) : undef;
    my $done   = $f->( move_line => 'done' );
    my @lines  = @{ $ln->search_read( [ [ $f->( move_line => 'picking' ), '=', $pid ] ], [ $f->( move_line => 'move' ), $done, ( $picked ? $picked : () ) ] ) };
    my %got;
    for my $l (@lines) {
        next if $picked && !$l->{$picked};
        my $m = $l->{ $f->( move_line => 'move' ) };
        $got{ ref $m ? $m->[0] : $m } += $l->{$done} // 0;
    }
    my @short;
    for my $m ( @{ $mv->search_read( [ [ $f->( move => 'picking' ), '=', $pid ] ], [ $f->( move => 'product' ), $f->( move => 'demand' ) ] ) } ) {
        my $d = $m->{ $f->( move => 'demand' ) } // 0;
        my $g = $got{ $m->{id} } // 0;
        next if $g >= $d - 0.001;
        my $pr = $m->{ $f->( move => 'product' ) };
        push @short, ( ref $pr ? $pr->[1] : $pr ) . " demand $d done $g";
    }
    return ( $pk ? $pk->{ $f->( picking => 'name' ) } : $pid, @short );
}

1;

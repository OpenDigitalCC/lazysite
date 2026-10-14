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
        close_backorder => 1, allow_expired => 0 );

=head1 DESCRIPTION

C<button_validate> returns C<true> or a window action naming a wizard
(SD3). This module loops over them, and answers only the ones the
caller's plan decided:

    stock.backorder.confirmation   process_cancel_backorder when
                                   close_backorder is set (the paper is the
                                   whole truth, the remainder is closed);
                                   otherwise a fault
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

=cut

sub run ($class, $client, $profile, $pid, %o) {
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
            Odoo::Error->throw( kind => 'fault', message => "validating picking $pid opened $m but the plan does not close the remainder" ) if !$o{close_backorder};
            $method = 'process_cancel_backorder';
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

1;

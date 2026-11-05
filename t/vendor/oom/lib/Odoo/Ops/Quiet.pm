package Odoo::Ops::Quiet;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(quiet_context quiet_for);

=head1 NAME

Odoo::Ops::Quiet - the one context OOM sends when a write is to be quiet

=head1 SYNOPSIS

    use Odoo::Ops::Quiet qw(quiet_context);
    $plan->add( ..., context => quiet_context() );

=head1 DESCRIPTION

C<quiet_context> returns a new hash of every flag OOM sends when the caller
wants no chatter and no mail from a create or a write:

=over

=item C<tracking_disable>, C<mail_notrack>

no tracking message for a changed field.

=item C<mail_create_nolog>

no "created" message.

=item C<mail_create_nosubscribe>

the acting user is not made a follower.

=item C<mail_auto_subscribe_no_notify>

no "You have been assigned to ..." mail to an assignee. Odoo 16, 17, 18 and 19
all read this key: C<mail.thread._message_auto_subscribe_notify> returns at once
when it is set, and on 17 to 19 so does C<project.task._task_message_auto_subscribe_notify>
(read in the OCB sources of the four series).

=back

Every site that builds a quiet context calls this sub, so the set cannot differ
between sites. A caller that needs more keys adds them to the hash it gets.

=head2 quiet_for($behaviour, $on, $what)

The one rule for the C<quiet> option of C<core.make>, C<core.set> and
C<core.action>: the context sent is the union of C<quiet_context> and the
C<suppress: { context: ... }> of every effect the model's behaviour file
records for this write (C<$on> is C<create>, C<write> or C<call>; C<$what> the
field names or the method, as L<Odoo::Ops::Behaviour/effects_for> takes them).
It returns C<< { context, keys, effects, words } >>: the hash to send, its keys
sorted, the effect texts that the behaviour keys silence, and a sentence for the
plan line that names the keys and the effect, or says that no recorded effect
applies (the shared context is sent all the same; it does no harm).

=cut

sub quiet_context () {
    my $t = JSON::PP::true;
    return {
        tracking_disable              => $t,
        mail_create_nolog             => $t,
        mail_notrack                  => $t,
        mail_create_nosubscribe       => $t,
        mail_auto_subscribe_no_notify => $t,
    };
}

sub quiet_for ($beh, $on, $what) {
    my ( %own, @effects );
    for my $e ( $beh->effects_for( $on, $what ) ) {
        my $sc = ref $e->{suppress} eq 'HASH' ? $e->{suppress}{context} : undef;
        next if ref $sc ne 'HASH';
        push @effects, $e->{effect};
        $own{$_} = 1 for keys %$sc;
    }
    my $ctx  = quiet_context();
    $ctx->{$_} = JSON::PP::true for keys %own;
    my @keys = sort keys %$ctx;
    my $words = 'quiet: sends ' . join( ', ', @keys ) . ( @effects
        ? ' (silences: ' . join( '; ', @effects ) . ')'
        : '; no recorded effect applies, so only the shared context is sent' );
    return { context => $ctx, keys => \@keys, effects => \@effects, words => $words };
}

1;

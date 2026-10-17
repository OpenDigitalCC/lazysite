package Odoo::Ops::PlanPrint;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

=head1 NAME

Odoo::Ops::PlanPrint - the lines of a plan and of a failed apply that oom-ops and oom-mailshot both print

=head1 DESCRIPTION

Plain functions that return lines of text, so that the two front doors
(C<oom-ops> and L<Odoo::Tools::Mailshot>) say the same thing in the same
words and neither prints for the other.

=head2 standing_effects($plan)

The text of every effect that stands (a planned change triggers it and the
context does not suppress it), once each, in model order. The plan's
C<side effects: N standing ...> note counts them; these are the lines that
follow it, each printed as C<standing: ...>.

=cut

sub standing_effects ($plan) {
    my ( %seen, @out );
    my $e = $plan->effects;
    for my $m ( sort keys %$e ) {
        for my $l ( @{ $e->{$m} } ) {
            next if $l->{changes} - $l->{suppressed} <= 0 || $seen{ $l->{effect} }++;
            push @out, $l->{effect};
        }
    }
    return @out;
}

=head2 standing_lines($plan)

C<standing_effects> as the printed lines, two spaces in, each starting
C<standing: >.

=cut

sub standing_lines ($plan) { map { "  standing: $_" } standing_effects($plan) }

=head2 failed_lines($result_hash, $conf, %o)

The lines for the changes of an apply that failed: one C<failed: ...> per
change, then C<fix_lines>. Empty when nothing failed. C<< lead => '   ' >>
indents every line.

=head2 fix_lines($result_hash, $conf, %o)

The C<fix:> line naming how to plan the rest of a run that stopped
(C<oom-ops resume --journal J --conf C>), with the extra line for a delete
Odoo refused for want of a state. Empty when nothing failed. The tool prints
only these under its own C<FAILED> lines, since it has said what failed.

=cut

sub failed_lines ($h, $conf, %o) {
    my @f = @{ $h->{failed_changes} // [] };
    return () if !@f;
    my $lead = $o{lead} // '';
    my @out;
    for my $x (@f) {
        my ($first) = split /\n/, $x->{message} // '', 2;
        my $what = join ' ', grep { defined && length } $x->{model} // $x->{action}, $x->{id} // $x->{key};
        push @out, $lead . 'failed: ' . $what . ': ' . ( $first // 'no message' );
    }
    return ( @out, fix_lines( $h, $conf, %o ) );
}

sub fix_lines ($h, $conf, %o) {
    my @f = @{ $h->{failed_changes} // [] };
    return () if !@f;
    my $lead = $o{lead} // '';
    my @out = ( $lead . "fix: remove the cause, then plan the rest: oom-ops resume --journal $h->{journal} --conf $conf" );
    push @out, $lead . '     (Odoo will not delete a record until its state allows it: the record must be cancelled first)'
        if grep { ( $_->{message} // '' ) =~ /\b(?:delete|unlink)\b.*\bcancel/is } @f;
    return @out;
}

=head2 made_text($created)

One record an action made, as the lines say it: C<hr.expense.sheet 16 (EX0016, draft)>.
$created is C<< { model, id, name, state } >>.

=cut

sub made_text ($c) {
    my @in = grep { defined && length } ( $c->{name}, $c->{state} );
    return "$c->{model} $c->{id}" . ( @in ? ' (' . join( ', ', @in ) . ')' : '' );
}

=head2 made_lines(\@created, %o)

C<made: hr.expense.sheet 16 (EX0016, draft)>, one line per record that Odoo
made as a side effect of a change (C<created> on a result's C<custom> entry or a
journal change). C<lead> is put in front of each line.

=cut

sub made_lines ($created, %o) {
    my $lead = $o{lead} // '';
    return map { $lead . 'made: ' . made_text($_) } @{ $created // [] };
}

=head2 journal_made_lines($journal_path, %o)

The C<made:> lines of every done change in a journal, each after the change that
made them (C<#seq model id>), for C<oom-ops show>. Nothing when the journal made none
or cannot be read.

=cut

sub journal_made_lines ($path, %o) {
    require Odoo::Ops::Journal;
    my $lead = $o{lead} // '';
    my ( $h, $changes ) = eval { Odoo::Ops::Journal->read($path) };
    return () if !$changes;
    my @out;
    for my $c ( grep { ref $_->{created} eq 'ARRAY' && @{ $_->{created} } } @$changes ) {
        push @out, $lead . "#$c->{seq} " . join( ' ', grep { defined } $c->{model}, $c->{id} ) . ( defined $c->{key} ? " [$c->{key}]" : '' ) . ':';
        push @out, made_lines( $c->{created}, lead => $lead . '  ' );
    }
    return @out;
}

1;

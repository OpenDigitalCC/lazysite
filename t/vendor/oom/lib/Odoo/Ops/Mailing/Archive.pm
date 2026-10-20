package Odoo::Ops::Mailing::Archive;

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

Odoo::Ops::Mailing::Archive - archive a mailing, or bring an archived one back

=head1 SYNOPSIS

    oom-ops run mailing.archive --conf ops.conf --set mailing=7
    oom-ops run mailing.archive --conf ops.conf --set mailing=7 --set active=1

=head1 DESCRIPTION

A sent mailing is the record of what went out and is kept
(C<mailing.delete> holds it); C<mailing.archive> takes it out of the way
instead. It writes C<active> false on the mailing (Odoo 16's
C<mailing.mailing> has the field; an archived mailing drops out of the
default lists and out of the queue cron's search but keeps its traces and
counters). C<active=1> restores it. Both are plain writes with a
before-image, so a revert undoes either.

    archive     the mailing is archived
    restore     active=1: the mailing is brought back
    unchanged   the mailing is already as asked

Archiving a mailing that is C<in_queue> or C<sending> is allowed, and the
plan says that Odoo's queue will no longer take it (it searches active
mailings only); C<mailing.cancel> first is the usual order. The read
operations show archived mailings with C<archived=1>.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.archive' }
sub summary ($class) { 'Plan archiving a mailing (a sent one is kept, not deleted), or restoring an archived one' }
sub pack    ($class) { 'mailing' }
sub params ($class) {
    {   mailing => { type => 'int',  required => 1, help => 'the mailing id' },
        active  => { type => 'bool', default => 0, help => '0 (default) archives; 1 restores an archived mailing' },
    };
}
sub buckets ($class) {
    [   { name => 'archive',   meaning => 'the mailing is archived (active false)' },
        { name => 'restore',   meaning => 'active=1: the archived mailing is brought back' },
        { name => 'unchanged', meaning => 'the mailing is already archived (or active) as asked' },
    ];
}
sub holds ($class) { [] }
sub read_scope  ($class) { { mailing => ['read'] } }
sub write_scope ($class) { { mailing => [qw(read write)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $id = $self->param('mailing');
    my $m  = $self->model('mailing')->read( [$id], [ $f->('subject'), $f->('state'), $f->('active') ] )->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.archive: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $now  = $m->{ $f->('active') } ? 1 : 0;
    my $want = $self->param('active') ? 1 : 0;
    my $state = $m->{ $f->('state') };
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = "mailing:$id";
    if ( $now == $want ) {
        $plan->add( bucket => 'unchanged', action => 'skip', key => $key, id => $id,
            reason => "mailing $id ('$m->{ $f->('subject') }') is already " . ( $want ? 'active' : 'archived' ) );
        return $plan;
    }
    $plan->note("mailing $id is $state: Odoo's queue searches active mailings only, so an archived one is not sent; mailing.cancel it first if it should not go")
        if !$want && $state =~ /^(?:in_queue|sending)\z/;
    $plan->add(
        bucket => $want ? 'restore' : 'archive', action => 'write', model => $p->model_name('mailing'), id => $id, key => $key,
        vals   => { $f->('active') => $want ? JSON::PP::true : JSON::PP::false },
        before => { $f->('active') => $now ? 1 : 0 },
        reason => "mailing $id ('$m->{ $f->('subject') }', $state) " . ( $want ? 'is brought back' : 'is archived; its traces and counters are kept' ),
    );
    return $plan;
}

1;

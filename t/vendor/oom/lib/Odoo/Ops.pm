package Odoo::Ops;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Digest::SHA qw(sha256_hex);

our $VERSION = '0.33';

=head1 NAME

Odoo::Ops - named, previewable, journalled operations over Odoo

=head1 DESCRIPTION

The layer above the mapper that turns "do this to the business data"
into something reviewable. It is function-agnostic: the CRM is its
first function pack, not its purpose.

    Odoo::Ops::Config      key=value connection files
    Odoo::Ops::Credential  credential strategies (file now; session and
                           cookie are the lazysite extension's to add)
    Odoo::Ops::Guard       transport wrapper: refuses any call outside
                           the running operation's declared scope, and
                           writes one audit record per call
    Odoo::Ops::Audit       the audit sink (never payload, never key)
    Odoo::Ops::Profile     logical -> physical schema per series,
                           validated against the live fields_get
    Odoo::Ops::Context     one connection + profile + audit + run dir
    Odoo::Ops::Operation   base class for named operations
    Odoo::Ops::Registry    discovers operations by namespace
    Odoo::Ops::Plan        what a write operation intends; applied => 0
    Odoo::Ops::Runner      applies a plan through a journal; reverts
    Odoo::Ops::Journal     append-only record of what was done
    Odoo::Ops::Result      what apply did; applied => 1

Read operations return a report. Write operations never write when
asked to run: they return a plan, which is saved, reviewed, and
applied as a separate step against the same instance.

=head1 FUNCTIONS

=head2 json

A shared canonical UTF-8 JSON codec, so fingerprints are stable.

=head2 fingerprint($data)

SHA-256 of the canonical JSON of C<$data>.

=cut

my $JSON = JSON::PP->new->utf8->canonical->allow_nonref;

sub json () { $JSON }

sub fingerprint ($data) { sha256_hex( $JSON->encode($data) ) }

=head2 iso_time($epoch)

UTC ISO-8601 (C<2026-09-28T10:15:00Z>).

=cut

sub iso_time ($epoch) {
    my @t = gmtime $epoch;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
}

1;

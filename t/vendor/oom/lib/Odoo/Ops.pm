package Odoo::Ops;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::JSON ();
use Digest::SHA qw(sha256_hex);

our $VERSION = '0.44';

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

A shared canonical UTF-8 JSON codec, so fingerprints are stable: the one
L<Odoo::JSON> picks (L<Cpanel::JSON::XS> when installed, else L<JSON::PP>).

=head2 check_input_file($path, $who) / check_input_text($text, $label, $who) / read_input($path, $who)

The size bound on input an outside party can supply (L<Odoo::Ops::Input>,
C<max_input_bytes>): refuse a file or text over it as C<refused/input-too-large>
before a parser sees it; C<read_input> returns the bytes of a file within it.
Here so that a pack and L<Odoo::Ops::Rows> reach it without loading more.

=cut

sub check_input_file ( $path, $who = undef ) { require Odoo::Ops::Input; Odoo::Ops::Input->check_file( $path, $who ) }
sub check_input_text ( $text, $label, $who = undef ) { require Odoo::Ops::Input; Odoo::Ops::Input->check_text( $text, $label, $who ) }
sub read_input ( $path, $who = undef ) { require Odoo::Ops::Input; Odoo::Ops::Input->slurp( $path, $who ) }

=head2 fingerprint($data)

SHA-256 of the canonical JSON of C<$data>.

=cut

sub json () { Odoo::JSON->json }

=head2 seal_json

The encoder every digest is taken over (a plan's fingerprint, a run's key):
L<JSON::PP>, canonical, whichever encoder reads the files, so a seal holds
under every encoder and across releases. See L<Odoo::JSON/sealer>.

=cut

sub seal_json () { Odoo::JSON->sealer }

sub fingerprint ($data) { sha256_hex( seal_json()->encode($data) ) }

=head2 iso_time($epoch)

UTC ISO-8601 (C<2026-09-28T10:15:00Z>).

=cut

sub iso_time ($epoch) {
    my @t = gmtime $epoch;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
}

1;

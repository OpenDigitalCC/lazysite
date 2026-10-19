package Odoo::Ops::Version;

use strict;
use warnings;

our $VERSION = '0.34';

=head1 NAME

Odoo::Ops::Version - the installed OOM version, and nothing else

=head1 SYNOPSIS

    require Odoo::Ops::Version;
    my $v = $Odoo::Ops::Version::VERSION;      # '0.31'

=head1 DESCRIPTION

A module that loads nothing, so a program that only needs the version (a
supervisor deciding whether a running oomd is the installed one) reads it
without loading OOM. The release keeps it equal to the other modules'
versions. The same string is the one line of F</usr/share/odoo-oom/VERSION>
and the C<version> of oomd's health verb.

=cut

1;

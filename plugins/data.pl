#!/usr/bin/perl

# The data plugin - tables a site declares, holds and renders.
#
# ADR 0009'S FIRST CONFORMING IMPLEMENTATION, and built to that shape from its
# first commit rather than retrofitted. The `owns` block below is the whole
# point: the platform is meant to CONSUME it - backup and site packages read
# `storage`, the SBOM gate reads `deps`, the capability lints discover
# `capabilities`, and the enabled gate (SM409) refuses everything here when the
# plugin is off. Where the platform still knows a plugin by name, conformance
# removes an entry from a core list rather than adding one.
#
# THE BOUNDARY, restated because it is what stops this becoming an application
# server: tables hold SITE state - a product list, an events calendar, a
# directory. Per-visitor state (a session, a profile, a basket) is an
# application and is out of scope; the BACKLOG sketch that named those schemas
# is superseded by SM410.
#
# WHAT IS AND IS NOT HERE YET. The typed core is built and tested
# (Lazysite::Data::{Descriptor,SQLite,Value,Schema,Export,Connect}). This file
# currently declares the plugin and answers --describe; the capability, the
# control-API actions and the MCP tools are the next commit, and until they
# exist nothing routes here. That order is deliberate: the declaration is what
# the parity lints read, so it goes in first and the surfaces are added against
# it rather than the other way round.

use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). Deferred, because --describe must answer even where the tree
    # is not found - a plugin that cannot describe itself cannot be listed,
    # and a sysop would see it missing rather than broken.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'data',
        name        => 'Data tables',
        description => 'Tables a site declares and holds: a product list, an '
            . 'events calendar, a directory. Each table is described by a '
            . 'field descriptor - names, types, what is required - and the '
            . 'engine keeps every write to it. Pages read tables through the '
            . 'same page-variable mechanism as anything else, so a listing is '
            . 'a template rather than a feature. Holds SITE data; per-visitor '
            . 'state such as sessions or baskets is an application and is out '
            . 'of scope.',
        version     => '0.1',
        config_file => 'lazysite/data.conf',

        # SM469 / SM409: OPT IN TO THE ENABLED GATE. A descriptor declaring
        # `contract` executes only while its script is in the `plugins:` list,
        # and is born disabled - which is the right default for a plugin that
        # holds a site's data and has not met a real site yet.
        #
        # This was missing, and the comment on _gate_execution names the data
        # plugin as the first contract plugin, so the omission was mine rather
        # than a design question. Without it the gate treated this as a legacy
        # plugin and left it ungated.
        contract => 1,

        config_schema => [
            { key => 'db_source',
                label   => 'Storage engine',
                type    => 'text',
                default => 'sqlite',
                note    => 'Only "sqlite" is built. One file at '
                    . 'lazysite/db/data.sqlite, which makes a backup a copy '
                    . 'and needs nothing provisioned. Other engines are '
                    . 'gated on demand (DP-7).',
            },
            { key => 'db_descriptor_dir',
                label   => 'Where table descriptors live',
                type    => 'text',
                default => 'lazysite/db/tables',
                note    => 'One YAML file per table. These are content, not '
                    . 'configuration: they describe the shape of the site\'s '
                    . 'own data and travel with it.',
            },
            { key => 'db_max_rows',
                label   => 'Largest listing a page may render',
                type    => 'text',
                default => '200',
                note    => 'A ceiling, not a page size. An unbounded listing '
                    . 'against a table an agent has been filling is how a '
                    . 'page comes to render for a minute.',
            },
        ],

        # ADR 0009. Each list is consumed by something, and each is asserted
        # against the code by t/unit/data/08 - a declaration nothing checks is
        # a comment with punctuation.
        owns => {
            config_keys => [qw(db_source db_descriptor_dir db_max_rows)],

            # Backup and site-package participation, by DECLARATION. SM410
            # finding B: content backups exclude ./lazysite entirely and a site
            # package copies content, nav and layout only - so before this, a
            # migrated or content-restored site arrived without its database
            # and nothing said so.
            storage => ['lazysite/db/'],

            # DP-3. It needs Lazysite::Auth::Session (SM411) because the
            # front door routes lazysite-*.pl but wraps only the processor and
            # manager-api - so a direct-CGI plugin sees X-Remote-User exactly
            # as the client sent it, and trusting that would be SM402's defect
            # reintroduced by specification.
            endpoints => ['lazysite-data.pl'],

            capabilities => ['manage_data'],

            # SBOM gate keys. DBD::SQLite is the engine; DBI is the interface;
            # YAML::PP reads descriptors. JSON::PP and the File:: modules are
            # core and already declared.
            deps => [qw(DBI DBD::SQLite YAML::PP)],
        },

        actions => [

            # `run => 'action'` IS NOT OPTIONAL HERE, and leaving it out is
            # what SM477 was: the manager invokes a declared action as
            # `--scan` UNLESS it says otherwise, and this plugin's run()
            # serves `--action status`. So the Status button ran
            # `--scan --docroot DIR`, hit the fall-through, and showed the
            # operator a usage string - the plugin's two halves disagreeing
            # about their own contract.
            { id => 'status', label => 'Status', run => 'action' },
        ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1 if $argv[$i] eq '--describe';
        $opt{status} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'status';

        # `--scan` IS THE MANAGER'S DEFAULT, and every other plugin here
        # serves it. Answering it too means an action that forgets the
        # declaration degrades to the status report rather than to a usage
        # string - and status is the recovery surface an operator reaches for
        # when something is already wrong.
        $opt{status}  = 1                     if $argv[$i] eq '--scan';
        $opt{docroot} = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
    }

    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }

    if ( $opt{status} ) {
        print encode_json( status( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }

    print encode_json(
        { ok => 0, error => 'usage: --describe | --action status --docroot DIR' } );
    return 1;
}

# What an operator needs to know before trusting it with anything: are the
# modules present, is there a store, and how many tables are declared.
#
# REPORTS RATHER THAN REPAIRS. Creating the store here would mean a status
# check that changes the thing it is reporting on, which is the shape this
# programme keeps having to undo.
sub status {
    my ($docroot) = @_;
    my %out = ( ok => 1 );

    for my $m (qw(DBI DBD::SQLite YAML::PP)) {
        ( my $path = "$m.pm" ) =~ s{::}{/}g;
        $out{modules}{$m} = eval { require $path; 1 } ? 'present' : 'missing';
    }

    my $store = "$docroot/lazysite/db/data.sqlite";
    $out{store} = -f $store ? { exists => 1, bytes => -s $store }
        :   { exists => 0 };

    my $dir = "$docroot/lazysite/db/tables";
    my @tables;
    if ( opendir my $dh, $dir ) {
        @tables = sort map { s/\.ya?ml\z//r }
            grep { /\.ya?ml\z/ } readdir $dh;
        closedir $dh;
    }
    $out{tables} = \@tables;

    # SM495: the Plugin Manager shows data.message or the literal 'Done.' -
    # so a status with no message is a button that answers 'Done.' while
    # three fields go unread. Say what was found, in one line, worst news
    # first: a missing module is why nothing else will work.
    my @missing = sort grep { $out{modules}{$_} eq 'missing' } keys %{ $out{modules} };
    my $summary =
        @missing               ? 'missing Perl module(s): ' . join( ', ', @missing )
        : !$out{store}{exists} ? 'no store yet - it is created on the first declared table'
        : @tables
        ? scalar(@tables)
        . ' table(s): '
        . join( ', ', @tables )
        . sprintf( '; store %.0f KB', $out{store}{bytes} / 1024 )
        : 'store present, no tables declared';
    $out{message} = "Data tables: $summary";

    return \%out;
}

1;

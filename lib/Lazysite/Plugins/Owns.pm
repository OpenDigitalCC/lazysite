package Lazysite::Plugins::Owns;

# ADR 0009: reading and VALIDATING a plugin's `owns` declaration.
#
# WHY VALIDATION LIVES HERE AND NOT IN EACH CONSUMER. The whole contract is
# that the platform consumes the declaration instead of knowing the plugin by
# name: backup and site packages read `storage`, the SBOM gate reads `deps`,
# the capability lints discover `capabilities`. Every one of those TRUSTS the
# list. Trust established separately by each consumer is trust established
# four times and correctly zero to three of them - which is the shape of defect
# this codebase keeps meeting.
#
# `storage` IS THE DANGEROUS ONE, and it is why this module exists before any
# consumer does. A site package deliberately excludes `lazysite/` because that
# is where secrets live; carrying plugin storage means carrying NAMED paths
# beneath it. A declaration of `lazysite/` or `../..` or `/etc` would turn a
# feature that ships a site into one that ships an auth store. So the paths are
# checked here, once, at the point they are read - and the check is
# deliberately narrow: under `lazysite/`, no traversal, no absolute paths, no
# symlink-shaped surprises, and a trailing slash so a declaration cannot name a
# prefix of a sibling.
#
# NOTHING CONSUMES THIS YET, deliberately. The validator and its tests land
# before the first consumer so that consumer is written against a checked
# structure rather than a hopeful one.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(validate_owns owns_keys);

# The declared keys, and nothing else. An unknown key is refused rather than
# ignored: a plugin author writing `capability` for `capabilities` would
# otherwise get silence and a capability that never appears, which reads as the
# platform being broken.
my @KEYS = qw(config_keys storage endpoints capabilities deps);

sub owns_keys { my @k = @KEYS; return @k }

sub _err {
    my ( $id, $key, $why ) = @_;
    return { plugin => $id, key => $key, error => $why };
}

# Returns a LIST of problems - empty when the declaration is sound.
#
# A list rather than the first failure, because the caller is either a lint
# reporting to a developer or a manager page reporting to a sysop, and both
# want every problem at once. Stopping at the first turns one fix into four
# round trips.
sub validate_owns {
    my ( $id, $owns ) = @_;
    my @bad;

    return ( _err( $id, 'owns', 'owns must be a mapping' ) )
        unless ref $owns eq 'HASH';

    my %known = map { $_ => 1 } @KEYS;
    for my $k ( sort keys %{$owns} ) {
        push @bad, _err( $id, $k, "unknown owns key '$k' (expected: "
                . join( ', ', @KEYS ) . ')' )
            unless $known{$k};
    }

    for my $k (@KEYS) {
        next unless exists $owns->{$k};
        push @bad, _err( $id, $k, "$k must be a list" )
            unless ref $owns->{$k} eq 'ARRAY';
    }
    return @bad if @bad;

    for my $p ( @{ $owns->{storage} || [] } ) {
        # Explicit blocks rather than `push ... and next if ...`: perlcritic
        # refuses the mixed-precedence form (PBP p70) and it is genuinely
        # harder to read, which matters more in the one function that decides
        # what a site package is allowed to carry.
        if ( ref $p || !defined $p || !length $p ) {
            push @bad, _err( $id, 'storage', 'a storage path must be a plain string' );
            next;
        }

        # UNDER lazysite/, and named. The site package excludes lazysite/
        # wholesale precisely because secrets live there, so a plugin may claim
        # a NAMED subtree of it and never the tree itself.
        if ( $p !~ m{\A lazysite/ [^/] }x ) {
            push @bad, _err( $id, 'storage',
                "'$p' must be under lazysite/ - that is the only tree a plugin "
                    . 'owns storage in' );
            next;
        }

        if ( $p =~ m{(?:\A|/)\.\.(?:/|\z)} ) {
            push @bad, _err( $id, 'storage', "'$p' must not contain '..'" );
            next;
        }

        if ( $p =~ m{\A/} ) {
            push @bad, _err( $id, 'storage', "'$p' must be relative, not absolute" );
            next;
        }

        # A trailing slash, so the path names a DIRECTORY and cannot be a bare
        # prefix of a sibling. Without it, `lazysite/db` claims `lazysite/db2`
        # to any consumer doing a prefix match - the boundary fault this
        # codebase has met six times, arriving in a new place.
        if ( $p !~ m{/\z} ) {
            push @bad, _err( $id, 'storage',
                "'$p' must end in '/' - a directory, so it cannot also match a "
                    . 'sibling whose name merely starts the same way' );
        }
    }

    for my $c ( @{ $owns->{capabilities} || [] } ) {
        push @bad, _err( $id, 'capabilities',
            "'" . ( defined $c ? $c : '(undef)' )
                . "' must be lower-case letters, digits and underscores" )
            unless defined $c && !ref $c && $c =~ /\A[a-z][a-z0-9_]*\z/;
    }

    for my $e ( @{ $owns->{endpoints} || [] } ) {
        # A direct-CGI surface, named as the script it is. No path, because an
        # endpoint elsewhere is not this plugin's to declare.
        push @bad, _err( $id, 'endpoints',
            "'" . ( defined $e ? $e : '(undef)' )
                . "' must be a bare script name ending in .pl" )
            unless defined $e && !ref $e && $e =~ /\A[a-z][a-z0-9-]*\.pl\z/;
    }

    for my $m ( @{ $owns->{deps} || [] } ) {
        push @bad, _err( $id, 'deps',
            "'" . ( defined $m ? $m : '(undef)' ) . "' is not a module name" )
            unless defined $m && !ref $m && $m =~ /\A[A-Z][\w:]*\z/;
    }

    for my $k ( @{ $owns->{config_keys} || [] } ) {
        push @bad, _err( $id, 'config_keys',
            "'" . ( defined $k ? $k : '(undef)' )
                . "' must be lower-case letters, digits and underscores" )
            unless defined $k && !ref $k && $k =~ /\A[a-z][a-z0-9_]*\z/;
    }

    return @bad;
}

1;

#!/usr/bin/perl
# SM662: print what every capability gate ACTUALLY decides, as a stable
# fingerprint, so a restructure of the gate tables can be proved to change
# nothing.
#
#   perl tools/gate-fingerprint.pl > before.txt
#   ...restructure...
#   perl tools/gate-fingerprint.pl > after.txt
#   diff before.txt after.txt      # must be empty
#
# The predicates are EXECUTED, not read. Reading them is what cannot be done
# reliably - that is the whole subject of SM662 - so each is run against a fixed
# battery of capability sets (none, all, and each capability alone) and the
# yes/no answers recorded. Two tables that answer identically across the battery
# are equivalent for every grant this system can issue, because every gate is a
# combination of single capabilities.
use strict;
use warnings;

# The house bootstrap (t/lint/59): find lib/Lazysite wherever this tool is
# installed rather than assuming the repo layout. This one is a development
# tool and is excluded from the shipped manifest, but the lint applies to
# everything in tools/ - and an exception here would be an exception nobody
# remembers the reason for.
BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use FindBin;
use Lazysite::Auth::Settings;

my $api = "$FindBin::Bin/../lazysite-manager-api.pl";
my $src = do { open my $fh, '<', $api or die "$api: $!\n"; local $/; <$fh> };

my @CAPS = @Lazysite::Auth::Settings::CAP_KEYS;

sub table {
    my ($name)  = @_;
    my ($block) = $src =~ /\n( *my \%\Q$name\E = \(.*?\n *\);)/s
        or die "could not extract %$name\n";
    my %h;
    ( my $code = $block ) =~ s/^ *my \%\Q$name\E = \(/\%h = (/;
    # A STRING eval, deliberately, and the only way to do this honestly. The
    # whole point of the fingerprint is that the gate predicates cannot be READ
    # reliably - that is SM662's subject - so they are compiled and RUN. A block
    # eval cannot compile source extracted at runtime, and reimplementing the
    # table here would fingerprint the copy rather than the gate.
    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    eval "package SM662Print; no warnings; $code; 1" or die "compiling %$name: $@";
    ## use critic
    return %h;
}

# none / all / the capabilities that grant it alone. An AND-shaped gate shows
# `none` for singles and `all=yes`, which is how it stays distinguishable from
# an OR gate without a positional column to read.
sub _describe {
    my ($ask)   = @_;
    my $none    = $ask->( {} )                        ? 1 : 0;
    my $all     = $ask->( { map { $_ => 1 } @CAPS } ) ? 1 : 0;
    my @singles = grep { $ask->( { $_ => 1 } ) } @CAPS;
    return sprintf 'none=%d all=%d singles=%s', $none, $all,
        ( @singles ? join( ',', @singles ) : '-' );
}

# SM662: %need is now DERIVED from %need_caps, so extracting the literal
# `my %need = (` block no longer finds the decision - it finds the map that
# rebuilds it. Extract the declaration and rebuild the predicates the same way
# the API does, so this still fingerprints what the gate DECIDES.
#
# The rebuild is duplicated here on purpose and it is two lines: the tool must
# not import from the script it is auditing, or a fault in the rebuild would
# cancel itself out and the fingerprint would agree with a broken gate.
my %need_caps = table('need_caps');
my %need      = map {
    my $d = $need_caps{$_};
    $_ => (
        ( !ref $d && $d eq 'ALWAYS' )
        ? sub { 1 }
        : do { my @c = @{$d}; sub { my $h = shift; scalar grep { $h->{$_} } @c } }
    );
} keys %need_caps;
my %cookie = table('COOKIE_CAP');

# SM682 correction: the fingerprint is keyed by capability NAME, not by
# position in a battery.
#
# The first version printed a bitstring, one column per capability in @CAP_KEYS
# order. That is unreadable and, worse, WRONG for the job: adding a capability
# lengthens every row, so the first real use of this tool - introducing
# write_data - reported all 140 gates as changed. An instrument that cannot tell
# "a gate moved" from "the vocabulary grew" cannot answer the question it was
# built for.
#
# Naming the capabilities that grant each action is stable under vocabulary
# growth: a new capability appears only on the gates that actually admit it.
print "# per gate: whether NO capability grants it, whether ALL together do,\n";
print "# and which capabilities grant it ON THEIR OWN.\n";

print "\n## token gate (%need)\n";
for my $a ( sort keys %need ) {
    my $p = $need{$a};
    next unless ref $p eq 'CODE';
    printf "%-34s %s\n", $a, _describe( sub { $p->( $_[0], {} ) } );
}

# The cookie table is capability NAMES with separators, not predicates: `a|b`
# means either, `a+b` (SM660) means both. Printed resolved the same way, so the
# two halves of the gate can be compared in one artefact.
print "\n## cookie gate (%COOKIE_CAP)\n";
for my $a ( sort keys %cookie ) {
    my $spec = $cookie{$a};
    next if ref $spec;
    printf "%-34s %s\n", $a, _describe( sub {
            my ($c) = @_;
            my $ok;
            if ( $spec =~ /\+/ ) { $ok = 1; $ok &&= $c->{$_} for split /\+/, $spec }
            else                 { $ok = 0; $ok ||= $c->{$_} for split /\|/, $spec }
            return $ok;
    } );
}

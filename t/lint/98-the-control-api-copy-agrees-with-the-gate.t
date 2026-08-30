#!/usr/bin/perl
# SM662: the control-API register and the gate say the same thing.
#
# `ControlApi::Actions.pm` carries `caps => [...]` per action, and the gate that
# actually DECIDES carries the same fact in %need_caps. Two copies of one fact,
# and until 0.11.9 they could not even be compared: the gate held predicates -
# sub { $_[0]->{manage_data} } - and nothing can extract the capability from one
# without executing it. So the register was kept in step by hand, by reviewers,
# and SM687 needed nine registration points for one action with five of them
# found by a failing gate rather than by reading the code.
#
# Now the gate DECLARES its capabilities, the two are the same shape, and this
# test is the thing that was impossible before. It does not make the register
# derived - that is the remaining half of SM662 - but it makes a drift between
# them fail immediately, which is the property that mattered.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";
my $api  = "$root/lazysite-manager-api.pl";
my $reg  = "$root/lib/Lazysite/ControlApi/Actions.pm";
ok( -f $api, 'the API is present' ) or BAIL_OUT("no $api");
ok( -f $reg, 'the control-API register is present' ) or BAIL_OUT("no $reg");

# The declaration, compiled and run - the same way tools/gate-fingerprint.pl
# does it, and for the same reason: this must read what SHIPS, not a
# reimplementation of it that could agree with a broken table.
my $src = do { open my $fh, '<', $api or die $!; local $/; <$fh> };
my ($block) = $src =~ /\n( *my \%need_caps = \(.*?\n *\);)/s
    or BAIL_OUT( 'could not extract %need_caps. If the gate table was renamed '
        . 'or reshaped, point this test at it - do not let it pass by finding '
        . 'nothing to check.' );
my %need_caps;
( my $code = $block ) =~ s/^ *my \%need_caps = \(/\%need_caps = (/;
## no critic (BuiltinFunctions::ProhibitStringyEval)
eval "package SM662Lint; no warnings; $code; 1"
    or BAIL_OUT("compiling %need_caps: $@");
## use critic
cmp_ok( scalar keys %need_caps, '>', 50, 'the gate table was read' );

my %reg_caps;
{
    my $rsrc = do { open my $fh, '<', $reg or die $!; local $/; <$fh> };
    $rsrc =~ s{^\s*#.*$}{}mg;    # comments name capabilities in prose
    while ( $rsrc =~ /'([a-z0-9_-]+)'\s*=>\s*\{\s*caps\s*=>\s*\[([^\]]*)\]/g ) {
        my ( $action, $list ) = ( $1, $2 );
        my @c = $list =~ /'([a-z0-9_]+)'/g;
        $reg_caps{$action} = [ sort @c ];
    }
}
cmp_ok( scalar keys %reg_caps, '>', 50, 'the register was read' );

# Only actions the register claims. An action gated but not exposed over the
# control API is legitimate; one EXPOSED with the wrong capability list is not.
my @drift;
for my $action ( sort keys %reg_caps ) {
    my $declared = $need_caps{$action};
    unless ( defined $declared ) {
        push @drift, "$action: in the register, absent from the gate";
        next;
    }
    my @gate = ( !ref $declared && $declared eq 'ALWAYS' )
        ? ()
        : sort @{$declared};
    my $g = join( ',', @gate );
    my $r = join( ',', @{ $reg_caps{$action} } );
    push @drift, "$action: gate=[$g] register=[$r]" if $g ne $r;
}

is( "@drift", '', 'every exposed action lists the capabilities its gate needs' )
    or diag( "The register and the gate disagree:\n  "
        . join( "\n  ", @drift )
        . "\n\nThe GATE is what decides. A register that names a different\n"
        . "capability tells an integrator to ask for the wrong grant, and the\n"
        . "generated reference repeats it." );

done_testing();

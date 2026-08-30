#!/usr/bin/perl
# SM570: the ACL actions' token gate was `webdav || manage_content`, and the
# registry agreed - so no drift lint could see that a themes partner holding
# webdav for theme uploads could read, set and remove content rules. The rule
# this pins is structural: a CHANNEL capability (webdav, api, mcp, ui) says
# which door a grant may use, never what it may do through it, so no token
# gate may be satisfied by one. And every gated action must be in the
# registry, with the same capability set, so describe-capabilities tells the
# truth the dispatcher enforces.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root gate_caps);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
my $api = slurp("$root/lazysite-manager-api.pl");
my $reg = slurp("$root/lib/Lazysite/ControlApi/Actions.pm");

# SM662: read as data, through the one helper that extracts the gate table.
my %need = gate_caps($api);
ok( scalar keys %need, 'the token gate table was found' );
cmp_ok( scalar keys %need, '>=', 60, 'the gate table was parsed' );

my %CHANNEL       = map       { $_ => 1 } qw(webdav api mcp ui);
my @channel_gated = sort grep { grep { $CHANNEL{$_} } keys %{ $need{$_} } } keys %need;
is_deeply( \@channel_gated, [], 'no token gate is satisfied by a channel capability' )
    or diag( "channel-gated: @channel_gated - a grant that may use a door "
        . 'must not thereby be allowed to do everything behind it (SM570)' );

my %reg;
while ( $reg =~ /'([a-z0-9_-]+)'\s*=>\s*\{\s*caps\s*=>\s*(\[[^\]]*\]|undef)/g ) {
    my ( $a, $caps ) = ( $1, $2 );
    $reg{$a} = $caps eq 'undef' ? undef : { map { $_ => 1 } $caps =~ /'(\w+)'/g };
}
cmp_ok( scalar keys %reg, '>=', 60, 'the registry was parsed' );

my @absent = sort grep { !exists $reg{$_} } keys %need;
is_deeply( \@absent, [], 'every gated action is declared in the registry' )
    or diag("absent from ControlApi::Actions: @absent");

my @disagree;
for my $a ( sort keys %need ) {
    next unless exists $reg{$a} && defined $reg{$a};
    my $n = join ',', sort keys %{ $need{$a} };
    my $r = join ',', sort keys %{ $reg{$a} };
    push @disagree, "$a: gate=[$n] registry=[$r]" if $n ne $r;
}
is_deeply( \@disagree, [], 'the gate and the registry name the same capabilities' )
    or diag( join "\n", @disagree );

done_testing();

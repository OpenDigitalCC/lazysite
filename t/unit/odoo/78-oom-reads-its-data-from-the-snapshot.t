#!/usr/bin/perl
# SM1202: OOM'S BEHAVIOURS AND PROFILES COME FROM THE SNAPSHOT, WHATEVER THE HOST HOLDS.
#
# SM1081 (release manager, 2026-10-14) and t/lint/262: the gate never reads OOM from
# the host. OOM's search for behaviours and profiles is the snapshot's own tree
# (beside lib/) and then, hard-coded in Odoo::Ops::Behaviour / Profile ->core_dirs,
# the deb's data directory when it exists. OOM offers no way to remove that last
# root (the environment variables ODOO_OOM_BEHAVIOURS and ODOO_OOM_PROFILES ADD a
# root in front), so the host's directory cannot be poisoned or excluded from here.
# What is held instead, in a fresh perl on the snapshot's library:
#   1. the snapshot's tree is searched before any host directory;
#   2. every model (behaviours) and pack (profiles) the host's directory holds is
#      also in the snapshot, so the host root is never the one that answers - a
#      host with more than the snapshot (a newer deb) fails here and says so;
#   3. the pack directories are the ones OdooTest set, not the host's.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip vendor_dir oom_lib);

BEGIN { oom_or_skip() }

my $host = '/usr/share/' . 'odoo-oom';    # lint 262 allows this only in the tools that mean the host
my $snap = vendor_dir();

my $script = 'use strict; use warnings; use JSON::PP; require Odoo::Ops::Behaviour; require Odoo::Ops::Profile; require Odoo::Ops::Registry;'
    . ' print encode_json({ b => [ Odoo::Ops::Behaviour->core_dirs ], p => [ Odoo::Ops::Profile->core_dirs ] }), "\n";';
open my $ph, '-|', $^X, '-I' . oom_lib(), '-e', $script or die $!;
my $out = do { local $/; <$ph> };
close $ph;
my $r = eval { JSON::PP::decode_json($out) } or BAIL_OUT("child said: $out");

sub names { my ($d) = @_; opendir my $dh, $d or return (); my @n = sort grep { !/^\./ } readdir $dh; closedir $dh; return @n }

for my $kind ( [ b => 'behaviours' ], [ p => 'profiles' ] ) {
    my ( $k, $dir ) = @$kind;
    my @roots = @{ $r->{$k} };
    is( Cwd::abs_path( $roots[0] ), Cwd::abs_path("$snap/$dir"), "$dir: the snapshot's tree is searched first" )
        or diag explain \@roots;
    my @host_roots = grep { $_ eq "$host/$dir" } @roots;
    if ( !@host_roots ) {
        pass("$dir: the host holds none to search");
        next;
    }
    my %have = map { $_ => 1 } names("$snap/$dir");
    my @extra = grep { !$have{$_} } names("$host/$dir");
    is_deeply( \@extra, [], "$dir: nothing in the host's directory is missing from the snapshot, so it never answers" )
        or diag "The host's odoo-oom is newer than t/vendor/oom ($dir: @extra): re-vendor (tools/vendor-oom.sh) or the gate depends on the host.";
}

{
    local $ENV{ODOO_OOM_PACK_DIRS} = $ENV{ODOO_OOM_PACK_DIRS};
    like( $ENV{ODOO_OOM_PACK_DIRS} // '', qr{\Q$snap\E/}, 'the pack directories are the ones OdooTest set, not the host\'s' )
        unless $ENV{LAZYSITE_OOM_LIB};
}

done_testing;

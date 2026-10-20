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
#   2. no model (behaviours) or pack (profiles) that only the host's directory
#      holds is one this suite names, so the host root never answers for a test.
#      SM1204: a host with MORE than the snapshot (a newer deb: OOM 0.37's helpdesk
#      models on 2026-10-20) failed this outright, which made the gate depend on
#      the host - what SM1081 forbids. The extras are now reported as a TODO
#      (re-vendor when the release manager decides; tools/ext-compat.sh is the
#      advisory tier for a newer OOM), and only an extra the suite actually uses
#      fails, because only that one could change a test's result;
#   3. the pack directories are the ones OdooTest set, not the host's.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Cwd      ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip vendor_dir oom_lib);

BEGIN { oom_or_skip() }

my $host = '/usr/share/' . 'odoo-oom'; # lint 262 allows this only in the tools that mean the host
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
    my %have  = map  { $_ => 1 } names("$snap/$dir");
    my @extra = grep { !$have{$_} } names("$host/$dir");
    my @used  = grep { suite_names($_) } @extra;
    is_deeply( \@used, [], "$dir: nothing only the host holds is named by this suite, so it never answers for a test" )
        or diag "The suite uses $dir that only the host's odoo-oom has (@used): re-vendor (tools/vendor-oom.sh) or the gate depends on the host.";
TODO: {
        local $TODO = "the host's odoo-oom is newer than t/vendor/oom ($dir: @extra); re-vendor when ruled" if @extra;
        is_deeply( \@extra, [], "$dir: the snapshot holds everything the host's directory does" );
    }
}

# Whether any test file outside the vendored tree names $name (a model such as
# helpdesk.ticket, or a profile's pack name) as a word: the test files, their t/lib
# helpers and fixtures. Read once.
my %SUITE_TEXT;

sub suite_names {
    my ($name) = @_;
    unless (%SUITE_TEXT) {
        my $t    = Cwd::abs_path("$FindBin::Bin/../..");
        my $self = Cwd::abs_path($0);    # this file names the extras in its own notes
        my @todo = ($t);
        while ( my $d = shift @todo ) {
            next if $d =~ m{/vendor\z};
            opendir my $dh, $d or next;
            for my $e ( grep { !/^\./ } readdir $dh ) {
                my $p = "$d/$e";
                if ( -d $p ) { push @todo, $p; next }
                next unless $e =~ /\.(?:t|pm|pl|md|ya?ml|json|conf)\z/;
                next if Cwd::abs_path($p) eq $self;
                open my $fh, '<', $p or next;
                my $s = do { local $/; <$fh> };
                # only what reaches OOM: a file that loads it through OdooTest or
                # names an Odoo:: module, and the Odoo test packs and fixtures. A
                # word in a lint's list or a URL path (/helpdesk) reaches nothing.
                next unless $s =~ /\bOdooTest\b|\bOdoo::/ || $p =~ m{/(?:Odoo|odoo)[^/]*/};
                $SUITE_TEXT{$p} = $s;
            }
        }
    }
    return grep { /(?<![\w.])\Q$name\E(?![\w])/ } values %SUITE_TEXT;
}

{
    local $ENV{ODOO_OOM_PACK_DIRS} = $ENV{ODOO_OOM_PACK_DIRS};
    like( $ENV{ODOO_OOM_PACK_DIRS} // '', qr{\Q$snap\E/}, 'the pack directories are the ones OdooTest set, not the host\'s' )
        unless $ENV{LAZYSITE_OOM_LIB};
}

done_testing;

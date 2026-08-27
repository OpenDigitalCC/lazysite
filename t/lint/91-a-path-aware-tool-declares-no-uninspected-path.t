#!/usr/bin/perl
# SM661: the confinement passes inspected a hardcoded list of argument names,
# and two tools carry their path under other names.
#
# A grant scoped to /sites/alpha was refused write_file to /sites/beta and, in
# the same session, CREATED /sites/beta/sneaky.md through create_page and MOVED
# a page into beta through rename_page. create_page declares `slug`;
# rename_page declares `old` and `new`. Neither was in qw(path to from), so
# neither call was confined - by the SM155 scope pass or the SM268 H4 carve-out
# pass. Nothing was malformed; the calls were well-formed and the tools did
# exactly what they advertise.
#
# EXTENDING THE LIST IS THE FIX AND WOULD BE THE SAME DEFECT IN A YEAR. A
# hardcoded set of names is what failed. This lint is the part that makes the
# next differently-named path argument a DECISION rather than a discovery: a
# path_aware tool may declare only properties this file knows the answer for.
#
# Adding a tool with a new path-shaped argument therefore fails here, and the
# fix is one line in Manager::Common::@PATH_ARGS - not a second confinement
# pass and not a special case in the dispatcher.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(repo_root);
use Lazysite::Manager::Common ();

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
plan skip_all => "no $mcp" unless -f $mcp;

my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };
my ($tools) = $src =~ /\nmy %TOOLS = \((.*?)\n\);\n/s;
ok( $tools, 'the tool table was found' )
    or BAIL_OUT('no %TOOLS - this test would pass while checking nothing');

my %PATH = map { $_ => 1 } @Lazysite::Manager::Common::PATH_ARGS;
cmp_ok( scalar keys %PATH, '>=', 6,
    'the shared path-argument list is populated (not vacuous)' );
ok( $PATH{slug} && $PATH{old} && $PATH{new},
    'and it covers the three names SM661 found uninspected' );

# Properties that are demonstrably NOT content paths. Each is here because
# somebody decided it, and a new name is meant to stop this test rather than
# be waved through - which is the whole point.
my %NOT_A_PATH = map { $_ => 1 } qw(
    inputSchema content content_base64 title subtitle body items fields submit
    name handler query limit offset version sha register update_links add_alias
    read write draft host theme layout day month table columns rows format
    confirm reason message note value key enabled id type url method
);

my ( @unknown, $checked );
while ( $tools =~ /^\s{4}(\w+)\s*=>\s*\{(.*?)^\s{4}\},/gms ) {
    my ( $tool, $body ) = ( $1, $2 );
    next unless $body =~ /\bpath_aware\s*=>\s*1/;
    $checked++;
    for my $prop ( $body =~ /(\w+)\s*=>\s*\{\s*type\s*=>/g ) {
        next if $PATH{$prop} || $NOT_A_PATH{$prop};
        push @unknown, "$tool declares '$prop'";
    }
}
cmp_ok( $checked, '>', 10, 'path_aware tools were actually examined' );

is_deeply( \@unknown, [],
    'every property a path_aware tool declares is known to be a path or known '
        . 'not to be' )
    or diag( join "\n  ", '',
    @unknown, '',
    'A path_aware tool has gained an argument this file has no answer for. If '
        . 'it carries a content path, add it to '
        . 'Lazysite::Manager::Common::@PATH_ARGS so BOTH confinement passes see '
        . 'it - that is the SM661 defect. If it does not, add it to '
        . '%NOT_A_PATH here and say why in the commit.' );

# --- and the dispatcher really reads the shared list ------------------------
# If it went back to a literal, the list above could be perfect and confine
# nothing.
my $lits = () = $src =~ /for my \$pk \(qw\(path to from\)\)/g;
is( $lits, 0,
    'no confinement pass iterates a hardcoded qw(path to from) any more' );
my $shared = () = $src =~ /\@Lazysite::Manager::Common::PATH_ARGS/g;
cmp_ok( $shared, '>=', 3,
    'the scope pass, the carve-out pass and the capability override all read '
        . 'the shared list' );

done_testing();

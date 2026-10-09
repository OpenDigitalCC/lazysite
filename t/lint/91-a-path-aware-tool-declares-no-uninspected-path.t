#!/usr/bin/perl
# SM661, SM976 Q15f: every MCP tool says which of its arguments are content
# paths, and the confinement reads that.
#
# SM661: the confinement passes inspected a hardcoded qw(path to from), and a
# grant scoped to /sites/alpha CREATED /sites/beta/sneaky.md through
# create_page (`slug`) and MOVED a page into beta through rename_page
# (`old`/`new`). The fix named the path arguments once, for every tool, in
# Manager::Common::@PATH_ARGS.
#
# SM976 Q15f (ruled 2026-10-09, "Fix: per-tool path args"): one list for every
# tool was the next defect. rename_page's `old`/`new` are paths; replace_text's
# `old`/`new` are the text it finds and the text it puts in, and a scoped grant
# was refused "Path 'title: Plain' is outside your assigned scope". So each tool
# declares its own (`path_args` in %TOOLS), and this lint is what makes a new
# argument a DECISION rather than a discovery:
#   - a declared path argument must be in the tool's schema;
#   - every argument of every tool is a declared path, or known not to be one
#     (%NOT_A_PATH for a name that is never a path, %NOT_A_PATH_HERE for a
#     path-shaped name that is not a path on that one tool, with the reason);
#   - the three passes in tools/call read the declaration, and nothing reads a
#     shared name list any more.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
plan skip_all => "no $mcp" unless -f $mcp;

my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };
my ($tools) = $src =~ /\nmy %TOOLS = \((.*?)\n\);\n/s;
ok( $tools, 'the tool table was found' )
    or BAIL_OUT('no %TOOLS - this test would pass while checking nothing');

# Names that are never a content path, on any tool. Each is here because
# somebody decided it. The path-shaped names (path, to, from, slug, old, new,
# file) are deliberately absent: whether they are a path is a per-tool fact.
my %NOT_A_PATH = map { $_ => 1 } qw(
    inputSchema accept activate add_alias adopt_identity all apply bad body clean
    config confirm confirm_lost content content_base64 context css day description
    descriptor draft enabled entry every fields form good handler handlers host id
    index items key layout limit logins max_files max_kb month name new_name notify
    offset order order_by payload query rating read register row submit subtitle
    summary table tags theme title trails update update_links uploads value
    version window write
);

# A path-shaped name that is not a content path on this tool, and why.
my %NOT_A_PATH_HERE = (
    replace_text => { old => 'the text to find (ruled 2026-10-09)', new => 'the text to put in (ruled 2026-10-09)' },
    map { $_ => { file => 'a store entry, reached by the form or data rule, not a content path' } }
        qw(read_form_submission read_data_safety_export delete_data_safety_export restore_data_safety_export),
);

my ( @unknown, @undeclared_in_schema, @aware_without, %decl, $checked );
while ( $tools =~ /^\s{4}(\w+)\s*=>\s*\{(.*?)^\s{4}\},/gms ) {
    my ( $tool, $body ) = ( $1, $2 );
    $checked++;
    my %props = map { $_ => 1 } grep { $_ ne 'inputSchema' } $body =~ /(\w+)\s*=>\s*\{\s*type\s*=>/g;
    my ($list) = $body =~ /\bpath_args\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/;
    my @paths  = defined $list ? split( ' ', $list ) : ();
    $decl{$tool} = \@paths;
    my %path = map { $_ => 1 } @paths;
    push @undeclared_in_schema, "$tool declares path argument '$_', which its schema does not have"
        for grep { !$props{$_} } @paths;
    push @aware_without, $tool if $body =~ /\bpath_aware\s*=>\s*1/ && !@paths;
    for my $prop ( sort keys %props ) {
        next if $path{$prop} || $NOT_A_PATH{$prop} || $NOT_A_PATH_HERE{$tool}{$prop};
        push @unknown, "$tool declares '$prop'";
    }
}
cmp_ok( $checked, '>', 60, 'every tool was examined, not only the path-aware ones' );

is_deeply( \@undeclared_in_schema, [], 'every declared path argument is in its tool\'s schema' )
    or diag( join "\n  ", '', @undeclared_in_schema );

is_deeply( \@unknown, [], 'every argument of every tool is a declared path or known not to be one' )
    or diag( join "\n  ", '',
    @unknown, '',
    'A tool has an argument this file has no answer for. If it carries a content '
        . 'path, add it to that tool\'s path_args in lazysite-mcp.pl so all three '
        . 'passes see it - that is the SM661 defect. If it does not, add it to '
        . '%NOT_A_PATH (never a path) or %NOT_A_PATH_HERE (not on this tool) here '
        . 'and say why in the commit.' );

is_deeply( \@aware_without, [], 'a path_aware tool declares the path argument the override reads' )
    or diag( join "\n  ", '', @aware_without );

my @shaped = qw(path to from slug old new);
ok( !( grep { $NOT_A_PATH{$_} } @shaped ), 'no path-shaped name is waved through for every tool' );

# The ruling, by name.
is_deeply( $decl{rename_page}, [qw(old new)], 'rename_page\'s old and new are paths' );
is_deeply( $decl{replace_text}, ['path'], 'replace_text\'s path is a path, and its old and new are text' );
is_deeply( $decl{create_page}, ['slug'], 'create_page\'s slug is a path (SM661)' );

# --- and the dispatcher reads the declaration --------------------------------
my $lits = () = $src =~ /for my \$pk \(qw\(path to from/g;
is( $lits, 0, 'no confinement pass iterates a hardcoded name list' );
my $shared = () = $src =~ /^[^#\n]*PATH_ARGS/mg; # code, not the comments that tell the story
is( $shared, 0, 'nothing in the MCP server reads a shared path-name list' );
my $reads = () = $src =~ /for my \$pk \( _path_args\(\$tool\) \) \{/g;
is( $reads, 3, 'the capability override, the carve-out pass and the scope pass read the tool\'s declaration' );
like( $src, qr/sub _path_args \{\n    my \(\$tool\) = \@_;\n    my \$p = \$tool->\{path_args\};/,
    'and the declaration is the tool\'s own path_args' );

my $common = do { open my $fh, '<', "$root/lib/Lazysite/Manager/Common.pm" or die $!; local $/; <$fh> };
unlike( $common, qr/^our \@PATH_ARGS\b/m, 'Manager::Common no longer holds one list for every tool' );

done_testing();

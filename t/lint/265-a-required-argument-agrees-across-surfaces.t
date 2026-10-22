#!/usr/bin/perl
# SM1119: a REQUIRED ARGUMENT agrees across the two remote surfaces.
#
# MCP set_permissions declared required => ['path'] while the control API's
# acl-set took the same argument with no requirement and, for an absent one,
# invented a default - the dangerous kind - and both looked correct to every
# check. t/lint/23 pins that the two surfaces expose the same ACTIONS and
# records the deliberate one-sided ones; nothing compared what each one
# REQUIRES. This does, for every action that names an MCP twin: an argument
# required on one surface is required on the other, or the difference is
# recorded in %DIFFERENCE with its reason.
#
# The names compared are the names each surface uses. No rename map is kept:
# where a twin spells an argument differently the difference is recorded below,
# which is the honest place for it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
my $src = do { local $/; <$fh> };
close $fh;

# The tool table is a lexical in a script, so it is read from the source the
# way t/lint/85 reads it. A tool's own `required` is the one inside its
# inputSchema; a nested `required` (inside an item schema) is indented deeper
# than the schema's own, so only the one at the schema's indentation counts.
my %mcp_required;
while ( $src =~ /^    ([a-z_]+) => \{\n(.*?)\n    \},\n/msg ) {
    my ( $tool, $body ) = ( $1, $2 );
    my ($list) = $body =~ /^ {12}required\s*=>\s*\[([^\]]*)\]/m;
    $mcp_required{$tool} = { map { $_ => 1 } ( $list // '' ) =~ /['"]([^'"]+)['"]/g };
}
cmp_ok( scalar keys %mcp_required, '>=', 60, 'the MCP tool table was parsed' );

# action => { api_name => 'mcp_name' }: one argument the two surfaces SPELL
# differently, so the comparison is made on the one name. This is not a
# difference in what is required; it is the same argument under two names, each
# visible in the code that reads it.
my %SPELLED = (
    # The MCP tools pass `version` to the same action_git_* the control API
    # feeds `$params{sha}` (lazysite-mcp.pl view_version / restore_version).
    'git-show'    => { sha  => 'version' },
    'git-restore' => { sha  => 'version' },
    # The API's theme actions name the theme by the dispatcher's generic `path`
    # (action_theme_delete($path), action_theme_copy($path, ...)); the MCP tools
    # call the same argument `theme`.
    'theme-copy'   => { path => 'theme' },
    'theme-delete' => { path => 'theme' },
);

# action => { argument => reason }: differences that are deliberate. The reason
# is the one the code gives where it makes the choice, not a new one.
my %DIFFERENCE = (
    # SM310 / t/lint/52: an absent path reads the rule governing the site root,
    # the canonical spelling of that question, and the operation only reads.
    'acl-get' => { path => 'an absent path reads the root rule, which SM310 made the canonical spelling of that question; read-only either way (t/lint/52)' },
    # SM1052: acl-set takes a list `paths` in the body instead of `path`, so
    # neither alone is required; an absent path with no list is refused (SM306).
    # SM1263: acl-remove keeps the dispatcher's "/" default (SM306, t/integration/52).
    'acl-remove' => { path => 'SM306: with no path it removes the root rule, so recovery stays as easy as the mistake; remove_permissions requires it' },
    'acl-set' => { path => 'SM1052: `paths`, a list of paths given the one rule, may be sent instead of path' },
    # SM696: brief-delete accepts the parts that CREATED the entry (type, table,
    # key) in place of a path; with neither it refuses.
    'brief-delete' => { path => 'SM696: the typed reference type=row&table&key may be sent instead of a path' },
    # SM911 LD2: layout-delete takes `layout=` and still takes `path`, which it
    # always took, so neither alone is required.
    'layout-delete' => { layout => 'SM911 LD2: `path` still works beside `layout`, so nothing that calls it changes' },
    # SM862: form-submissions takes `form` or `file`; exactly one is needed, and
    # the action answers for that by name.
    'form-submissions' => { form => 'SM862: `file`, the path to a store, may be sent instead of form; exactly one is needed' },
    # SM905 U5: for a form's upload keys, "false, 0, '' and absent all mean off".
    'form-uploads-save' => { uploads => 'SM905 U5: absent means off, as false and 0 do (action_form_uploads_save)' },
    # These two read the RAW request body (action_layout_install($body),
    # action_site_backup_apply($req)), which the extractor behind t/lint/58 cannot
    # see into, so each declares no parameters and cannot mark one required. The
    # handler refuses the absent value itself ('layout required', and
    # _package_name_refusal for an absent package name).
    'layout-install'    => { layout => 'the handler reads the raw body and refuses an absent layout itself; t/lint/58 cannot extract a declared parameter from it' },
    'site-backup-apply' => { name   => 'the handler reads the raw body and refuses an absent name itself (_package_name_refusal); t/lint/58 cannot extract a declared parameter from it' },
);

my %twin = Lazysite::ControlApi::Actions::mcp_twins();
cmp_ok( scalar keys %twin, '>=', 40, 'the declared twins were read' );

for my $a ( sort keys %twin ) {
    my $t = $twin{$a};
    ok( $mcp_required{$t}, "twin '$t' of '$a' is a parsed MCP tool" ) or next;
    my $spell = $SPELLED{$a} || {};
    my %api = map { ( $spell->{ $_->{name} } // $_->{name} ) => 1 }
        grep { $_->{required} } @{ $Lazysite::ControlApi::Actions::ACTION{$a}{params} || [] };
    my %mcp = %{ $mcp_required{$t} };
    my %diff = map { $_ => 1 } grep { !( $api{$_} && $mcp{$_} ) } keys %api, keys %mcp;
    my $rec = $DIFFERENCE{$a} || {};
    my @unrecorded = sort grep { !$rec->{$_} } keys %diff;
    is( "@unrecorded", '', "'$a' / '$t': required arguments agree" )
        or diag( join '', map {
            "  '$_' is required on the "
            . ( $api{$_} ? "control API but not MCP '$t'" : "MCP tool '$t' but not the control API action '$a'" )
            . "; make both require it or record the reason in \%DIFFERENCE\n"
        } @unrecorded );
    for my $arg ( sort keys %$rec ) {
        ok( $diff{$arg}, "recorded difference '$a'/'$arg' still differs - remove it when decided" );
    }
}
for my $a ( sort keys %DIFFERENCE ) {
    ok( $twin{$a}, "recorded difference names a real twin '$a'" );
}

done_testing();

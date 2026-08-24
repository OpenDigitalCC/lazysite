#!/usr/bin/perl
# SECURITY GUARANTEE (adversarial breadth, 2026-07): the reserved control tree
# (lazysite/auth secrets + hashes + ACLs + sessions, logs, cache, backups, the
# built-in templates, the manager chrome, lazysite.conf, form-config secrets)
# must be unwritable from every CONTENT channel. The guard itself is pinned by
# t/unit/manager/28-file-editor-confinement.t (is_blocked_path/validate_path);
# what THIS test pins is that every write channel actually ROUTES THROUGH a
# guard - the failure mode being a new handler or a new channel that writes a
# file without calling the guard, silently reopening the tree.
#
# Channels:
#   - control-API + MCP file writes -> the shared Lazysite::Manager::Files
#     action_* handlers, which each call validate_path + is_blocked_path;
#   - git-restore -> action_save (the same guarded path);
#   - WebDAV -> lazysite-dav.pl, which denies the whole lazysite/ subtree bar
#     the documented carve-outs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; <$fh> }

# Return the source of sub $name from $src (up to the next top-level 'sub ').
sub sub_body {
    my ( $src, $name ) = @_;
    return $1 if $src =~ /\nsub \Q$name\E\b(.*?)(?=\nsub \w)/s;
    return $1 if $src =~ /\nsub \Q$name\E\b(.*)/s;
    return '';
}

# --- 1. every file-mutating handler is CLASSIFIED, and the guarded ones guard --
#
# SM418: this list used to be five names in Files.pm, hand-maintained. The
# upload handler lives in Upload.pm, was never added, and shipped without
# validate_path - the traversal that let an upload overwrite the cookie-signing
# secret. A parity lint that enumerates proves only what somebody remembered to
# enumerate, which is the failure mode it exists to prevent, one level up.
#
# So it DISCOVERS instead. Every `action_*` handler in every Manager module
# whose body writes (open '>', rename, unlink, make_path) must appear in
# exactly one of the two registers below. A handler in neither FAILS THIS LINT
# until somebody classifies it - which is the point: adding a file-writing
# handler should require a decision about its path guard, not an omission.
#
# GUARDED: takes a caller-supplied content path, so it must call validate_path
# (which rejects `..`, collapses symlinks and yields the canonical rel the
# blocklist string-matches) and is_blocked_path.
my %GUARDED = map { $_ => 1 } qw(
    action_save action_save_binary action_delete action_mkdir action_move
    action_copy action_migrate_to_local action_file_upload
    action_brief_append
);

# EXEMPT: writes only to a location the ENGINE names, never a caller-supplied
# path - so validate_path has no request to validate. Each carries its reason,
# because "exempt" without one is indistinguishable from "forgotten".
my %EXEMPT = (
    # SM245: the migration enumerates sidecars from its own docroot walk and
    # writes store entries at paths IT derives - no caller-supplied path
    # exists to validate.
    action_briefs_migrate  => 'engine-walked sidecars into the engine-named store',
    action_backup_delete   => 'backups dir, name validated by _valid_name',
    action_backup_create   => 'backups dir, name minted by _claim_name',
    action_backup_restore  => 'extracts into the docroot; name validated, tar confined',
    action_git_show        => 'reads git objects; writes only a temp file it names',
    action_git_restore     => 'routes its write through action_save (asserted below)',
    action_layouts_install => 'layouts dir, name validated by the layout rules',
    action_layouts_release_contents     => 'layouts dir, engine-named paths',
    action_layout_install               => 'layouts dir, name validated',
    action_nav_save                     => 'the single fixed nav file',
    action_plugin_list                  => 'writes only its own listing cache',
    action_plugin_save                  => 'plugin config file named by the descriptor',
    action_form_targets_save            => 'forms dir, engine-named',
    action_form_submission_delete       => 'submission store, id validated',
    action_form_submission_confirm      => 'submission store, id validated',
    action_form_submissions_delete_bulk => 'submission store, ids validated',
    action_create_theme     => 'themes dir, name validated by the theme rules',
    action_theme_rename     => 'themes dir, both names validated',
    action_theme_upload     => 'themes dir, archive members validated on extract',
    action_cache_invalidate => 'render cache, engine-named paths',

    # SM470: the descriptor directory, one fixed place, and the NAME is the
    # only caller-chosen part - validated twice before it reaches a path
    # (explicitly here, and again by load_descriptor's _bad_ident, which is
    # what actually refuses a traversal). It cannot address the docroot at
    # all, so the content write guard has nothing to say about it.
    action_data_table_save => 'descriptor dir, name validated to [a-z][a-z0-9_]*',
);

{
    my @unclassified;
    for my $mod ( sort glob("$root/lib/Lazysite/Manager/*.pm") ) {
        my $src = slurp($mod);
        ( my $short = $mod ) =~ s{.*/}{};
        while ( $src =~ /\nsub (action_\w+)\b(.*?)(?=\nsub \w|\z)/gs ) {
            my ( $fn, $body ) = ( $1, $2 );

            # CODE, not the prose about it. The first version matched the word
            # "rename" inside a comment describing an atomic write and flagged
            # a read-only handler - a lint that reads commentary reports on
            # what the file SAYS rather than what it DOES, which is the exact
            # confusion this file exists to prevent.
            ( my $code = $body ) =~ s/^\s*#.*$//mg;
            next unless $code =~ /\b(?:rename|unlink|make_path)\b/
                || $code =~ m{open \s+ my \s+ \S+ \s* , \s* '>>?'}x;
            next if $EXEMPT{$fn};
            unless ( $GUARDED{$fn} ) {
                push @unclassified, "$short:$fn";
                next;
            }
            like( $code, qr/validate_path\(/,
                "$fn confines the path under the docroot (validate_path)" );
            like( $code, qr/is_blocked_path\(/,
                "$fn refuses the reserved lazysite/ tree (is_blocked_path)" );
        }
    }
    is_deeply( \@unclassified, [],
        'every file-writing action handler is classified guarded or exempt' )
        or diag( "Unclassified file-writing handler(s):\n  "
            . join( "\n  ", @unclassified )
            . "\n\nAdd each to %GUARDED (and make it call validate_path +"
            . " is_blocked_path) or to %EXEMPT with the reason it needs no"
            . " path guard. SM418 shipped because this list was hand-kept." );
}

# --- 2. git-restore writes through the guarded save path -----------------------
my $files = slurp("$root/lib/Lazysite/Manager/Files.pm");
like( sub_body( $files, 'action_git_restore' ), qr/action_save\(/,
    'git-restore routes its write through action_save (inherits the guard)' );

# --- 3. MCP: content writes go through the guarded handlers, not raw opens ------
my $mcp = slurp("$root/lazysite-mcp.pl");
like( $mcp, qr/use Lazysite::Manager::Files\b[^;]*\baction_save\b/s,
    'MCP imports the guarded action_save' );
like( $mcp, qr/use Lazysite::Manager::Files\b[^;]*\baction_delete\b/s,
    'MCP imports the guarded action_delete' );
# No raw write-open in the MCP server may target a user-supplied CONTENT path -
# those must go through action_save. (The only permitted raw writes are to fixed,
# name-validated control locations: a form .conf and a server-id'd feedback file.)
my @raw_writes = $mcp =~ /open\s+my\s+\$\w+\s*,\s*'>'\s*,\s*("[^"]*"|[^;]+?)\s*(?:or\b|;)/g;
my @content_bypass = grep { /->\{\s*(?:path|to|rel|rel_path)\s*\}/ } @raw_writes;
is( "@content_bypass", '',
    'no raw write-open in the MCP server builds its path from a user content path (writes route through action_save)' )
    or diag "raw MCP write targets a content path: @content_bypass";

# --- 4. WebDAV denies the whole lazysite/ subtree (bar documented carve-outs) ---
my $dav = slurp("$root/lazysite-dav.pl");
like( $dav,
    qr/if \(\s*\$rel eq 'lazysite'\s*\|\|\s*\$rel =~ m\{\^lazysite\/\}/,
    'WebDAV authorise gates the entire lazysite/ subtree' );
like( $dav, qr/only lazysite\/layouts\/ is writable over WebDAV/,
    'WebDAV write carve-out is limited to lazysite/layouts/ (auth/config/etc. stay denied)' );

done_testing;

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

# --- 1. every file-mutating handler calls the guard chain ----------------------
my $files = slurp("$root/lib/Lazysite/Manager/Files.pm");
for my $fn (qw(action_save action_delete action_mkdir action_move action_copy)) {
    my $body = sub_body( $files, $fn );
    ok( length $body, "Files.pm defines $fn" );
    like( $body, qr/validate_path\(/,
        "$fn confines the path under the docroot (validate_path)" );
    like( $body, qr/is_blocked_path\(/,
        "$fn refuses the reserved lazysite/ tree (is_blocked_path)" );
}

# --- 2. git-restore writes through the guarded save path -----------------------
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

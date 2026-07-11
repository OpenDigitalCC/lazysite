#!/usr/bin/perl
# Coverage: unsaved-changes guard on every explicit-save manager page (field
# report: the Nav editor silently lost unsaved changes on navigation). The
# SM118 settings pattern now lives as the shared mgDirtyGuard helper in the
# manager layout, and each explicit-save page registers with it. No browser
# automation exists in this suite, so these are static presence asserts on the
# page source (the 23-manager-read-actions.t idiom): the dirty-note markup,
# the guard registration/clearing and the mutation-path hooks must stay
# present, in lock-step with the JS.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($rel) = @_;
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $s = do { local $/; <$fh> };
    close $fh;
    return $s;
}

# --- the shared helper lives in the manager layout ---------------------------
{
    my $layout = slurp('starter/lazysite/manager/layout.tt');
    like( $layout, qr/window\.mgDirtyGuard/, 'layout: mgDirtyGuard helper present' );
    like( $layout, qr/addEventListener\('beforeunload'/,
        'layout: the single beforeunload guard is registered' );
}

# --- config.md (the SM118 reference) uses the shared helper ------------------
{
    my $page = slurp('starter/manager/config.md');
    like( $page, qr/id="site-dirty" class="mg-dirty-note"/, 'config: dirty-note markup present' );
    like( $page, qr/mgDirtyGuard\.set\('site-settings'/, 'config: registers dirty state' );
    like( $page, qr/mgDirtyGuard\.clear\('site-settings'/, 'config: clears dirty state on save' );
    unlike( $page, qr/addEventListener\('beforeunload'/,
        'config: no page-local beforeunload (shared guard only)' );
}

# --- nav.md: every mutation path marks dirty ---------------------------------
{
    my $page = slurp('starter/manager/nav.md');
    like( $page, qr/id="nav-dirty" class="mg-dirty-note"/, 'nav: dirty-note markup present' );
    like( $page, qr/mgDirtyGuard\.set\('nav'/,             'nav: registers dirty state' );

    # add / edit / indent / outdent / delete / drag-drop all mark dirty
    # (call sites only; the lookbehind excludes the function definition).
    my @marks = $page =~ /(?<!function )markNavDirty\(\)/g;
    cmp_ok( scalar @marks, '>=', 6,
        'nav: all six mutation paths (add/edit/indent/outdent/delete/drop) mark dirty' );

    # load (re-sync) and save success both clear it
    my @clears = $page =~ /(?<!function )clearNavDirty\(\)/g;
    cmp_ok( scalar @clears, '>=', 2, 'nav: load and save success clear dirty' );
}

# --- edit.md: shared guard + lock release decoupled from the prompt ----------
{
    my $page = slurp('starter/manager/edit.md');
    like( $page, qr/mgDirtyGuard\.set\('editor'/,   'editor: registers dirty state' );
    like( $page, qr/mgDirtyGuard\.clear\('editor'/, 'editor: clears dirty state on save' );
    like( $page, qr/addEventListener\('pagehide'/,
        'editor: lock release happens on pagehide (page really leaving)' );
    unlike( $page, qr/addEventListener\('beforeunload'/,
        'editor: no beforeunload lock release (cancelling the leave prompt keeps the lock)' );
}

# --- plugin-config.md: config forms, handler forms, form targets -------------
{
    my $page = slurp('starter/manager/plugin-config.md');
    like( $page, qr/class="mg-dirty-note"/, 'plugin-config: dirty-note markup present' );
    like( $page, qr/markPluginDirty/,       'plugin-config: config forms mark dirty' );
    like( $page, qr/markHandlerDirty/, 'plugin-config: handler add/edit forms mark dirty' );
    like( $page, qr/markTargetsDirty/, 'plugin-config: form targets mark dirty' );
    like( $page, qr/clearPluginDirty\(pluginId\)/,
        'plugin-config: config save success clears dirty (before the reload)' );
    like( $page, qr/mgDirtyGuard\.clear/, 'plugin-config: clears route to the shared guard' );
}

# --- appearance.md: the layouts-repo field ----------------------------------
{
    my $page = slurp('starter/manager/appearance.md');
    like( $page, qr/id="repo-dirty" class="mg-dirty-note"/, 'appearance: dirty-note markup present' );
    like( $page, qr/mgDirtyGuard\.set\('layouts-repo'/, 'appearance: registers dirty state' );
    like( $page, qr/mgDirtyGuard\.clear\('layouts-repo'/, 'appearance: clears dirty state on save' );
}

done_testing();

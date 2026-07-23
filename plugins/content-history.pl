#!/usr/bin/perl
# content-history.pl - the operator-facing surface for the content history
# (SM085; the enable/status half of the pair whose remote half is git-sync.pl).
#
# Field feedback (2026-07-11): the enable/status controls used to be a card on
# the Backups page, where they were lost - and content history is not a backup,
# it is the enabling of change logging. Its sibling git-sync already presents
# as a plugin, so the pair now lives coherently on the plugin surface. ONE
# switch: ticking the plugin on Plugin Manager runs the on_enable hook (git
# init + adoption commit), unticking runs on_disable (recording paused, every
# version kept) - no second Enable on the config page. Status / Enable /
# Pause on Plugin Config remain for inspection and recovery.
#
# The ENGINE is untouched. The write hooks stay keyed on the `git_history`
# conf key plus an initialised repo (lib/Lazysite/Git.pm), the Files page keeps
# its per-file History/Diff/Restore panels (hidden while disabled), and the
# manager-api git-* actions remain the control-API surface. This plugin drives
# exactly the machinery action_git_init drives: ENABLE writes the conf key
# through the manager's own _write_conf_key and takes the adoption commit via
# Lazysite::Git::init (idempotent - re-enabling reports "already enabled" and
# keeps every recorded version); STATUS reports enabled / initialised / git
# availability / the recorded version count in plain language.

use strict;
use warnings;
no warnings 'once';    # cross-module package vars (the Common docroot context,
                       # $Lazysite::Util::COMPONENT) are each set once here.
use JSON::PP qw(encode_json);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). Deferred to the action paths below via require - --describe
    # must answer even where the tree is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'content-history',
        name        => 'Content history',
        description => 'Every content change recorded as a version. With history '
            . 'enabled, every save (manager, WebDAV, or AI connector) becomes a '
            . 'recorded version, and each file gains a History panel on the Files '
            . 'page - view, diff and restore any version. The history covers the '
            . 'content plus lazysite.conf and nav.conf; it never includes secrets '
            . 'or personal data (accounts, form submissions, logs) nor generated '
            . 'caches, so it stays safe to sync to a private remote (the Remote '
            . 'sync plugin). Full-system backups on the Backups page remain the '
            . 'disaster-recovery mechanism for exactly what the history excludes.',
        version       => '1.0',
        config_file   => '',
        config_schema => [],
        actions       => [
            { id => 'status', label => 'Status' },
            # enable/disable are the toggle's lifecycle hooks (on_enable /
            # on_disable), hidden from the config page so there is never an
            # "Enable" button while it is already enabled - the Plugin-Manager
            # tick is the one switch.
            {
                id     => 'enable',
                label  => 'Enable content history',
                run    => 'action',
                hidden => JSON::PP::true(),
            },
            {
                id     => 'disable',
                label  => 'Pause recording',
                run    => 'action',
                hidden => JSON::PP::true(),
            },
        ],
        # Lifecycle: the Plugin-Manager toggle is the ONE switch. Enabling the
        # plugin enables recording (init + adoption commit); disabling pauses
        # it. Both hooks reference the actions above.
        on_enable  => 'enable',
        on_disable => 'disable',
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1 if $argv[$i] eq '--describe';
        $opt{scan}     = 1 if $argv[$i] eq '--scan';
        $opt{docroot}  = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
        $opt{action}   = $argv[ $i + 1 ] // '' if $argv[$i] eq '--action';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }

    require Lazysite::Util;
    require Lazysite::Git;
    $Lazysite::Util::COMPONENT = 'content-history';

    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $user    = $ENV{LAZYSITE_ACTING_USER} // 'operator';
    my $what    = $opt{scan} ? 'status' : ( $opt{action} // '' );

    my $result =
        $what eq 'status'    ? do_status($docroot)
        : $what eq 'enable'  ? do_enable( $docroot, $user )
        : $what eq 'disable' ? do_disable($docroot)
        :                      { ok => 0, error => 'Unknown action.' };
    print encode_json($result);
    return 0;
}

sub _bool { return $_[0] ? JSON::PP::true : JSON::PP::false }

# STATUS: the same facts action_git_status reports, plus the plain-language
# sentence the old Backups card rendered from them - and last-commit health:
# the engine leaves GIT_DIR/COMMIT_FAILED behind when a version could not be
# recorded (the save itself succeeds by design), so a currently-failing
# recorder is visible here without log-diving.
sub do_status {
    my ($docroot) = @_;
    return { ok => 0, error => 'No site directory given.' }
        unless defined $docroot && length $docroot && -d $docroot;

    # A REAL health probe (not just "is the conf key set"): it verifies the repo
    # actually exists and reads, and flags the masked failure where enabling wrote
    # the conf key but the git init never completed (a network-interrupted enable
    # that "looked enabled"). The verdict drives the message + a healthy flag.
    my $h       = Lazysite::Git::health($docroot);
    my $v       = $h->{verdict};
    my $commits = $h->{commits};
    my $s       = ( $commits == 1 ) ? '' : 's';

    my %message = (
        'no-git' => 'git is not installed on this host. Ask your system '
            . 'administrator to install the git package, then enable content history here.',
        'disabled' => 'Content history is not enabled. Enabling takes an initial snapshot '
            . 'of the current site and then records every save as a version.',
        'paused' => "Content history recording is switched off, but $commits earlier "
            . "version$s are kept. Re-enable here to resume recording.",
        'inconsistent' => 'Content history is switched ON in the configuration, but its '
            . 'repository is missing or unusable - the last attempt to enable it did not '
            . 'complete (e.g. a network-interrupted request), so nothing is being '
            . 'recorded. Re-enable it here, or run "lazysite check --fix" on the server, '
            . 'to repair it.',
        'degraded' => "Content history is enabled ($commits recorded version$s), but the "
            . 'last attempt to record a version FAILED or a stale lock is present, so '
            . 'recent changes may be missing. Run "lazysite check --fix" on the server; '
            . 'the next successful save clears this.',
        'ok' => "Content history is enabled and healthy: $commits recorded version$s. "
            . 'Each file has History, Diff and Restore on the Files page.',
    );

    return {
        ok               => 1,
        verdict          => $v,
        healthy          => _bool( $h->{healthy} ),
        enabled          => _bool( $v eq 'ok' || $v eq 'degraded' ),
        initialised      => _bool( $h->{initialised} ),
        git_available    => _bool( $h->{git_available} ),
        recording_failed => _bool( $h->{recording_failed} ),
        lock_present     => _bool( $h->{lock_present} ),
        commits          => $commits,
        message          => ( $message{$v} // 'Content history status is unknown.' ),
    };
}

# ENABLE: the git-init semantics - set the conf key, initialise the repo, take
# the adoption commit, report it. Idempotent: with a repo already initialised
# only the conf key is (re)written and the version count is reported.
sub do_enable {
    my ( $docroot, $user ) = @_;
    return { ok => 0, error => 'No site directory given.' }
        unless defined $docroot && length $docroot && -d $docroot;
    return { ok => 0,
        error => 'git is not installed on this host. Ask your system '
            . 'administrator to install the git package and try again.' }
        unless Lazysite::Git::git_available();

    # The conf key travels through the manager's own writer (permission hints
    # included) - the same code path action_git_init uses.
    require Lazysite::Manager::Common;
    Lazysite::Manager::Common->import('_write_conf_key');
    local $Lazysite::Manager::Common::DOCROOT = $docroot;
    _write_conf_key( 'git_history', 'enabled' )
        or return { ok => 0, error => 'Could not write lazysite.conf.' };
    Lazysite::Git::reset_cache();

    if ( Lazysite::Git::initialised($docroot) ) {
        return { ok => 1, already => 1,
            commits => Lazysite::Git::count_commits($docroot),
            message => 'Content history was already enabled. '
                . 'Every recorded version is kept.' };
    }
    my $r = Lazysite::Git::init( $docroot, $user );
    return $r unless $r->{ok};
    my $sha7 = substr( $r->{commit} // '', 0, 7 );
    Lazysite::Util::log_event( 'INFO', 'enable', 'content history enabled',
        commit => ( $r->{commit} // '' ), user => $user );
    return { ok => 1, commit => $r->{commit},
        commits => Lazysite::Git::count_commits($docroot),
        message => "Content history enabled (initial snapshot $sha7). "
            . 'Every save is now recorded as a version.' };
}

# DISABLE (the on_disable hook / Pause recording): recording stops, nothing
# is lost - the repo and every recorded version stay on disk, and re-enabling
# resumes on top of them (do_enable's already-initialised path).
sub do_disable {
    my ($docroot) = @_;
    return { ok => 0, error => 'No site directory given.' }
        unless defined $docroot && length $docroot && -d $docroot;

    require Lazysite::Manager::Common;
    Lazysite::Manager::Common->import('_write_conf_key');
    local $Lazysite::Manager::Common::DOCROOT = $docroot;

    unless ( Lazysite::Git::enabled($docroot) ) {
        return { ok => 1, already => 1,
            message => 'Content history was not recording.' };
    }
    _write_conf_key( 'git_history', 'disabled' )
        or return { ok => 0, error => 'Could not write lazysite.conf.' };
    Lazysite::Git::reset_cache();
    my $commits = Lazysite::Git::count_commits($docroot);
    Lazysite::Util::log_event( 'INFO', 'disable', 'content history paused',
        commits_kept => $commits );
    return { ok => 1, commits => $commits,
        message => "Content history paused - $commits recorded version"
            . ( $commits == 1 ? '' : 's' )
            . ' kept. Enable the plugin again to resume recording.' };
}

1;

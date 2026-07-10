#!/usr/bin/perl
# git-sync.pl - remote sync for the content history (SM085; the follow-up
# plugin to the git backend core in lib/Lazysite/Git.pm).
#
# Opt-in: enable on Plugin Manager, configure on Plugin Config (remote
# address, branch, access token). Two on-demand actions - PUSH (send the
# local history to the remote branch) and PULL (fetch and apply the remote's
# changes) - plus a Test connection probe (--scan). Collision handling
# without git vocabulary: a pull that fast-forwards just applies; when both
# sides changed, the operator sees the plain-language conflict list ("These
# pages changed in both places: ...") and re-runs pull with keep_mine or
# take_theirs (merge -X ours/theirs under the hood). A content safety
# snapshot (Backups machinery, prerestore kind) is taken before ANY apply
# that changes the worktree. Push never forces.
#
# CREDENTIALS - why the token cannot leak: the access token (https remotes)
# is never placed on a command line, never embedded in the remote URL and
# never written into the git config - remote.origin.url stores the clean,
# validated address only. At action time the token travels in the process
# environment (LAZYSITE_GIT_SYNC_TOKEN, visible only to the site's own uid)
# and git reads it through a transient GIT_ASKPASS helper written 0700
# under lazysite/git/ (never served) and removed after the action; the
# helper itself contains no secret - it echoes the env var. So the token is
# invisible to `ps` (argv stays clean), absent from every file a push or a
# leak could expose, and present only for the duration of the action.
# GIT_TERMINAL_PROMPT=0 and ssh BatchMode turn a missing credential into a
# clean failure instead of a hang. The token's at-rest home is
# lazysite/git-sync.conf (0660 via the password-field rule in plugin-save),
# which is ALSO excluded from the versioned set - enforced self-healingly
# before every sync - so the history that gets pushed can never carry it.
#
# All git invocations go through Lazysite::Git::run_git - list-form exec,
# no shell anywhere. The remote address is shape-validated first: https://,
# git@host:path or ssh:// only; javascript:/file:/arbitrary schemes and
# embedded userinfo are refused. LAZYSITE_GIT_SYNC_ALLOW_LOCAL is a test
# seam letting the unit tests use local bare repos as remotes; it can only
# be set by whoever starts the server process, never through the manager.

use strict;
use warnings;
no warnings 'once';    # cross-module package vars ($Lazysite::Util::COMPONENT,
                       # the Backups context, $File::Find::name) are each set or
                       # read once here - the warning is noise, not a typo.
use JSON::PP qw(encode_json);
use Fcntl    qw(O_WRONLY O_CREAT O_EXCL);

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
        id          => 'git-sync',
        name        => 'Remote sync',
        description => 'Keep a copy of the site content on a remote server. '
            . 'Push sends your changes, Pull fetches changes made elsewhere; '
            . 'needs Content history (Backups page) to be enabled. When both '
            . 'sides changed the same page you choose Keep mine or Take '
            . 'theirs, and a safety snapshot is taken first.',
        version       => '1.0',
        config_file   => 'lazysite/git-sync.conf',
        config_keys   => [qw(remote_url branch auth_token)],
        config_schema => [
            {
                key   => 'remote_url',
                label => 'Remote address',
                type  => 'text',
                note  => 'Where the remote copy lives: https://host/path or '
                    . 'git@host:path (ssh form). Nothing else is accepted.',
            },
            {
                key     => 'branch',
                label   => 'Branch',
                type    => 'text',
                default => 'main',
                note    => 'The name of the line of history on the remote. '
                    . 'Leave as main unless the remote says otherwise.',
            },
            {
                key   => 'auth_token',
                label => 'Access token',
                type  => 'password',
                note  => 'For https remotes: an access token from the hosting '
                    . 'service. Stored in the operator-only git-sync.conf; '
                    . 'never shown again. Leave blank to keep the current one.',
            },
        ],
        actions => [
            { id => 'test', label => 'Test connection' },
            { id => 'push', label => 'Push - send changes', run => 'action' },
            {
                id      => 'pull',
                label   => 'Pull - fetch changes',
                run     => 'action',
                choices => [
                    { id => 'keep_mine',   label => 'Keep mine' },
                    { id => 'take_theirs', label => 'Take theirs' },
                ],
            },
        ],
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
        $opt{choice}   = $argv[ $i + 1 ] // '' if $argv[$i] eq '--choice';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }

    require Lazysite::Util;
    require Lazysite::Git;
    $Lazysite::Util::COMPONENT = 'git-sync';

    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $user    = $ENV{LAZYSITE_ACTING_USER} // 'operator';
    my $what    = $opt{scan} ? 'test' : ( $opt{action} // '' );

    my $result;
    if ( $what eq 'test' || $what eq 'push' || $what eq 'pull' ) {
        $result = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 120;
            my $r =
                $what eq 'test'   ? do_test($docroot)
                : $what eq 'push' ? do_push( $docroot, $user )
                :                   do_pull( $docroot, $user, $opt{choice} );
            alarm 0;
            $r;
        };
        if ( !defined $result ) {
            my $err = $@ // '';
            Lazysite::Util::log_event( 'ERROR', $what, 'sync action failed',
                error => $err, user => $user );
            $result =
                $err eq "timeout\n"
                ? { ok => 0, error => 'The remote copy did not respond in time. Try again later.' }
                : { ok => 0, error => 'The operation failed. The server log has the technical detail.' };
        }
    }
    else {
        $result = { ok => 0, error => 'Unknown action.' };
    }
    print encode_json($result);
    return 0;
}

# --- config + validation ------------------------------------------------------

sub _conf {
    my ($docroot) = @_;
    my %conf;
    if ( open my $fh, '<:utf8', "$docroot/lazysite/git-sync.conf" ) {
        while ( my $line = <$fh> ) {
            next if $line =~ /^\s*#/;
            if ( $line =~ /^\s*([a-z_]+)\s*:\s*(.*?)\s*$/ ) { $conf{$1} = $2 }
        }
        close $fh;
    }
    $conf{branch} = 'main' unless defined $conf{branch} && length $conf{branch};
    return \%conf;
}

# The accepted remote-address shapes, and nothing else: https:// (no embedded
# userinfo - the token comes from the settings, never the URL), scp-style
# git@host:path, or ssh://. Everything else - javascript:, file:, data:, plain
# http, option-shaped strings, shell metacharacters - is refused before any
# git call sees it.
sub valid_remote_url {
    my ($url) = @_;
    return 0 unless defined $url && length $url;
    return 0 if $url =~ /[\s\0'"`;|&<>\\]/;
    return 1 if $url =~ m{\Ahttps:// [A-Za-z0-9][A-Za-z0-9.-]* (?::\d{1,5})? / [A-Za-z0-9._~/-]+ \z}x;
    return 1 if $url =~ m{\A [A-Za-z0-9._-]+ \@ [A-Za-z0-9][A-Za-z0-9.-]* : [A-Za-z0-9._~/-]+ \z}x;
    return 1
        if $url
        =~ m{\Assh:// (?:[A-Za-z0-9._-]+\@)? [A-Za-z0-9][A-Za-z0-9.-]* (?::\d{1,5})? / [A-Za-z0-9._~/-]+ \z}x;
    # Test seam: local bare repos as remotes (unit tests only - see header).
    return 1 if $ENV{LAZYSITE_GIT_SYNC_ALLOW_LOCAL} && $url =~ m{\A/[A-Za-z0-9._~/-]+\z};
    return 0;
}

sub _valid_branch {
    my ($b) = @_;
    return 0 unless defined $b && $b =~ m{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,100}\z};
    return 0 if $b =~ /\.\./;
    return 1;
}

# Everything every action needs before it may touch the network. Returns
# ( $conf, undef ) or ( undef, $refusal ).
sub _gate {
    my ($docroot) = @_;
    return ( undef, { ok => 0, error => 'No site directory given.' } )
        unless defined $docroot && length $docroot && -d $docroot;
    return ( undef,
        { ok => 0, error => 'The history feature is not installed on this host.' } )
        unless Lazysite::Git::git_available();
    return ( undef,
        { ok => 0,
            error => 'Content history is not enabled for this site. '
                . 'Enable it on the Backups page first.'
        }
    ) unless Lazysite::Git::enabled($docroot);
    my $conf = _conf($docroot);
    return ( undef,
        { ok => 0,
            error => 'No remote copy is configured. Set the remote address in '
                . "this plugin's settings and save."
        }
    ) unless length( $conf->{remote_url} // '' );
    return ( undef,
        { ok => 0,
            error => 'The remote address must look like https://host/path, '
                . 'git@host:path or ssh://host/path.'
        }
    ) unless valid_remote_url( $conf->{remote_url} );
    return ( undef,
        { ok => 0, error => 'The branch setting contains characters that are not allowed.' } )
        unless _valid_branch( $conf->{branch} );
    return ( $conf, undef );
}

# --- credentials (see the header for why this cannot leak) ---------------------

# The transient GIT_ASKPASS helper: 0700, under the never-served lazysite/git/,
# no secret inside - it answers git's username prompt with a placeholder and
# its password prompt with the token FROM THE ENVIRONMENT.
sub _write_askpass {
    my ($docroot) = @_;
    my $path = "$docroot/lazysite/git/sync-askpass.$$";
    unlink $path;
    sysopen my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0700 or return undef;
    print {$fh} "#!/bin/sh\n"
        . "# lazysite git-sync credential helper - transient, per action, no secret\n"
        . "# inside: the token travels in the environment, never on disk or argv.\n"
        . "case \"\$1\" in\n"
        . "  *sername*) printf '%s' \"\${LAZYSITE_GIT_SYNC_USER:-token}\" ;;\n"
        . "  *) printf '%s' \"\${LAZYSITE_GIT_SYNC_TOKEN:-}\" ;;\n"
        . "esac\n";
    close $fh or do { unlink $path; return undef };
    return $path;
}

# Run one git command against the remote with the credential environment in
# place and stderr captured (run_git lets it pass to the server log; the sync
# actions need it to explain failures in plain language).
sub _net_git {
    my ( $docroot, $conf, @args ) = @_;
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    local $ENV{GIT_SSH_COMMAND}     = 'ssh -oBatchMode=yes';
    local $ENV{GIT_ASKPASS};
    local $ENV{LAZYSITE_GIT_SYNC_TOKEN};
    my $helper;
    my $token = $conf->{auth_token} // '';
    if ( length $token ) {
        $helper = _write_askpass($docroot);
        return ( 0, undef, 'could not write the credential helper' )
            unless defined $helper;
        $ENV{GIT_ASKPASS}             = $helper;
        $ENV{LAZYSITE_GIT_SYNC_TOKEN} = $token;
    }
    my ( $ok, $out, $err ) = _run_git_capture( $docroot, @args );
    unlink $helper if defined $helper;
    return ( $ok, $out, $err );
}

sub _run_git_capture {
    my ( $docroot, @args ) = @_;
    my $errfile = Lazysite::Git::git_dir($docroot) . "/sync-stderr.$$";
    open my $saved, '>&', \*STDERR
        or return ( Lazysite::Git::run_git( $docroot, @args ), '' );
    my ( $ok, $out );
    if ( open STDERR, '>', $errfile ) {
        ( $ok, $out ) = Lazysite::Git::run_git( $docroot, @args );
        open STDERR, '>&', $saved or 1;
    }
    else {
        ( $ok, $out ) = Lazysite::Git::run_git( $docroot, @args );
    }
    close $saved;
    my $err = '';
    if ( open my $fh, '<', $errfile ) {
        local $/;
        $err = <$fh> // '';
        close $fh;
    }
    unlink $errfile;
    return ( $ok, $out, $err );
}

# Map git's stderr onto the operator's vocabulary. Never echoes the raw text -
# it may contain URLs; the full detail is in the server log.
sub _explain_failure {
    my ($err) = @_;
    $err //= '';
    return 'The remote copy refused the credentials. Check the access token in the settings.'
        if $err =~ /authentication[ ]failed | could[ ]not[ ]read[ ]username
            | invalid[ ]credentials | access[ ]denied | permission[ ]denied
            | http[ ]basic | 401 | 403/ix;
    return 'Could not reach the remote copy. Check the address and the network connection.'
        if $err =~ /could[ ]not[ ]resolve[ ]host | unable[ ]to[ ]access
            | connection[ ](?:refused|timed[ ]out|reset) | no[ ]route[ ]to[ ]host
            | failed[ ]to[ ]connect | network[ ]is[ ]unreachable
            | operation[ ]timed[ ]out/ix;
    return "The remote copy has changes you don't have yet. Use Pull to fetch them first."
        if $err =~ /fetch first|non-fast-forward|rejected|stale info/i;
    return 'The operation failed. The server log has the technical detail.';
}

sub _missing_remote_ref { return ( $_[0] // '' ) =~ /couldn.t find remote ref|remote branch .* not found/i }

# --- repo plumbing --------------------------------------------------------------

# Point origin at the (validated) address - git config, never a URL carrying
# a credential.
sub _set_remote {
    my ( $docroot, $url ) = @_;
    my ($has) = Lazysite::Git::run_git( $docroot, 'config', '--get', 'remote.origin.url' );
    my @cmd =
        $has
        ? ( 'remote', 'set-url', 'origin', $url )
        : ( 'remote', 'add', 'origin', $url );
    my ($ok) = Lazysite::Git::run_git( $docroot, @cmd );
    return $ok;
}

# The token file must never be pushable. init() excludes it for new repos;
# a repo initialised before this plugin existed self-heals here - the line is
# (re)added and an already-tracked copy is untracked - BEFORE any staging.
sub _ensure_conf_excluded {
    my ($docroot) = @_;
    my $exclude   = Lazysite::Git::git_dir($docroot) . '/info/exclude';
    my $text      = '';
    if ( open my $fh, '<', $exclude ) { local $/; $text = <$fh> // ''; close $fh }
    if ( $text !~ m{^/lazysite/git-sync\.conf$}m ) {
        if ( open my $fh, '>>', $exclude ) {
            print {$fh} "/lazysite/git-sync.conf\n";
            close $fh;
        }
    }
    my ( $tok, $tracked ) =
        Lazysite::Git::run_git( $docroot, 'ls-files', '--', 'lazysite/git-sync.conf' );
    if ( $tok && defined $tracked && $tracked =~ /\S/ ) {
        Lazysite::Git::run_git( $docroot, 'rm', '--cached', '-q', '--',
            'lazysite/git-sync.conf' );
        Lazysite::Git::run_git( $docroot, 'commit', '-q', '-m',
            'keep the sync settings out of the content history' );
    }
    return;
}

sub _count_range {
    my ( $docroot, $range ) = @_;
    my ( $ok, $out ) = Lazysite::Git::run_git( $docroot, 'rev-list', '--count', $range );
    return undef unless $ok && defined $out && $out =~ /(\d+)/;
    return $1 + 0;
}

sub _rev {
    my ( $docroot, $ref ) = @_;
    my ( $ok, $out ) = Lazysite::Git::run_git( $docroot, 'rev-parse', '--verify', $ref );
    return undef unless $ok && defined $out;
    chomp $out;
    return $out =~ /\A[0-9a-f]{40}\z/ ? $out : undef;
}

sub _changed_files {
    my ( $docroot, $from, $to ) = @_;
    my ( $ok, $out ) =
        Lazysite::Git::run_git( $docroot, 'diff', '--name-only', $from, $to );
    return () unless $ok && defined $out;
    return grep { length } split /\n/, $out;
}

# Fold any writes that happened outside the hooked save paths into the history
# so a sync always operates on the complete current site.
sub _capture_worktree {
    my ( $docroot, $user ) = @_;
    _ensure_conf_excluded($docroot);
    Lazysite::Git::commit_all( $docroot, $user, 'capture changes before sync' );
    return;
}

# --- the safety snapshot (Backups machinery, prerestore kind) --------------------

sub _snapshot {
    my ( $docroot, $user ) = @_;
    require Lazysite::Manager::Backups;
    local $Lazysite::Manager::Backups::DOCROOT      = $docroot;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$docroot/lazysite";
    local $Lazysite::Manager::Backups::auth_user    = $user;
    my $r = eval { Lazysite::Manager::Backups::action_backup_create('prerestore') };
    return ( ref $r eq 'HASH' && $r->{ok} ) ? $r->{name} : undef;
}

# --- post-apply: the worktree changed outside the save path ----------------------

# WHOLESALE cache invalidation, the same choice as backup restore: a pulled
# change can touch nav.conf or lazysite.conf, which affects every rendered
# page, so per-page precision buys nothing - drop every .html that is the
# render cache of a .md sibling plus the whole per-host tree; pages re-render
# on their next request. Then reindex the alias map for the changed .md files
# (their front matter was written outside the save path that normally indexes
# it).
sub _after_apply {
    my ( $docroot, $changed ) = @_;
    require File::Find;
    my $cleared = 0;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                return unless $p =~ /\.html\z/ && -f $p;
                return if index( $p, "$docroot/lazysite" ) == 0;
                ( my $src = $p ) =~ s/\.html\z/.md/;
                return unless -f $src;
                unlink $p and $cleared++;
            },
        },
        $docroot
    );
    Lazysite::Util::clear_host_cache($docroot);
    require Lazysite::Aliases;
    for my $rel ( @{$changed} ) {
        next unless $rel =~ /\.md\z/;
        next if index( $rel, 'lazysite/' ) == 0;
        if ( -f "$docroot/$rel" ) {
            my $content = '';
            if ( open my $fh, '<', "$docroot/$rel" ) { local $/; $content = <$fh> // ''; close $fh }
            eval { Lazysite::Aliases::index_page( $docroot, $rel, $content ) };
        }
        else {
            eval { Lazysite::Aliases::deindex_page( $docroot, $rel ) };
        }
    }
    return $cleared;
}

sub _pages_summary {
    my ($changed) = @_;
    my @pages = @{$changed};
    splice @pages, 200 if @pages > 200;
    return \@pages;
}

# --- actions ---------------------------------------------------------------------

# Test connection: ls-remote against the configured address (never mutates the
# repo), reporting reachable / signed-in / content-present in plain language.
sub do_test {
    my ($docroot) = @_;
    my ( $conf, $refusal ) = _gate($docroot);
    return $refusal if $refusal;
    my ( $ok, $out, $err ) = _net_git( $docroot, $conf, 'ls-remote',
        $conf->{remote_url}, "refs/heads/$conf->{branch}" );
    unless ($ok) {
        Lazysite::Util::log_event( 'INFO', 'test', 'sync connection test failed',
            error => _one_line($err) );
        return { ok => 0, reachable => 0, error => _explain_failure($err) };
    }
    my $exists = ( defined $out && $out =~ /\S/ ) ? 1 : 0;
    return {
        ok            => 1,
        reachable     => 1,
        auth_ok       => 1,
        branch_exists => $exists,
        message       => $exists
        ? 'Connection OK. The remote copy is reachable and its content is present.'
        : 'Connection OK, but the remote copy has nothing yet. '
            . 'Push will send your copy the first time.',
    };
}

# PUSH: send the local history to the remote. Refuses cleanly when the remote
# is ahead - never forces, never merges here; Pull owns combining.
sub do_push {
    my ( $docroot, $user )    = @_;
    my ( $conf,    $refusal ) = _gate($docroot);
    return $refusal if $refusal;
    _capture_worktree( $docroot, $user );
    _set_remote( $docroot, $conf->{remote_url} )
        or return { ok => 0, error => 'Could not record the remote address. '
            . 'The server log has the technical detail.' };

    my $branch = $conf->{branch};
    my ( $fok, undef, $ferr ) = _net_git( $docroot, $conf, 'fetch', 'origin', $branch );
    my $have_remote = $fok ? 1 : 0;
    if ( !$fok && !_missing_remote_ref($ferr) ) {
        Lazysite::Util::log_event( 'INFO', 'push', 'sync push failed at fetch',
            error => _one_line($ferr), user => $user );
        return { ok => 0, error => _explain_failure($ferr) };
    }

    my $ahead;
    if ($have_remote) {
        my $behind = _count_range( $docroot, 'HEAD..FETCH_HEAD' ) // 0;
        if ( $behind > 0 ) {
            return { ok => 0,
                error => "The remote copy has changes you don't have yet. "
                    . 'Use Pull to fetch them first.' };
        }
        $ahead = _count_range( $docroot, 'FETCH_HEAD..HEAD' ) // 0;
        if ( $ahead == 0 ) {
            return { ok => 1, pushed => 0,
                message => 'Already up to date. The remote copy matches yours.' };
        }
    }
    else {
        $ahead = _count_range( $docroot, 'HEAD' ) // 0;
    }

    my ( $pok, undef, $perr ) =
        _net_git( $docroot, $conf, 'push', 'origin', "HEAD:refs/heads/$branch" );
    unless ($pok) {
        Lazysite::Util::log_event( 'INFO', 'push', 'sync push failed',
            error => _one_line($perr), user => $user );
        return { ok => 0, error => _explain_failure($perr) };
    }
    Lazysite::Util::log_event( 'INFO', 'push', 'sync push succeeded',
        pushed => $ahead, user => $user );
    return { ok => 1, pushed => $ahead,
        message => "Pushed $ahead new change" . ( $ahead == 1 ? '' : 's' )
            . ' to the remote copy.' };
}

# PULL: fetch, then apply. Fast-forward applies straight away; when both sides
# changed, report the conflict list and wait for keep_mine / take_theirs. A
# safety snapshot precedes ANY apply.
sub do_pull {
    my ( $docroot, $user, $choice ) = @_;
    $choice = '' unless defined $choice;
    return { ok => 0, error => 'Unknown choice.' }
        if length $choice && $choice ne 'keep_mine' && $choice ne 'take_theirs';
    my ( $conf, $refusal ) = _gate($docroot);
    return $refusal if $refusal;
    _capture_worktree( $docroot, $user );
    _set_remote( $docroot, $conf->{remote_url} )
        or return { ok => 0, error => 'Could not record the remote address. '
            . 'The server log has the technical detail.' };

    my ( $fok, undef, $ferr ) =
        _net_git( $docroot, $conf, 'fetch', 'origin', $conf->{branch} );
    unless ($fok) {
        return { ok => 1, applied => 0,
            message => 'The remote copy has nothing yet. Nothing to fetch.' }
            if _missing_remote_ref($ferr);
        Lazysite::Util::log_event( 'INFO', 'pull', 'sync pull failed at fetch',
            error => _one_line($ferr), user => $user );
        return { ok => 0, error => _explain_failure($ferr) };
    }

    my $head   = _rev( $docroot, 'HEAD' );
    my $theirs = _rev( $docroot, 'FETCH_HEAD' );
    return { ok => 0, error => 'The operation failed. The server log has the technical detail.' }
        unless defined $head && defined $theirs;
    if ( $theirs eq $head ) {
        return { ok => 1, applied => 0,
            message => 'Up to date. There is nothing new on the remote copy.' };
    }
    my ( $mok, $mout ) = Lazysite::Git::run_git( $docroot, 'merge-base', 'HEAD', 'FETCH_HEAD' );
    unless ( $mok && defined $mout && $mout =~ /\A([0-9a-f]{40})/ ) {
        return { ok => 0,
            error => 'The remote copy does not share this site\'s history. '
                . 'Refusing to combine them - check the remote address.' };
    }
    my $base = $1;
    if ( $base eq $theirs ) {
        return { ok => 1, applied => 0,
            message => 'Up to date. There is nothing new on the remote copy.' };
    }

    if ( $base eq $head ) {
        # Their changes only: apply directly (still behind a snapshot - this
        # rewrites the worktree).
        my @changed = _changed_files( $docroot, 'HEAD', 'FETCH_HEAD' );
        my $snap    = _snapshot( $docroot, $user )
            or return { ok => 0,
            error => 'Stopped before fetching: a safety snapshot could not be created.' };
        my ( $aok, undef, $aerr ) =
            _run_git_capture( $docroot, 'merge', '--ff-only', 'FETCH_HEAD' );
        unless ($aok) {
            Lazysite::Util::log_event( 'WARN', 'pull', 'sync pull apply failed',
                error => _one_line($aerr), user => $user );
            return { ok => 0,
                error => 'Could not apply the changes. Your copy is unchanged; '
                    . "the safety snapshot $snap was kept." };
        }
        _after_apply( $docroot, \@changed );
        Lazysite::Util::log_event( 'INFO', 'pull', 'sync pull applied',
            applied => scalar @changed, snapshot => $snap, user => $user );
        return _applied_result( \@changed, $snap );
    }

    # Both sides changed. Without a choice: report only, touch nothing.
    my %mine = map       { $_ => 1 } _changed_files( $docroot, $base, 'HEAD' );
    my @both = sort grep { $mine{$_} } _changed_files( $docroot, $base, 'FETCH_HEAD' );
    unless ( length $choice ) {
        my $list = join ', ', @both;
        $list = 'none - different pages changed on each side' unless length $list;
        return {
            ok           => 1,
            needs_choice => 1,
            conflicts    => \@both,
            message      => "These pages changed in both places: $list. "
                . "Choose 'Keep mine' to keep your versions of those pages, or "
                . "'Take theirs' to use the remote copy's versions. Changes to "
                . 'other pages are combined either way.',
        };
    }

    my $snap = _snapshot( $docroot, $user )
        or return { ok => 0,
        error => 'Stopped before fetching: a safety snapshot could not be created.' };
    my $strategy = $choice eq 'keep_mine' ? 'ours'      : 'theirs';
    my $label    = $choice eq 'keep_mine' ? 'kept mine' : 'took theirs';
    local $ENV{GIT_AUTHOR_NAME}  = $user;
    local $ENV{GIT_AUTHOR_EMAIL} = "$user\@lazysite";
    my ( $cok, undef, $cerr ) = _run_git_capture( $docroot, 'merge', '--no-edit',
        '-X', $strategy, '-m', "apply changes from the remote copy ($label)",
        'FETCH_HEAD' );
    unless ($cok) {
        Lazysite::Git::run_git( $docroot, 'merge', '--abort' );
        Lazysite::Util::log_event( 'WARN', 'pull', 'sync pull combine failed',
            error => _one_line($cerr), choice => $choice, user => $user );
        return { ok => 0,
            error => 'Could not combine the changes automatically. Your copy is '
                . "unchanged; the safety snapshot $snap was kept." };
    }
    my @changed = _changed_files( $docroot, $head, 'HEAD' );
    _after_apply( $docroot, \@changed );
    Lazysite::Util::log_event( 'INFO', 'pull', 'sync pull combined',
        choice => $choice, applied => scalar @changed, snapshot => $snap,
        user   => $user );
    return _applied_result( \@changed, $snap );
}

sub _applied_result {
    my ( $changed, $snap ) = @_;
    my $n = scalar @{$changed};
    my $message =
        $n
        ? "$n change" . ( $n == 1 ? '' : 's' ) . ' applied from the remote copy.'
        : 'Combined with the remote copy. No pages changed on your side.';
    return { ok => 1, applied => $n, pages => _pages_summary($changed),
        snapshot => $snap, message => $message };
}

sub _one_line {
    my ($s) = @_;
    ( my $t = $s // '' ) =~ s/\s+/ /g;
    return substr $t, 0, 400;
}

1;

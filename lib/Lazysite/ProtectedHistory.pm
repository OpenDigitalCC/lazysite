package Lazysite::ProtectedHistory;

# SM1324 (ruling 50, T-16): HISTORY FOR A PROTECTED FOLDER, BY CHOICE.
#
# Protected content lives in the private store (SM286), outside the docroot the
# content history versions, so it has never had a history - by design: a history
# can be pushed to a remote, and this content is not meant to travel (SM683).
# The release manager ruled that a folder may opt in. A folder rule carrying
# `history: true` (set wherever the rule is set: the manager, the control API,
# MCP set_permissions, `lazysite acl set`) keeps a history of what is beneath it.
#
# WHERE IT LIVES - SM683's design, which this follows:
#
#   A SECOND REPOSITORY with its own object store, never a second work tree of
#   the public one: a shared object store would put protected content in the
#   public repository, which is the disclosure this avoids. Its work tree is the
#   private store and its git dir is <store>/lazysite/git - inside the store,
#   so outside the served tree with the store's own protection (02770, the
#   docroot's group), and at a name no content path can take, `lazysite/` being
#   the engine's reserved name in every tree. Git-sync never sees it: the sync
#   extension works the public repository only.
#
#   Only what a history rule covers is ever staged. There is no adoption of the
#   whole store and no commit_all: a folder that has not opted in is never read
#   into it.
#
# WHO READS IT - the same rule as the content: every reader resolves its target
# through the manager's _git_target, which applies the file's read rule, so a
# history never widens who may read. Restores go through action_save, so the
# write rule applies.
#
# WHEN IT RECORDS - when the site's content history is enabled AND the folder's
# rule says so. A site that pauses its history pauses this one too. Off by
# default: a site with no `history` on any rule never creates the repository.

use strict;
use warnings;
use Lazysite::Git     ();
use Lazysite::Private ();
use Lazysite::Util    qw(log_event);

# The reserved engine name inside the store. Not the site's engine tree (that
# is Lazysite::Paths's question): the store has none, and this name is the one
# no content path can take.
sub _store_engine_dir { my ($root) = @_; return "$root/lazysite" }

sub _git_dir_in { return _store_engine_dir( $_[0] ) . '/git' }

# The private store root, registered with Lazysite::Git so its plumbing reads
# and writes this repository. undef when the docroot has no store name.
sub root {
    my ($docroot) = @_;
    my $root = Lazysite::Private::private_root($docroot) or return undef;
    Lazysite::Git::register_repo( $root, _git_dir_in($root) )
        unless exists $Lazysite::Git::REPO{$root};
    return $root;
}

sub initialised {
    my ($docroot) = @_;
    my $root = root($docroot) or return 0;
    return Lazysite::Git::initialised($root);
}

# The folder rule keeping history for this path, or undef.
sub kept_by {
    my ( $docroot, $rel ) = @_;
    require Lazysite::Auth::Acl;
    return Lazysite::Auth::Acl::history_key( $docroot, $rel );
}

# Is history being RECORDED for this path now: the site's history is on and a
# folder rule keeps it.
sub recording {
    my ( $docroot, $rel ) = @_;
    return 0 unless Lazysite::Git::enabled($docroot);
    return defined kept_by( $docroot, $rel ) ? 1 : 0;
}

# Create the repository: the store's permissions, an exclude list that keeps the
# engine name out, and an empty first commit - nothing is adopted. Returns the
# root, or undef when it could not be made (logged).
sub ensure {
    my ( $docroot, $user ) = @_;
    my $root = root($docroot) or return undef;
    return $root if Lazysite::Git::initialised($root);
    return undef unless Lazysite::Git::git_available();
    Lazysite::Private::ensure_store($docroot) or return undef;

    my $engine = _store_engine_dir($root);
    mkdir $engine unless -d $engine;
    return undef  unless -d $engine;
    chmod 02770, $engine;

    my $gd    = _git_dir_in($root);
    my ($iok) = Lazysite::Git::run_git( $root, '-c', 'init.defaultBranch=main', 'init', '-q',
        '--shared=group' );
    return undef unless $iok && -d $gd;
    Lazysite::Git::run_git( $root, 'config', 'core.worktree',         $root );
    Lazysite::Git::run_git( $root, 'config', 'core.sharedRepository', 'group' );
    chmod 02770, $gd;

    if ( open my $ex, '>', "$gd/info/exclude" ) {
        print {$ex} "# lazysite protected-folder history (SM1324). Only what a\n";
        print {$ex} "# folder rule keeps history for is staged; this is the backstop.\n";
        print {$ex} "/lazysite/\n";
        close $ex;
        chmod 0664, "$gd/info/exclude";
    }
    my ($cok) = Lazysite::Git::run_git( $root, 'commit', '-q', '--allow-empty',
        '-m', 'history kept for protected folders', '--author', Lazysite::Git::author_for($user) );
    return undef unless $cok;
    chmod 0664, "$gd/COMMIT_EDITMSG";
    delete $Lazysite::Git::ENABLED_CACHE{$root};
    log_event( 'INFO', 'git', 'protected-folder history initialised', user => ( $user // '' ) );
    return $root;
}

# The write hook (Lazysite::Git::commit_paths / commit_move): commit the paths a
# history rule covers, as one commit. A move whose source was kept too carries
# the rename trailer, so the history follows the file; one from elsewhere starts
# its history at the destination.
sub record {
    my ( $docroot, $user, $message, $from, @specs ) = @_;
    return 0 unless Lazysite::Git::enabled($docroot);
    my @keep = grep { defined kept_by( $docroot, $_ ) } @specs;
    return 0 unless @keep;
    my $root = ensure( $docroot, $user ) or return 0;
    my $tr   = ( defined $from && defined kept_by( $docroot, $from ) )
        ? ["Lazysite-Renamed-From:$from"] : undef;
    return Lazysite::Git::commit_specs( $root, $user, $message, $tr, @keep );
}

# The first version of a folder that has just opted in: what is in it now, less
# whatever a nested rule says `history: false` for (ruling 100). Each file is
# asked the question the recording hook asks (Acl::history_key_in), so a page
# whose stem rule says no is left out exactly as its later edits are. One commit.
# Returns 1 when a commit was made.
sub baseline {
    my ( $docroot, $user, $key ) = @_;
    return 0 unless Lazysite::Git::enabled($docroot);
    ( my $folder = $key // '' ) =~ s{\A/+|/+\z}{}g;
    return 0 unless length $folder;
    my $root = ensure( $docroot, $user ) or return 0;
    return 0 unless -d "$root/$folder";

    require Lazysite::Auth::Acl;
    my $map = Lazysite::Auth::Acl::load_acls();
    my @keep;
    {
        no warnings 'once';    # File::Find's own variables
        require File::Find;
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    my $p = $File::Find::name;
                    return if -l $p || !-f _;
                    ( my $rel = $p ) =~ s{\A\Q$root\E/}{};
                    push @keep, $rel if defined Lazysite::Auth::Acl::history_key_in( $map, $rel );
                },
            },
            "$root/$folder"
        );
    }
    return 0 unless @keep;
    my $made = eval {
        # In batches, so a large folder stays inside the argument limit.
        my @todo = sort @keep;
        while ( my @batch = splice @todo, 0, 500 ) {
            my ($aok) = Lazysite::Git::run_git( $root, 'add', '--', @batch );
            die "git add failed for $folder\n" unless $aok;
        }
        my ($clean) = Lazysite::Git::run_git( $root, 'diff', '--cached', '--quiet' );
        return 0 if $clean;
        my ($cok) = Lazysite::Git::run_git( $root, 'commit', '-q', '-m',
            Lazysite::Git::commit_text("keep history for $folder"),
            '--author', Lazysite::Git::author_for($user) );
        die "git commit failed\n" unless $cok;
        chmod 0664, Lazysite::Git::git_dir($root) . '/COMMIT_EDITMSG';
        1;
    };
    unless ( defined $made ) {
        log_event( 'WARN', 'git', 'protected-folder history: the first version was not recorded',
            folder => $folder, error => ( $@ // 'unknown' ), user => ( $user // '' ) );
        return 0;
    }
    return $made;
}

# SM1324 (ruling 99): DELETE A FOLDER'S RECORDED HISTORY. Clearing the flag or
# removing the rule keeps what was recorded; this is the one way to remove it,
# and the caller (`lazysite acl purge-history`) lets only the operator ask and
# audits it. The history is rewritten without the folder - every commit
# replayed on a scratch index with the folder taken out, a commit left empty
# dropped, authors, dates and messages kept - then the old objects are expired
# and pruned, so the bytes leave the object store and not merely the log. The
# files in the store are not touched. Returns { ok, folder, versions, dropped }.
sub purge {
    my ( $docroot, $key ) = @_;
    ( my $folder = $key // '' ) =~ s{\A/+|/+\z}{}g;
    return { ok => 0, kind => 'invalid', error => 'Name the folder whose history is to be deleted.' }
        unless length $folder
        && $folder !~ /\0/
        && $folder !~ /\A-/
        && !grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split m{/}, $folder;
    my $root = root($docroot)
        or return { ok => 0, kind => 'invalid', error => 'This site has no private store.' };
    return { ok => 1, folder => "/$folder", versions => 0, dropped => 0 }
        unless Lazysite::Git::initialised($root);

    my ( undef, $count ) = Lazysite::Git::run_git( $root, 'rev-list', '--count', 'HEAD', '--', $folder );
    my $versions = ( ( $count // '' ) =~ /(\d+)/ ) ? $1 + 0 : 0;
    return { ok => 1, folder => "/$folder", versions => 0, dropped => 0 } unless $versions;

    my ( $lok, $list ) = Lazysite::Git::run_git( $root, 'rev-list', '--reverse', 'HEAD' );
    return { ok => 0, error => 'The history could not be read; nothing was deleted.' } unless $lok;
    my $index = Lazysite::Git::git_dir($root) . "/purge-index.$$";
    my ( $parent, $parent_tree, $dropped ) = ( undef, undef, 0 );
    my $done = eval {
        for my $c ( grep { /\A[0-9a-f]{40}\z/ } split /\n/, $list ) {
            local $ENV{GIT_INDEX_FILE} = $index;
            my ($rok) = Lazysite::Git::run_git( $root, 'read-tree', $c );
            die "read-tree $c\n" unless $rok;
            Lazysite::Git::run_git( $root, 'rm', '-r', '--cached', '-q', '--ignore-unmatch', '--', $folder );
            my ( $wok, $tree ) = Lazysite::Git::run_git( $root, 'write-tree' );
            die "write-tree $c\n" unless $wok && defined $tree;
            chomp $tree;
            if ( defined $parent && $tree eq $parent_tree ) { $dropped++; next }
            my ( undef, $meta ) = Lazysite::Git::run_git( $root, 'log', '-1',
                '--format=%an%x00%ae%x00%aD%x00%cn%x00%ce%x00%cD%x00%B', $c );
            my ( $an, $ae, $ad, $cn, $ce, $cd, $msg ) = split /\0/, ( $meta // '' ), 7;
            local @ENV{ qw(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
                    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE) }
                = ( $an, $ae, $ad, $cn, $ce, $cd );
            my ( $cok, $new ) = Lazysite::Git::run_git( $root, 'commit-tree', $tree,
                ( defined $parent ? ( '-p', $parent ) : () ), '-m', ( $msg // '' ) );
            die "commit-tree $c\n" unless $cok && defined $new;
            chomp $new;
            ( $parent, $parent_tree ) = ( $new, $tree );
        }
        die "nothing replayed\n" unless defined $parent;
        my ($uok) = Lazysite::Git::run_git( $root, 'update-ref', 'HEAD', $parent );
        die "update-ref\n" unless $uok;
        1;
    };
    unlink $index;
    unless ($done) {
        log_event( 'WARN', 'git', 'protected history purge failed; the history is unchanged',
            folder => $folder, error => ( $@ // 'unknown' ) );
        return { ok => 0, error => 'The history could not be rewritten; nothing was deleted.' };
    }
    # The real index first: it names the folder's last recorded blobs, and gc
    # keeps whatever an index names.
    Lazysite::Git::run_git( $root, 'read-tree', 'HEAD' );
    Lazysite::Git::run_git( $root, 'reflog',    'expire', '--expire=now', '--all' );
    Lazysite::Git::run_git( $root, 'gc',        '-q',     '--prune=now' );
    log_event( 'INFO', 'git', 'protected history purged', folder => $folder, versions => $versions );
    return { ok => 1, folder => "/$folder", versions => $versions, dropped => $dropped };
}

1;

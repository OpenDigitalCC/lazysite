package Lazysite::Private;

# SM286 step 1: the private content store - a tree OUTSIDE the document root
# holding content that is gated, so no front end can serve it whatever its
# configuration says.
#
# WHY THIS EXISTS. Three defects in three releases (SM248, SM268 H17, SM283)
# were one cause: security living in front-end configuration that lazysite ships
# as templates, cannot test where it is installed, and on most deployments
# cannot even see. SM283 was live across a fleet for weeks - a protected section
# gating its pages and serving its images, PDFs and archives to anyone who knew
# the path, because Hestia's nginx answered by file extension before Apache saw
# the request.
#
# Every fix so far has been "put the rule in one more config file". This is the
# other answer: if the bytes are not in a directory any front end serves, no
# front-end rule is needed and none can be got wrong. It makes SM283
# structurally impossible rather than fixed once per deployment shape.
#
# WHERE. A sibling of the docroot, not a subdirectory of it - a subdirectory is
# exactly what the front end serves. The docroot's parent already holds engine
# files on the Hestia layout (tools/, lazysite-log.pl), so this follows an
# established convention rather than inventing a location.
#
# THE INVARIANT, and it is the whole point: a path is in EXACTLY ONE tree. A
# copy left in the docroot is the very exposure this removes, so a move that
# cannot complete leaves the content where it was and reports failure - it never
# leaves both.

use strict;
use warnings;
# make_path is deliberately NOT imported: it CROAKS, and an unqualified call is
# how SM296 happened. _mkpath below is the only way this module creates a
# directory, and it returns.
use File::Path     qw(remove_tree);
use File::Basename qw(dirname basename);
use File::Copy     qw(copy);
use Cwd            qw(realpath);
use Errno          qw(EXDEV);
use Exporter 'import';

our @EXPORT_OK = qw(private_root private_path resolve resolve_for_write
    is_private move_in move_out stray_public count_private);

# The store's directory name. A leading dot would hide it from an operator
# looking at the tree, and the point is that they can see where their private
# content went.
our $DIRNAME = 'lazysite-private';

# The store is named for the docroot it shadows, NOT a fixed name in the parent.
#
# A fixed "<parent>/lazysite-private" is shared by every docroot with the same
# parent. Two sites side by side - /srv/sites/a and /srv/sites/b, which is what
# the dev server invites and what a container image tends to look like - would
# then share ONE private store, and each would resolve the other's protected
# content by path. Two sites' members-only content silently merged is a worse
# disclosure than the one this store exists to remove.
#
# It was not a hypothetical: every test using a bare tempdir() as its docroot had
# a parent of /tmp, so the whole suite shared /tmp/lazysite-private and files
# from one test file appeared in another. That is the same defect, found the easy
# way.
#
# Deriving the name from the docroot makes collision impossible: two docroots
# with the same parent have different basenames, or they are the same directory.
sub private_root {
    my ($docroot) = @_;
    return undef unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};
    return undef unless length $docroot;
    return dirname($docroot) . '/' . basename($docroot) . "-$DIRNAME";
}

sub private_path {
    my ( $docroot, $rel ) = @_;
    my $root = private_root($docroot) or return undef;
    $rel = '' unless defined $rel;
    $rel =~ s{\A/+}{};
    return length $rel ? "$root/$rel" : $root;
}

# Where does this path actually live? Returns ( $abs, $where ) with $where being
# 'private', 'public' or '' (nowhere).
#
# PRIVATE WINS when both exist. That is not a preference, it is the fail-safe
# direction: if a stray public copy is left behind, the front end can already
# serve it, and having the engine ALSO serve the public one would hide the fault
# from every check that compares them. Preferring private means the engine
# serves the governed copy while stray_public() can still report the leak.
sub resolve {
    my ( $docroot, $rel ) = @_;
    return ( undef, '' ) unless defined $rel && length $rel;
    $rel =~ s{\A/+}{};

    my $priv = private_path( $docroot, $rel );
    return ( $priv, 'private' ) if defined $priv && -e $priv;

    my $pub = "$docroot/$rel";
    return ( $pub, 'public' ) if -e $pub;

    return ( undef, '' );
}

sub is_private {
    my ( $docroot, $rel )   = @_;
    my ( undef,    $where ) = resolve( $docroot, $rel );
    return $where eq 'private' ? 1 : 0;
}

# Where a path should be WRITTEN, which is not the same question as where it is.
#
# Existing content keeps its home. A NEW path inherits the tree of its nearest
# existing ancestor - so a file created inside a gated folder is created
# PRIVATELY. Without that rule a naive save recreates a public copy of a section
# that was moved out: the folder does not exist in the docroot, mkdir -p makes
# it, and the section is half-published by an operation nobody thought of as a
# permission change. That is the "one write choke point" the filing asks for,
# expressed as a resolution rule rather than a check every caller must remember.
sub resolve_for_write {
    my ( $docroot, $rel ) = @_;
    return ( undef, '' ) unless defined $rel && length $rel;
    $rel =~ s{\A/+}{};

    my ( $abs, $where ) = resolve( $docroot, $rel );
    return ( $abs, $where ) if $where;

    # An ancestor that exists in the DOCROOT settles it as public, and is checked
    # FIRST - a directory existing in the store is not on its own evidence that
    # the folder is gated.
    #
    # Moving a single FILE into the store creates its parent directories there
    # too. Using resolve() here, that bare container made the folder look
    # private, so protecting one file in `content/` silently caused every file
    # created in `content/` afterwards to be written privately - unpublishing new
    # public content through an operation nobody thinks of as a permission
    # change, which is the exact failure this function was written to prevent,
    # pointed the other way.
    #
    # The distinction is structural and needs no ACL lookup: a genuinely gated
    # folder was MOVED, so it does not exist in the docroot at all. A folder in
    # both trees is a public folder that happens to hold some private files.
    my @parts = split m{/}, $rel;
    pop @parts;    # the path itself does not exist; start at its parent
    while (@parts) {
        my $anc = join( '/', @parts );
        last if -e "$docroot/$anc";    # a public ancestor settles it

        my $priv_anc = private_path( $docroot, $anc );
        return ( private_path( $docroot, $rel ), 'private' )
            if defined $priv_anc && -e $priv_anc;

        pop @parts;
    }
    return ( "$docroot/$rel", 'public' );
}

# A path that exists in BOTH trees. Always a fault: the private copy is the one
# the engine governs and the public one is reachable without asking it. Surfaced
# rather than silently repaired, because deleting content is not a repair a tool
# should decide on its own.
sub stray_public {
    my ( $docroot, $rel ) = @_;
    return 0 unless defined $rel && length $rel;
    $rel =~ s{\A/+}{};
    my $priv = private_path( $docroot, $rel );
    return ( defined $priv && -e $priv && -e "$docroot/$rel" ) ? 1 : 0;
}

# Count the regular files held in the store under a relative prefix ('' or undef
# = the whole store). Directories and symlinks are not counted; the question this
# answers is always "how much CONTENT is in there", asked by something that is
# about to tell an operator a number.
#
# SM286: exists so that code which cannot carry private content has to state how
# much it left behind. A silent omission is the failure mode this whole work item
# is about, and a caller with no way to count is a caller that will stay silent.
sub count_private {
    my ( $docroot, $rel ) = @_;
    my $base = private_path( $docroot, $rel );
    return 0 unless defined $base && -d $base;
    require File::Find;
    my $n = 0;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                return if -l $p;    # never follow a link out of the store
                $n++   if -f $p;
            },
        },
        $base
    );
    return $n;
}

# make_path that RETURNS rather than dies.
#
# SM296: `make_path($parent) unless -d $parent` looks like it reports failure by
# returning false. It does not - File::Path::make_path CROAKS. So the guard on
# the very next line ("cannot create the private store") was unreachable, and an
# unwritable parent threw straight out through action_acl_set and killed the CGI.
#
# What that cost, live on 0.10.8: the ACL is saved BEFORE the move, so the rule
# was stored and honoured for pages while the content stayed in the document
# root and kept being served - SM283's exposure, reached through the mechanism
# built to make it impossible. The caller saw "Tool error"; the audit line was
# never written, because the process died before it. The documented warning for
# exactly this case existed and could not be reached.
#
# Both callers already handle a false return correctly. They only ever needed
# the failure to BE a return.
sub _mkpath {
    my ($dir) = @_;
    return 1 if -d $dir;
    my $err;
    File::Path::make_path( $dir, { error => \$err } );
    return -d $dir ? 1 : 0;
}

# Confinement: never let a caller's path escape either tree. Both roots are
# resolved with realpath so a symlink cannot be used to write outside.
sub _within {
    my ( $root, $abs ) = @_;
    return 0 unless defined $root && defined $abs;
    my $rroot = realpath($root)           or return 0;
    my $rabs  = realpath( dirname($abs) ) or return 0;
    return ( $rabs eq $rroot || index( $rabs, "$rroot/" ) == 0 ) ? 1 : 0;
}

# SM307: say why the rename failed, having checked.
#
# This reported one of two causes and determined NEITHER. On the host where it
# was found both were wrong, and the correct diagnosis was available two layers
# away in the same codebase - the WebDAV layer, on the same docroot, minutes
# apart, said "the target directory is not writable by the server. This is a
# server configuration fault, rather than a permission decision about your
# request - the operator must fix the directory permissions", which was exactly
# right. The ACL path said "cannot move a folder across filesystems".
#
# The old comment was honest about the uncertainty - "Cross-device, or a rename
# the filesystem refused" - and the message below it dropped the second half and
# stated the first as fact. rename() sets $!, so the distinction the comment
# already drew was one branch away from being made.
#
# The wrong diagnosis is expensive: mount layout is not something an operator
# changes casually, and on the Hestia layout the store sits in the domain folder
# beside public_html, which looks like somewhere a separate mount could
# plausibly be. The suggested cause is credible enough to be investigated, and
# the real fix was a chown.
#
# Worse, it CONTRADICTED a check that shipped alongside it: SM296 added a
# `lazysite check` report on whether the store exists, is writable, or could be
# created, naming the directory, its owner and its mode. On a host where the
# docroot is not writable that check answers correctly while this blamed the
# filesystem layout - two parts of one release giving an operator different
# accounts of one fault, and the wrong one returned at the moment they act.
#
# Both directions share this so a single condition cannot be described two ways
# depending on which way the content was going.
sub _move_failure {
    my ( $src, $dst, $is_dir ) = @_;
    my $errno = $!;

    # A genuine cross-device move of a DIRECTORY is the one case the original
    # message described correctly. Name both locations, because the operator's
    # next question is which two filesystems.
    if ( $errno == EXDEV && $is_dir ) {
        return "cannot move a folder across filesystems: \"$src\" and \"$dst\" "
            . 'are on different mounts, and moving a folder between them '
            . 'cannot be done in one atomic step. Protecting a section refuses '
            . 'rather than copy-then-delete, because a partial copy would leave '
            . 'half a section public.';
    }

    # Everything else. Borrow the shape of the WebDAV wording, which separates a
    # server configuration fault from a decision about the request - the ACL
    # path has MORE need of that distinction, because its failure leaves content
    # served while the rule reads as applied.
    return "could not move \"$src\" into place: $errno. This is a server "
        . 'configuration fault rather than a permission decision about your '
        . 'request - `lazysite check` reports the private store\'s directory, '
        . 'owner and mode, and `lazysite check --fix` repairs a docroot that '
        . 'came back from a control-panel rebuild without group write.';
}

# Move public -> private. Returns ( $ok, $error ).
#
# rename() is atomic within a filesystem and moves a whole directory in one
# step, which is what makes protecting a section safe: there is no window in
# which half a section is public. Across filesystems it fails with EXDEV, and
# for a FILE the fallback copies, VERIFIES, and only then removes the original -
# so an interrupted copy leaves the content public and reports failure, rather
# than leaving it half-moved and unreadable.
#
# SM307: THE FALLBACK COVERS FILES ONLY. A directory stops at the -d guard below
# and is refused, deliberately - a recursive copy-then-delete would reintroduce
# exactly the window that rename() exists to close, on the operation whose whole
# purpose is to close it. Since a folder ACL is the normal way to protect a
# section, the fallback is unreachable in the common case, and the comment above
# used to describe it as though it were general.
sub move_in {
    my ( $docroot, $rel ) = @_;
    $rel = '' unless defined $rel;
    $rel =~ s{\A/+}{};
    return ( 0, 'no path given' ) unless length $rel;

    my $src = "$docroot/$rel";
    return ( 1, undef ) unless -e $src;    # nothing to move is not a failure

    my $dst = private_path( $docroot, $rel );
    return ( 0, 'cannot resolve the private store' ) unless defined $dst;

    my $parent = dirname($dst);
    _mkpath($parent);

    # SM307: whatever the store cannot do, a file and a folder describe it the
    # same way. This branch is where a SINGLE FILE failed on the host that
    # prompted the filing, producing "cannot create the private store" for the
    # very condition a folder reported as a cross-filesystem move - one fault,
    # two messages, neither naming the cause.
    return ( 0, "cannot create the private store at \"$parent\": $!. This is a "
            . 'server configuration fault rather than a permission decision '
            . 'about your request - `lazysite check` reports the store\'s '
            . 'directory, owner and mode, and `lazysite check --fix` repairs a '
            . 'docroot that came back from a control-panel rebuild without '
            . 'group write.' )
        unless -d $parent;
    return ( 0, 'refusing a path outside the private store' )
        unless _within( private_root($docroot), $dst );

    # An existing destination means a previous move left something behind. Do
    # not overwrite it silently - that would destroy the governed copy in
    # favour of one the front end has been serving.
    return ( 0, 'the private store already holds this path' ) if -e $dst;

    return ( 1, undef ) if rename $src, $dst;

    return ( 0, _move_failure( $src, $dst, 1 ) ) if -d $src;
    return ( 0, _move_failure( $src, $dst, 0 ) ) unless copy( $src, $dst );
    unless ( -s $dst == -s $src ) {
        unlink $dst;
        return ( 0, 'the copy did not match the original; nothing was moved' );
    }
    unlink $src or return ( 0, 'the copy landed but the original could not be '
            . 'removed - the content is still public' );
    return ( 1, undef );
}

# Move private -> public, for un-protecting. Same contract in reverse.
sub move_out {
    my ( $docroot, $rel ) = @_;
    $rel = '' unless defined $rel;
    $rel =~ s{\A/+}{};
    return ( 0, 'no path given' ) unless length $rel;

    my $src = private_path( $docroot, $rel );
    return ( 1, undef ) unless defined $src && -e $src;

    my $dst = "$docroot/$rel";
    return ( 0, 'the docroot already holds this path' ) if -e $dst;

    my $parent = dirname($dst);
    _mkpath($parent);
    return ( 0, 'cannot create the destination folder' ) unless -d $parent;
    return ( 0, 'refusing a path outside the docroot' )
        unless _within( $docroot, $dst );

    return ( 1, undef ) if rename $src, $dst;

    # SM307: the same reporter as move_in. Un-protecting used to misreport the
    # identical condition in the identical way, so an operator hitting one fault
    # from two directions got two different accounts of it.
    return ( 0, _move_failure( $src, $dst, 1 ) ) if -d $src;
    return ( 0, _move_failure( $src, $dst, 0 ) ) unless copy( $src, $dst );
    unless ( -s $dst == -s $src ) {
        unlink $dst;
        return ( 0, 'the copy did not match the original; nothing was moved' );
    }
    unlink $src or return ( 0, 'the copy landed but the private original could '
            . 'not be removed' );
    return ( 1, undef );
}

1;

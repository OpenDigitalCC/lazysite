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
use File::Path     qw(make_path remove_tree);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use Cwd            qw(realpath);
use Exporter 'import';

our @EXPORT_OK = qw(private_root private_path resolve resolve_for_write
    is_private move_in move_out stray_public count_private);

# The store's directory name. A leading dot would hide it from an operator
# looking at the tree, and the point is that they can see where their private
# content went.
our $DIRNAME = 'lazysite-private';

sub private_root {
    my ($docroot) = @_;
    return undef unless defined $docroot && length $docroot;
    return dirname($docroot) . "/$DIRNAME";
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

    my @parts = split m{/}, $rel;
    pop @parts;    # the path itself does not exist; start at its parent
    while (@parts) {
        my ( undef, $w ) = resolve( $docroot, join( '/', @parts ) );
        if ( $w eq 'private' ) { return ( private_path( $docroot, $rel ), 'private' ) }
        last if $w;    # a public ancestor settles it
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

# Confinement: never let a caller's path escape either tree. Both roots are
# resolved with realpath so a symlink cannot be used to write outside.
sub _within {
    my ( $root, $abs ) = @_;
    return 0 unless defined $root && defined $abs;
    my $rroot = realpath($root)           or return 0;
    my $rabs  = realpath( dirname($abs) ) or return 0;
    return ( $rabs eq $rroot || index( $rabs, "$rroot/" ) == 0 ) ? 1 : 0;
}

# Move public -> private. Returns ( $ok, $error ).
#
# rename() is atomic within a filesystem and moves a whole directory in one
# step, which is what makes protecting a section safe: there is no window in
# which half a section is public. Across filesystems it fails with EXDEV, and
# the fallback copies, VERIFIES, and only then removes the original - so an
# interrupted copy leaves the content public and reports failure, rather than
# leaving it half-moved and unreadable.
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
    make_path($parent) unless -d $parent;
    return ( 0, 'cannot create the private store' ) unless -d $parent;
    return ( 0, 'refusing a path outside the private store' )
        unless _within( private_root($docroot), $dst );

    # An existing destination means a previous move left something behind. Do
    # not overwrite it silently - that would destroy the governed copy in
    # favour of one the front end has been serving.
    return ( 0, 'the private store already holds this path' ) if -e $dst;

    return ( 1, undef ) if rename $src, $dst;

    # Cross-device, or a rename the filesystem refused.
    return ( 0, 'cannot move a folder across filesystems' ) if -d $src;
    return ( 0, "copy failed: $!" ) unless copy( $src, $dst );
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
    make_path($parent) unless -d $parent;
    return ( 0, 'cannot create the destination folder' ) unless -d $parent;
    return ( 0, 'refusing a path outside the docroot' )
        unless _within( $docroot, $dst );

    return ( 1, undef )                                     if rename $src, $dst;
    return ( 0, 'cannot move a folder across filesystems' ) if -d $src;
    return ( 0, "copy failed: $!" ) unless copy( $src, $dst );
    unless ( -s $dst == -s $src ) {
        unlink $dst;
        return ( 0, 'the copy did not match the original; nothing was moved' );
    }
    unlink $src or return ( 0, 'the copy landed but the private original could '
            . 'not be removed' );
    return ( 1, undef );
}

1;

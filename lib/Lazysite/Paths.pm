package Lazysite::Paths;

# SM293 step 2: where the engine's own tree lives.
#
# WHY THIS EXISTS. `lazysite/` holds config, credentials, the audit log, session
# state, form submissions and pre-install snapshots - none of it content, and all
# of it inside the directory the web server serves. It is kept unreachable by a
# `deny /lazysite/` rule repeated in every shipped front-end template, which is
# the same arrangement SM248, SM268 H17 and SM283 each turned out to be: security
# living in configuration lazysite ships as a template, cannot test where it is
# installed, and on most deployments cannot even see.
#
# The concrete case, not a hypothetical: SM283's Hestia proxy answered static
# extensions off the docroot before Apache saw the request, so on any host whose
# list includes `gz` it would have served
# `lazysite/backups/preinstall-*.tar.gz` - a whole-site snapshot, including the
# account store, to anyone who knew the path.
#
# DISCOVERY, NOT ASSUMPTION - and this is the whole reason the change is safe.
# The engine ASKS where its tree is rather than computing one answer. A site
# migrates by MOVING THE DIRECTORY and nothing else: no config key, no flag day,
# no version gate. Both layouts work on the same code, so an upgrade cannot
# half-migrate a site into an unbootable state, and an operator who moves it back
# has undone the migration completely.
#
# This mirrors Lazysite::Private, deliberately. Two trees now sit beside the
# docroot on a migrated site:
#
#   <docroot>                    the served tree, and only content
#   <docroot>-lazysite           the engine's own tree (this module)
#   <docroot>-lazysite-private   protected content (Lazysite::Private)
#
# named for the docroot they belong to, so two sites under one parent directory
# can never share either. That naming was not free: a fixed name in the parent
# was the first shape of the private store, and it meant any two docroots with
# the same parent shared one store and each resolved the other's protected
# content.

use strict;
use warnings;
use File::Basename qw(dirname basename);
use Exporter 'import';

our @EXPORT_OK = qw(lazysite_dir external_lazysite_dir stray_lazysite);

our $DIRNAME = 'lazysite';

# The out-of-docroot location, whether or not anything is there yet.
sub external_lazysite_dir {
    my ($docroot) = @_;
    return undef unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};
    return undef unless length $docroot;
    return dirname($docroot) . '/' . basename($docroot) . "-$DIRNAME";
}

# Where this site's engine tree actually is.
#
# OUTSIDE WINS when both exist, and that direction is not a preference. A tree
# left inside the docroot is reachable by any front end that has not been told
# otherwise - the exposure being removed - so the engine must govern the copy
# that is safe and let stray_lazysite() report the one that is not. Preferring
# the inside copy would hide a half-finished migration behind working software,
# which is the worst of both.
sub lazysite_dir {
    my ($docroot) = @_;
    return undef unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};

    my $ext = external_lazysite_dir($docroot);
    return $ext if defined $ext && -d $ext;
    return "$docroot/$DIRNAME";
}

# Is this site half-migrated - an engine tree in BOTH places?
#
# Always a fault, and a quiet one: the engine reads the outside copy while the
# front end can still serve the inside one, so the site works perfectly and
# publishes its account store. Reported rather than repaired, because choosing
# which copy is current is a decision about an operator's live credentials.
sub stray_lazysite {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};
    my $ext = external_lazysite_dir($docroot);
    return ( defined $ext && -d $ext && -d "$docroot/$DIRNAME" ) ? 1 : 0;
}

# Move the engine tree OUT of the document root. Returns ( $ok, $error_or_note ).
#
# rename() is atomic within a filesystem and moves the whole tree in one step,
# which is what makes this safe to run on a live site: there is no window in
# which half the config, or half the account store, is in each place. Across
# filesystems it fails with EXDEV and this REFUSES rather than falling back to a
# copy - a half-copied auth store is the worst outcome available here, and the
# operator can move it themselves and re-run the check.
#
# Idempotent: a site already migrated returns ok with a note, so "migrate
# everything" is safe to run repeatedly and safe to run on a mixed fleet.
sub migrate_out {
    my ($docroot) = @_;
    return ( 0, 'no docroot given' ) unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};

    my $inside = "$docroot/$DIRNAME";
    my $ext    = external_lazysite_dir($docroot)
        or return ( 0, 'cannot derive the external location' );

    return ( 0, 'this site has an engine tree in BOTH places - resolve that by '
            . 'hand before migrating; the engine is already reading the one '
            . 'outside, so the copy inside the document root is the one to '
            . 'check and remove' )
        if -d $ext && -d $inside;

    return ( 1, 'already migrated' ) if -d $ext;
    return ( 0, "no engine tree at $inside" ) unless -d $inside;

    return ( 0, 'something already exists at the destination' ) if -e $ext;

    unless ( rename $inside, $ext ) {
        my $err = "$!";
        return ( 0, 'cannot move the engine tree across filesystems - move it '
                . "by hand and re-run: $err" )
            if $err =~ /cross-device|Invalid cross/i;
        return ( 0, "cannot move the engine tree: $err" );
    }
    return ( 1, 'migrated' );
}

# And back, for an operator who wants to undo it. Same contract reversed.
#
# Reversibility is not politeness. It is what lets a site be migrated on edge,
# watched, and put back without a release if anything about the deployment turns
# out to disagree.
sub migrate_back {
    my ($docroot) = @_;
    return ( 0, 'no docroot given' ) unless defined $docroot && length $docroot;
    $docroot =~ s{/+\z}{};

    my $inside = "$docroot/$DIRNAME";
    my $ext    = external_lazysite_dir($docroot)
        or return ( 0, 'cannot derive the external location' );

    return ( 0, 'this site has an engine tree in BOTH places - resolve that by '
            . 'hand first' )
        if -d $ext && -d $inside;

    return ( 1, 'already inside the document root' ) if -d $inside;
    return ( 0, "no engine tree at $ext" ) unless -d $ext;

    unless ( rename $ext, $inside ) {
        my $err = "$!";
        return ( 0, "cannot move the engine tree back: $err" );
    }
    return ( 1, 'moved back' );
}

1;

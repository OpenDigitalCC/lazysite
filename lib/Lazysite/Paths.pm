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

1;

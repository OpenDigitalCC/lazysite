package Lazysite::Data::Connect;

# SM447: two handles, structurally separated.
#
# The render path and the endpoint's read side get a READ-ONLY handle. The
# validated write path gets a read-write one. That is not a convention anybody
# has to remember - it is enforced by the connection itself, so a bug in a
# caller cannot become a write from a page render.
#
# WHY IT IS DONE THIS WAY RATHER THAN BY DISCIPLINE:
#
#   A page render is the least trusted place in this system to hold a writable
#   database handle. It runs per request, it is reached by anonymous visitors,
#   and its inputs are content. Everything else in this plugin is a check that
#   can be got wrong once; a read-only handle is a property that stays true
#   even when a check is.
#
#   SQLite gives it to us honestly: sqlite_open_flags => SQLITE_OPEN_READONLY
#   is refused by the driver, not by us. On a server engine the operator SHOULD
#   supply a read-only role in the URI - that is documented rather than
#   pretended, because we cannot enforce it from here and saying otherwise
#   would be the worse failure.
#
# WAL and busy_timeout are set on connect: WAL so a reader is never blocked by
# a writer (a page render must not wait on an import), busy_timeout so a writer
# waits rather than failing instantly under concurrency.
#
# RaiseError is ON. A silent failure in a data layer is a wrong page, and this
# programme has spent a week on controls that reported success without
# checking.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(read_handle write_handle store_path ensure_store
    store_diagnosis);

our $BUSY_TIMEOUT_MS = 5_000;

sub store_path {
    my ($docroot) = @_;
    return "$docroot/lazysite/db/data.sqlite";
}

# Create the directory, never the database file itself - DBI does that on
# first connect. Returns the path, or undef if the directory cannot be made.
sub ensure_store {
    my ($docroot) = @_;
    my $path = store_path($docroot);
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    unless ( -d $dir ) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 } or return undef;
    }
    return -d $dir ? $path : undef;
}

sub _connect {
    my ( $docroot, %opt ) = @_;
    require DBI;
    require DBD::SQLite;

    my $path = $opt{readonly} ? store_path($docroot) : ensure_store($docroot);
    return undef unless defined $path;

    # A read-only handle on a store that does not exist yet is a legitimate
    # nothing, not an error: a site with no tables renders pages that show no
    # rows. Returning undef lets the caller say "no data" rather than die on
    # every page of a site that has never used the feature.
    return undef if $opt{readonly} && !-e $path;

    my %attr = (
        RaiseError                 => 1,
        PrintError                 => 0,
        AutoCommit                 => 1,
        sqlite_unicode             => 1,
        sqlite_see_if_its_a_number => 1,
    );

    if ( $opt{readonly} ) {
        # Enforced by the DRIVER. A caller that tries to write through this
        # handle gets an error from SQLite, not from a check of ours that
        # could be bypassed or forgotten.
        $attr{sqlite_open_flags} = DBD::SQLite::OPEN_READONLY();
    }

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$path", '', '', \%attr );
    return undef unless $dbh;

    # WAL COSTS SOMETHING WORTH KNOWING, measured rather than assumed: a reader
    # needs a `-shm` file BESIDE the database, so a store directory that is not
    # writable breaks READING as well as writing. Even `PRAGMA journal_mode`
    # fails, with "attempt to write a readonly database".
    #
    # SQLITE IS HONEST ABOUT THIS. An earlier version of this comment said the
    # reads came back silently empty; they do not - they raise. The silence was
    # ours, in a caller that wrapped the probe in `eval {} || {exists => 0}`
    # and turned a real error into "the table has not been created yet". The
    # engine reported accurately and our fallback discarded it, which is the
    # defect class this codebase spends most of its time removing.
    #
    # So the answer is not a deployment note. It is store_diagnosis() below,
    # which the read path consults when something fails, so an operator is told
    # the directory is not writable rather than being told their table is
    # empty. Read-only deployment may be a legitimate choice; being unable to
    # tell it apart from an empty table is not.
    #
    # WAL is a property of the DATABASE, not the connection, so it is set once
    # by a writer; a read-only handle cannot set it and must not try.
    unless ( $opt{readonly} ) {
        eval { $dbh->do('PRAGMA journal_mode = WAL');              1 };
        eval { $dbh->do("PRAGMA busy_timeout = $BUSY_TIMEOUT_MS"); 1 };
    }
    else {
        eval { $dbh->do("PRAGMA busy_timeout = $BUSY_TIMEOUT_MS"); 1 };
    }

    return $dbh;
}

# WHY A READ FAILED, in terms an operator can act on.
#
# Called when something on the read path has already gone wrong. It does not
# guess: each branch below is a condition that has been checked, and the last
# one says plainly that the cause is unknown rather than offering a plausible
# story.
#
# THE PROBE IS A REAL WRITE ATTEMPT, not a stat. `-w` answers from the mode
# bits and the real uid, and gets a read-only MOUNT, an ACL, or a container's
# view wrong - in a direction that matters, because it would report "writable"
# for a directory that is not. Creating and removing a file answers the
# question that was actually asked.
sub store_diagnosis {
    my ($docroot) = @_;
    my $path = store_path($docroot);
    ( my $dir = $path ) =~ s{/[^/]+\z}{};

    return { ok => 0, reason => 'no_store',
        detail => "There is no data store yet at $path. It is created the "
            . 'first time a table is migrated.' }
        unless -e $path;

    return { ok => 0, reason => 'unreadable',
        detail => "The data store at $path cannot be read. Check its "
            . 'ownership and mode.' }
        unless -r $path;

    my $probe    = "$dir/.lazysite-write-probe.$$";
    my $writable = 0;
    if ( open my $fh, '>', $probe ) {
        close $fh;
        unlink $probe;
        $writable = 1;
    }

    return { ok => 0, reason => 'directory_not_writable',
        detail => "The directory $dir is not writable. The store uses WAL "
            . 'journalling, and a WAL reader has to create a `-shm` file '
            . 'beside the database - so a read-only directory stops READS as '
            . 'well as writes. Make the directory writable by the account '
            . 'that serves the site.' }
        unless $writable;

    return { ok => 0, reason => 'unknown',
        detail => "The data store at $path exists, is readable, and its "
            . 'directory is writable. The cause is not one this check knows '
            . 'about - the underlying error from the database is the thing '
            . 'to read.' };
}

sub read_handle  { return _connect( $_[0], readonly => 1 ) }
sub write_handle { return _connect( $_[0], readonly => 0 ) }

1;

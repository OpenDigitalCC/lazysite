package Lazysite::Manager::PageCopy;

# SM1354 (ruling 155): COPY A PAGE, CHANGE THE COPY, PUBLISH IT OVER THE PAGE.
#
# A change to a live page is prepared on a private copy, looked at, and then put
# over the page in one move - the theme copy-then-activate route
# (Manager::Themes::action_theme_copy, SM749), for a page. Content history is
# the way back.
#
#   page-copy          copy_page     take a copy (one open copy per page)
#   page-copy-publish  publish_copy  put the copy over the page, and close it
#   page-copy-discard  discard_copy  throw the copy away, leaving no trace
#   page-copies        (read)        the open copies this caller may edit
#
# THE COPY is a page source at lazysite/copies/pages/<page path>
# (Lazysite::PageCopy says why there, and what keeps it private). It is edited
# like any page, by that path: Manager::Files writes a file there only while
# its copy is open, records no content-history commit for it and indexes no
# alias from it. It is rendered only as a draft, at the page's own path - with
# the page's layout, theme, navigation and data - by preview_page and the
# manager's preview, which write nothing.
#
# THE RECORDS are lazysite/copies/records.json: per page, who took the copy,
# when, what the page was at that moment (its bytes' digest, and its content
# history version when history is kept), and who has changed the copy since.
# Outside the carve-out, so no file verb writes them.
#
# PUBLISHING is Files::action_save of the copy's text at the page's path - the
# one write path, so every rule a save applies applies to a publish - with a
# commit message naming the publisher, the door and who prepared the copy. It
# is refused when the page changed after the copy was taken (stale): both
# versions are named and nothing is written. Undo is restore_version of the
# version before the publish, which the answer names.
#
# WHO. Taking, changing, discarding and listing a copy is manage_content plus
# the page's own write rule. Publishing is the same for a person in the manager;
# over MCP and the control API it needs `publish_copies` as well - off by
# default and held by no shipped role (ruling 155), so an agent proposes by
# copying and changing, and publishes only where the site has said it may.
# Those gates are the dispatchers' (ControlApi::Actions %GATE, the MCP tool's
# cap); this module answers who the publish came from, as the door says.

use strict;
use warnings;
use Exporter 'import';
use Fcntl                     qw(:flock);
use File::Path                qw(make_path);
use File::Basename            qw(dirname);
use Digest::SHA               qw(sha256_hex);
use JSON::PP                  ();
use Lazysite::Util            qw(log_event);
use Lazysite::Paths           ();
use Lazysite::PageCopy        ();
use Lazysite::Manager::Common qw(validate_path is_blocked_path is_blocked_config refusal_detail
    outside_all_scopes);
use Lazysite::Auth::Acl qw(_acl_denied _acl_allows);

our @EXPORT_OK = qw(action_page_copy action_page_copy_publish action_page_copy_discard
    action_page_copies open_copy note_copy_edit page_version);

# The request context is Manager::Files's - the module whose save a publish is -
# so the docroot and the account are set where they always are, once.
sub _docroot {
    no warnings 'once'; ## no critic (ProhibitNoWarnings) - Files sets it and loads this module
    return $Lazysite::Manager::Files::DOCROOT;
}
sub _lz      { return Lazysite::Paths::lazysite_dir( _docroot() ) }
sub _dir     { return _lz() . '/copies' }
sub _records { return _dir() . '/records.json' }

# Where a copy's bytes are, for its docroot-relative copy path.
sub _copy_full {
    my ($copy_rel) = @_;
    ( my $tail = $copy_rel ) =~ s{\Alazysite/}{};
    return _lz() . "/$tail";
}

sub _refused {
    my ( $kind, $cause, $remedy, %extra ) = @_;
    return { ok => 0, kind => $kind, error => "$cause. " . ucfirst($remedy) . '.',
        audit_detail => refusal_detail( $kind, $cause, $remedy ), %extra };
}

# --- the records ---------------------------------------------------------------

# Run $code with the records, under an exclusive lock; $code returns the result
# and may change the hash it is given (written back when it says so).
sub _with_records {
    my ($code) = @_;
    my $dir = _dir();
    make_path($dir) unless -d $dir;
    open my $lk, '>>', "$dir/.records.lock"
        or return { ok => 0, kind => 'not-saved', error => "The page copy records cannot be locked: $!" };
    flock( $lk, LOCK_EX );
    my ( $recs, $fault ) = _read_records();
    if ($fault) {
        flock( $lk, LOCK_UN );
        close $lk;
        return $fault;
    }
    my ( $result, $dirty ) = $code->($recs);
    if ($dirty) {
        my $tmp = _records() . ".$$.tmp";
        if ( open my $fh, '>:raw', $tmp ) {
            print {$fh} JSON::PP->new->canonical->pretty->encode($recs);
            close $fh;
            rename $tmp, _records() or unlink $tmp;
        }
        else {
            $result = { ok => 0, kind => 'not-saved', error => "The page copy records cannot be written: $!" };
        }
    }
    flock( $lk, LOCK_UN );
    close $lk;
    return $result;
}

# ( \%records ) or ( undef, $refusal ). ABSENT IS NO COPIES; a file that will not
# open or decode is not "no copies" - it is refused, so a copy is never taken over
# one the records lost and a save to a copy is never let through on a guess.
sub _read_records {
    my $file  = _records();
    my $fault = { ok => 0, kind => 'store-uninspectable',
        error => 'The page copy records (lazysite/copies/records.json) cannot be read; nothing was '
            . 'changed. Ask the operator to check the file.' };
    open my $fh, '<:raw', $file or do {
        return ( {} ) if $!{ENOENT};
        Lazysite::Util::cannot_read( 'the page copy records', $file );
        return ( undef, $fault );
    };
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    return ($d) if ref $d eq 'HASH';
    log_event( 'WARN', 'page-copy', 'the page copy records do not decode', file => $file );
    return ( undef, $fault );
}

# The open copy of a page (docroot-relative), or undef. Unreadable records hold
# no open copy, so a save to a copy is refused rather than let through.
sub open_copy {
    my ($page) = @_;
    ( my $rel = $page // '' ) =~ s{^/+}{};
    my ($recs) = _read_records();
    my $r      = $recs ? $recs->{$rel} : undef;
    return ref $r eq 'HASH' ? $r : undef;
}

# A save to a copy names its writer in the record (Manager::Files asks this).
sub note_copy_edit {
    my ( $page, $user ) = @_;
    return unless defined $user && length $user;
    _with_records(
        sub {
            my ($recs) = @_;
            my $r = $recs->{$page};
            return ( undef, 0 ) unless ref $r eq 'HASH';
            my %have = map { $_ => 1 } @{ $r->{changed_by} || [] };
            return ( undef, 0 ) if $have{$user};
            push @{ $r->{changed_by} }, $user;
            return ( undef, 1 );
        }
    );
    return;
}

# --- what a page is, now ---------------------------------------------------------

# A page's version: the digest of its bytes (absent when there is no file) and,
# when content history is kept for it, the id of its newest recorded version.
# The digest decides staleness - it is what the page IS, whether or not history
# is kept - and the history id is what restore_version takes.
sub page_version {
    my ($r) = @_;
    my $digest = 'absent';
    if ( open my $fh, '<:raw', $r->{full} ) { # not a store: the page itself; absent is "absent"
        local $/;
        my $bytes = <$fh>;
        close $fh;
        $digest = 'sha256:' . sha256_hex( $bytes // '' );
    }
    my $v = eval {
        require Lazysite::Git;
        return undef unless Lazysite::Git::enabled( _docroot() );
        my $repo = Lazysite::Manager::Files::history_root_for($r);
        return undef unless defined $repo;
        my $log = Lazysite::Git::file_log( $repo, $r->{rel}, 1 );
        return ( ref $log eq 'ARRAY' && @$log ) ? $log->[0]{sha} : undef;
    };
    return { digest => $digest, ( defined $v ? ( history_version => $v ) : () ) };
}

# The page a request names: a page path, or its copy's path. The validate_path
# result, or a refusal.
sub _page_target {
    my ( $path, $user, $what ) = @_;
    my $given = $path // '';
    my $page  = Lazysite::PageCopy::original_of($given);
    $page = $given unless defined $page;
    return _refused( 'invalid-path', 'No page was named', "name the page to $what, such as /about.md" )
        unless length $page;
    my $r = validate_path($page);
    return $r unless $r->{ok};
    return _refused( 'not-a-page', "'$r->{rel}' is not a page",
        'name a page (a .md file); a copy is taken of a page only' )
        unless $r->{rel} =~ /\.md\z/ && !Lazysite::PageCopy::under_copies( $r->{rel} )
        && defined Lazysite::PageCopy::copy_of( $r->{rel} );
    if ( my $why = is_blocked_path( $r->{rel} ) ) {
        return _refused( 'blocked', $why =~ s/\.\z//r, 'copy an ordinary content page' );
    }
    if ( my $why = is_blocked_config( $r->{rel} ) ) {
        return _refused( 'blocked-config', $why =~ s/\.\z//r, 'copy an ordinary content page' );
    }
    # A copy is the editors' - the page's write rule, for every verb here.
    if ( my $d = _acl_denied( $r->{rel}, 'write', $user ) ) {
        return { %$d, error => "$d->{error}. A page's copy is for those who may change the page." };
    }
    return $r;
}

sub _show {
    my ($rec) = @_;
    return {
        page       => "/$rec->{page}",
        copy       => $rec->{copy},
        taken_by   => $rec->{taken_by},
        taken_at   => $rec->{taken_at},
        taken_from => $rec->{taken_from},
        changed_by => [ @{ $rec->{changed_by} || [] } ],
    };
}

# --- the verbs ---------------------------------------------------------------------

sub action_page_copy {
    my ( $path, $user ) = @_;
    my $r = _page_target( $path, $user, 'copy' );
    return $r unless $r->{ok};
    my $rel = $r->{rel};
    return _refused( 'not-found', "'$rel' does not exist", 'copy a page that is there' )
        unless -f $r->{full};

    my $bytes = do {
        open my $fh, '<:raw', $r->{full}
            or return { ok => 0, kind => 'store-uninspectable', error => "'$rel' could not be read: $!" };
        local $/;
        my $b = <$fh>;
        close $fh;
        $b // '';
    };
    my $copy_rel = Lazysite::PageCopy::copy_of($rel);
    my $from     = page_version($r);

    return _with_records(
        sub {
            my ($recs) = @_;
            if ( my $open = $recs->{$rel} ) {
                return ( _refused( 'copy-open', "'$rel' already has an open copy, taken by "
                            . ( $open->{taken_by} // 'someone' ),
                        "change that copy ($open->{copy}), publish it, or discard it first",
                        copy => $open->{copy} ), 0 );
            }
            my $full = _copy_full($copy_rel);
            make_path( dirname($full) ) unless -d dirname($full);
            open my $out, '>:raw', "$full.$$.tmp"
                or return ( { ok => 0, kind => 'not-saved', error => "The copy could not be written: $!" }, 0 );
            print {$out} $bytes;
            close $out;
            rename "$full.$$.tmp", $full
                or return ( { ok => 0, kind => 'not-saved', error => "The copy could not be written: $!" }, 0 );
            my $who = ( defined $user && length $user ) ? $user : 'unknown';
            $recs->{$rel} = {
                page       => $rel,
                copy       => $copy_rel,
                taken_by   => $who,
                taken_at   => time(),
                taken_from => $from,
                changed_by => [],
            };
            log_event( 'INFO', 'page-copy', 'page copied', page => $rel, user => $who );
            return (
                { ok => 1,
                    %{ _show( $recs->{$rel} ) },
                    next => "change the copy with write_file or replace_text at '$copy_rel' (the manager "
                        . "opens it in the editor), see it with preview_page path '$copy_rel', then "
                        . 'publish_copy or discard_copy it',
                },
                1
            );
        }
    );
}

# %opt: door => 'person' | 'agent' (the dispatcher says which), via => a label
# for what made the change ('wizard'), recorded as said.
sub action_page_copy_publish {
    my ( $path, $user, %opt ) = @_;
    my $r = _page_target( $path, $user, 'publish' );
    return $r unless $r->{ok};
    my $rel = $r->{rel};
    my $rec = open_copy($rel)
        or return _refused( 'no-copy', "'$rel' has no open copy", 'take one with copy_page first' );
    my $door = ( ( $opt{door} // '' ) =~ /\A(person|agent)\z/ )          ? $1 : 'agent';
    my $via  = ( ( $opt{via}  // '' ) =~ /\A([a-z][a-z0-9_-]{0,31})\z/ ) ? $1 : undef;

    # STALE: the page changed after the copy was taken. Publishing would put an
    # old page's text, changed, over somebody's newer one - refused, with both.
    my $now = page_version($r);
    if ( $now->{digest} ne ( $rec->{taken_from}{digest} // '' ) ) {
        return _refused( 'stale-copy',
            "'$rel' changed after its copy was taken, so the copy was not published",
            'look at both (view_version for the page, read_file for the copy), then discard the copy '
                . 'and copy the page again, or carry the change into the page by hand',
            page       => "/$rel",            copy    => $rec->{copy},
            taken_from => $rec->{taken_from}, current => $now );
    }

    my $full = _copy_full( $rec->{copy} );
    my $text = do {
        open my $fh, '<:raw', $full
            or return _refused( 'copy-missing', "the copy of '$rel' is not on disk",
            'discard it and copy the page again', copy => $rec->{copy} );
        local $/;
        my $b = <$fh>;
        close $fh;
        $b // '';
    };
    utf8::decode($text);

    my $who  = ( defined $user && length $user ) ? $user : 'unknown';
    my $from = $door . ( defined $via ? " via $via" : '' );
    my @prep = ( $rec->{taken_by} // 'unknown', @{ $rec->{changed_by} || [] } );
    my %seen;
    @prep = grep { !$seen{$_}++ } @prep;
    my $message = "publish $rel from its copy - by $who ($from); prepared by " . join( ', ', @prep );

    my $saved = do {
        no warnings 'once';
        local $Lazysite::Manager::Files::GIT_COMMIT_MESSAGE = $message;
        Lazysite::Manager::Files::action_save( $rel, $user, $text, undef );
    };
    return $saved unless ref $saved eq 'HASH' && $saved->{ok};

    # The copy is closed: its file and its record go, as a discard's do.
    _close_copy($rel);

    my $after    = page_version($r);
    my $previous = $rec->{taken_from}{history_version};
    log_event( 'INFO', 'page-copy-publish', 'page published from its copy',
        page => $rel, user => $who, from => $from );
    # A copy published unchanged changes nothing, so it records nothing and has
    # nothing to undo - said, rather than offering an Undo to the same page.
    if ( $after->{digest} eq $now->{digest} ) {
        return { ok => 1, page => "/$rel", published_by => $who, from => $from,
            prepared_by => \@prep, version => $after, unchanged => JSON::PP::true,
            note => 'the copy was the page as it stands, so nothing changed and no version was recorded; '
                . 'the copy is closed' };
    }
    return {
        ok           => 1,
        page         => "/$rel",
        published_by => $who,
        from         => $from,
        prepared_by  => \@prep,
        version      => $after,
        previous     => $rec->{taken_from},
        ( defined $previous && defined $after->{history_version} && $after->{history_version} ne $previous
            ? ( undo => { tool => 'restore_version', action => 'git-restore', path => "/$rel",
                    version => $previous,
                    note => 'restores the page as it was before this publish; the undo is itself a new version' } )
            : ( undo_note => 'Content history is not kept for this page, so there is no recorded version to '
                    . 'undo to. Enable the Content history extension to have Undo offered.' ) ),
        message => $message,
    };
}

sub action_page_copy_discard {
    my ( $path, $user ) = @_;
    my $r = _page_target( $path, $user, 'discard the copy of' );
    return $r unless $r->{ok};
    my $rel = $r->{rel};
    my $rec = open_copy($rel)
        or return _refused( 'no-copy', "'$rel' has no open copy", 'there is nothing to discard' );
    _close_copy($rel);
    log_event( 'INFO', 'page-copy-discard', 'page copy discarded', page => $rel,
        user => ( $user // '' ) );
    return { ok => 1, page => "/$rel", discarded => $rec->{copy},
        note => 'the copy is gone; the page and its content history are as they were' };
}

# The open copies this caller may edit, within its scopes.
sub action_page_copies {
    my ( $user, $scopes ) = @_;
    my ( $recs, $fault )  = _read_records();
    return $fault if $fault;
    my @out;
    for my $rel ( sort keys %$recs ) {
        my $rec = $recs->{$rel};
        next unless ref $rec eq 'HASH';
        next if ref $scopes eq 'ARRAY' && outside_all_scopes( $scopes, $rel );
        next unless _acl_allows( $rel, 'write', $user );
        my $r = validate_path($rel);
        my $stale = ( $r->{ok} && page_version($r)->{digest} ne ( $rec->{taken_from}{digest} // '' ) ) ? 1 : 0;
        push @out, { %{ _show($rec) }, stale => ( $stale ? JSON::PP::true : JSON::PP::false ) };
    }
    return { ok => 1, copies => \@out };
}

sub _close_copy {
    my ($rel) = @_;
    _with_records(
        sub {
            my ($recs) = @_;
            my $rec    = delete $recs->{$rel} or return ( undef, 0 );
            my $full   = _copy_full( $rec->{copy} );
            unlink $full;
            # Empty folders the copy made go with it.
            my $stop = _dir() . '/pages';
            my $dir  = dirname($full);
            while ( length $dir > length $stop && index( $dir, "$stop/" ) == 0 ) {
                last unless rmdir $dir;
                $dir = dirname($dir);
            }
            return ( undef, 1 );
        }
    );
    return;
}

1;

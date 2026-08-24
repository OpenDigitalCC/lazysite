package Lazysite::Manager::Briefs;
# SM245: the brief store, out of band. One entry per content path, keyed BY
# that path under lazysite/briefs/ - engine-owned, DAV-blocklisted with the
# rest of lazysite/, and never served. Append-only, exactly the discipline
# the sidecar had; only the storage moved. The engine's render, listing and
# move paths no longer know briefs exist - which is the entire point, and
# why a moved file's entry staying under its old key is the filing's own
# accepted interim rather than a defect (a reconcile pass can adopt it).
use strict;
use warnings;
use File::Path                qw(make_path);
use File::Basename            qw(dirname);
use Lazysite::Util            qw(log_event);
use Lazysite::Manager::Common qw(validate_path is_blocked_path);
use Exporter 'import';
our @EXPORT_OK = qw(action_brief_read action_brief_append
    action_briefs_migrate plugin_status store_entry_move store_entry_remove);

our $DOCROOT;
our $auth_user = '';

sub _gate {
    local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
    require Lazysite::Manager::Plugins;
    return undef
        if Lazysite::Manager::Plugins::plugin_enabled('plugins/briefs.pl');
    return { ok => 0,
        error => 'The briefs plugin is disabled. An operator can enable it '
            . 'on the Plugin Manager page.' };
}

# SM507: the store entry follows its file. SM245 recorded a moved file's
# entry staying under the old key as a tolerable interim "until a reconcile
# adopts it" - the field found the interim's cost first (a renamed page
# silently split from its record of intent, a deleted page's entry orphaned
# and undiscoverable). These two helpers are that reconcile, called by every
# surface that moves or deletes content. They are DELIBERATELY UNGATED:
# carrying a store entry is filesystem consistency, not an agent surface -
# a site with the plugin disabled but entries on disk still deserves them
# kept consistent. The docroot is a PARAMETER, never the package var: the
# DAV process does not set it (the SM504 lesson).
sub store_entry_move {
    my ( $docroot, $src_rel, $dst_rel ) = @_;
    return unless defined $docroot && length $docroot;
    for ( $src_rel, $dst_rel ) { return unless defined; s{\A/+}{}; return if m{\.\.} }
    my $src = "$docroot/lazysite/briefs/$src_rel";
    return unless -e $src;
    my $dst = "$docroot/lazysite/briefs/$dst_rel";
    make_path( dirname($dst) ) unless -d dirname($dst);
    rename $src, $dst
        or log_event( 'WARN', $src_rel, 'brief store entry not carried',
        to => $dst_rel, error => "$!" );
    return;
}

sub store_entry_remove {
    my ( $docroot, $rel ) = @_;
    return unless defined $docroot && length $docroot;
    return unless defined $rel;
    $rel =~ s{\A/+}{};
    return if $rel =~ m{\.\.};
    my $f = "$docroot/lazysite/briefs/$rel";
    if    ( -f $f ) { unlink $f }
    elsif ( -d $f ) { require File::Path; File::Path::remove_tree( $f, { safe => 1 } ) }
    return;
}

sub _store_path {
    my ($rel) = @_;
    $rel =~ s{\A/+}{};
    return "$DOCROOT/lazysite/briefs/$rel";
}

sub action_brief_read {
    my ($path) = @_;
    if ( my $off = _gate() ) { return $off }
    my $r = validate_path($path);
    return $r unless $r->{ok};
    return { ok => 0, error => 'Path is blocked' } if is_blocked_path( $r->{rel} );
    my $f = _store_path( $r->{rel} );
    return { ok => 1, path => $r->{rel}, brief => '', exists => 0 }
        unless -f $f;
    open my $fh, '<:utf8', $f
        or return { ok => 0, error => 'the brief store entry could not be read' };
    my $c = do { local $/; <$fh> };
    close $fh;
    return { ok => 1, path => $r->{rel}, brief => $c, exists => 1 };
}

sub action_brief_append {
    my ( $path, $entry ) = @_;
    if ( my $off = _gate() ) { return $off }
    return { ok => 0, error => 'entry text required' }
        unless defined $entry && $entry =~ /\S/;
    return { ok => 0, error => 'entry too large (64KB cap per append)' }
        if length($entry) > 65536;
    my $r = validate_path($path);
    return $r unless $r->{ok};
    return { ok => 0, error => 'Path is blocked' } if is_blocked_path( $r->{rel} );
    my $f = _store_path( $r->{rel} );
    make_path( dirname($f) ) unless -d dirname($f);
    $entry =~ s/\s+\z//;
    my @t     = gmtime;
    my $stamp = sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    my $actor = length $auth_user ? $auth_user : '(unattributed)';
    open my $fh, '>>:utf8', $f
        or return { ok => 0, error => 'the brief store entry could not be written' };
    print {$fh} ( -s $f ? "\n" : "# Brief - $r->{rel}\n\n" ),
        "- $stamp \x{b7} $actor \x{b7} $entry\n";
    close $fh;
    log_event( 'INFO', $r->{rel}, 'brief appended', actor => $actor );
    return { ok => 1, path => $r->{rel} };
}

# The status the Plugin Manager shows (SM495's lesson: a message, always).
sub plugin_status {
    my $dir = "$DOCROOT/lazysite/briefs";
    my ( $entries, $sidecars ) = ( 0, 0 );
    if ( -d $dir ) {
        require File::Find;
        File::Find::find(
            { no_chdir => 1, wanted => sub { $entries++ if -f $File::Find::name } },
            $dir );
    }
    require File::Find;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                return      if $File::Find::name                         =~ m{/lazysite/};
                $sidecars++ if -f $File::Find::name && $File::Find::name =~ /\.brief\z/;
            },
        },
        $DOCROOT ) if -d $DOCROOT;
    my $msg =
        $sidecars
        ? "Briefs: $entries in the store; $sidecars sidecar file(s) still "
        . 'in the content tree - run Migrate sidecars'
        : "Briefs: $entries in the store; no sidecar files remain";
    return { ok => 1, entries => $entries, sidecars => $sidecars, message => $msg };
}

# SM245's migration, and its one hard rule: NEVER remove a sidecar that was
# not successfully imported. Idempotent - an entry already in the store is
# not duplicated (the sidecar is appended only if the store entry does not
# yet exist; a sidecar AND an existing entry means a previous partial run,
# and the sidecar's text is appended once under a migration marker rather
# than lost or blindly re-imported).
sub action_briefs_migrate {
    if ( my $off = _gate() ) { return $off }
    my ( @imported, @removed, @failed );
    require File::Find;
    my @sidecars;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                return if $File::Find::name =~ m{/lazysite/};
                push @sidecars, $File::Find::name
                    if -f $File::Find::name && $File::Find::name =~ /\.brief\z/;
            },
        },
        $DOCROOT );
    for my $abs (@sidecars) {
        ( my $rel = $abs ) =~ s{\A\Q$DOCROOT\E/}{};
        ( my $for = $rel ) =~ s/\.brief\z//;
        my $content = do {
            if ( open my $fh, '<:utf8', $abs ) { local $/; my $c = <$fh>; close $fh; $c }
            else                               { undef }
        };
        unless ( defined $content ) {
            push @failed, { sidecar => $rel, why => 'unreadable' };
            next;
        }
        my $dest = _store_path($for);
        my $ok   = eval {
            make_path( dirname($dest) ) unless -d dirname($dest);
            if ( -f $dest ) {
                open my $fh, '>>:utf8', $dest or die "append: $!";
                print {$fh} "\n# migrated sidecar content ($rel)\n$content";
                close $fh or die "close: $!";
            }
            else {
                open my $fh, '>:utf8', $dest or die "write: $!";
                print {$fh} $content;
                close $fh or die "close: $!";
            }
            1;
        };
        unless ($ok) {
            push @failed, { sidecar => $rel, why => "$@" };
            next;
        }
        push @imported, $rel;
        if ( unlink $abs ) { push @removed, $rel }
        else {
            push @failed, { sidecar => $rel,
                why => "imported but could not remove ($!) - safe to re-run" };
        }
    }
    log_event( 'INFO', 'briefs', 'sidecar migration',
        imported => scalar @imported, failed => scalar @failed );
    return { ok => 1, imported => \@imported, removed => \@removed,
        failed => \@failed };
}

1;

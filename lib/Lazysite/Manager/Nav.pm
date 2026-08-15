package Lazysite::Manager::Nav;
# SM318: ONE implementation of the site navigation, for both surfaces.
#
# The control API and MCP each had their own. They were not equivalent, and the
# MCP one was the poorer of the two:
#
#                              control API        MCP (before)
#   per-domain nav_file        yes, `host`        hard-coded lazysite/nav.conf
#   reports `inherited`        yes                no
#   content history (SM085)    explicit commit    via the generic file save
#   cache invalidation (SM168) yes, with a count  NONE
#
# The reported defect was the first row: `read_nav` and `set_nav` refused a
# `host`, so an MCP-only account holding manage_nav could not manage navigation
# for any domain except the primary - on an instance whose headline feature is
# many first-class domains (SM151). That refusal is good behaviour (SM278) and it
# was also the whole problem: the agent is told plainly that the thing it needs
# cannot be expressed.
#
# The LAST row was not reported and is worse. The nav is baked into every page's
# rendered HTML, so a nav change is invisible on the live site until each page
# re-renders. SM168 taught the control API to bust the cache and report how many
# pages it refreshed, so the UI could confirm the change was PUBLISHED rather
# than merely saved. An MCP nav edit did none of that: it returned ok:1 and the
# site carried on serving the old menu. That is this project's recurring defect,
# and nobody found it from outside because the file really had been written.
#
# So this is not "add a host parameter". Two implementations of one operation
# will always drift, and the drift is silent by construction - each surface is
# individually consistent. SM301 established the answer when the gap ran the
# other way: one implementation serves both channels, so they cannot answer
# differently.
#
# Context ($DOCROOT, $LAZYSITE_DIR, $auth_user) is set by the caller, as every
# other Manager module does.
use strict;
use warnings;
use File::Basename            qw(dirname);
use File::Path                qw(make_path);
use Lazysite::Manager::Common qw(write_file_checked);
use Lazysite::Manager::Themes qw(action_cache_invalidate);
use Exporter 'import';

our @EXPORT_OK = qw(action_nav_read action_nav_save _nav_conf_info _nav_conf_path);

our $DOCROOT;
our $LAZYSITE_DIR;
our $auth_user;


sub _nav_conf_info {
    my ($host) = @_;
    $host = lc( $host // '' );
    $host = '' if $host eq '(default)';

    my $base = 'lazysite/nav.conf';
    my $over;
    my $conf = "$LAZYSITE_DIR/lazysite.conf";
    if ( -f $conf and open my $fh, '<:utf8', $conf ) {
        while (<$fh>) {
            if (/^nav_file\s*:\s*(.+)/) { ( my $v = $1 ) =~ s/^\s+|\s+$//g; $base = $v if length $v }
            elsif ( length $host
                && /^alias\.\Q$host\E\.nav_file\s*:\s*(.+)/ )
            {
                ( my $v = $1 ) =~ s/^\s+|\s+$//g;
                $over = $v if length $v;
            }
        }
        close $fh;
    }
    my $rel       = defined $over ? $over : $base;
    my $inherited = defined $over ? 0     : ( length $host ? 1 : 0 );
    return ( "$DOCROOT/$rel", $rel, $inherited, $base );
}

sub _nav_conf_path {
    my ($host) = @_;
    my ($path) = _nav_conf_info($host);
    return $path;
}

sub action_nav_read {
    my ($host) = @_;
    my ( $path, $rel, $inherited ) = _nav_conf_info($host);
    my @items;

    if ( -f $path ) {
        open my $fh, '<:utf8', $path or return { ok => 0, error => "Cannot read nav" };
        my $current_parent = -1;
        while (<$fh>) {
            chomp;
            next if /^\s*#/ || /^\s*$/;

            my $is_child = /^\s+/;
            s/^\s+|\s+$//g;

            my ( $label, $url ) = split /\s*\|\s*/, $_, 2;
            $label //= '';
            $url   //= '';
            $label =~ s/^\s+|\s+$//g;
            $url   =~ s/^\s+|\s+$//g;
            next unless length $label;

            if ( $is_child && $current_parent >= 0 ) {
                push @{ $items[$current_parent]{children} },
                    { label => $label, url => $url };
            } else {
                push @items, { label => $label, url => $url, children => [] };
                $current_parent = $#items;
            }
        }
        close $fh;
    }

    # Return the DOCROOT-RELATIVE path only - never the server-absolute one. The
    # absolute path leaked the filesystem layout + the system username to token
    # clients (e.g. /home/<user>/web/.../nav.conf). $rel is the relative form,
    # same value already carried in nav_file.
    return { ok => 1, items => \@items, path => $rel,
        nav_file => $rel, inherited => $inherited };
}

sub action_nav_save {
    my ( $items, $host ) = @_;
    my $path = _nav_conf_path($host);

    my $content = "# lazysite navigation\n";
    $content .= "# Format: Label | /url\n";
    $content .= "# Indent child items with any whitespace\n\n";

    for my $item (@$items) {
        my $label = $item->{label} // '';
        my $url   = $item->{url}   // '';
        $label =~ s/^\s+|\s+$//g;
        $url   =~ s/^\s+|\s+$//g;
        next unless length $label;

        if ( length $url ) {
            $content .= "$label | $url\n";
        } else {
            $content .= "$label\n";
        }

        for my $child ( @{ $item->{children} // [] } ) {
            my $cl = $child->{label} // '';
            my $cu = $child->{url}   // '';
            $cl =~ s/^\s+|\s+$//g;
            $cu =~ s/^\s+|\s+$//g;
            next unless length $cl;
            $content .= "  $cl | $cu\n";
        }
    }

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ( $wok, $werr ) = write_file_checked( $path, $content );
    return { ok => 0, error => "Cannot write nav: $werr" } unless $wok;

    # SM085: nav.conf is one of the two versioned config files - a nav save is
    # a content-history commit (instant no-op when git history is off).
    ( my $nav_rel = $path ) =~ s{^\Q$DOCROOT\E/+}{};
    require Lazysite::Git;
    Lazysite::Git::commit_paths( $DOCROOT, $auth_user, "edit $nav_rel", $nav_rel );

    # SM168: the nav is baked into every page's rendered HTML, so a nav change is
    # invisible on the live site until each page re-renders. Theme/layout changes
    # already bust the render cache; do the same here so the new menu takes effect
    # right away, and report how many cached pages were refreshed so the UI can
    # confirm the change is published (not just saved to the file).
    my $inv = action_cache_invalidate('*');
    return { ok => 1, cache_cleared => ( ref $inv eq 'HASH' ? ( $inv->{count} // 0 ) : 0 ) };
}
1;

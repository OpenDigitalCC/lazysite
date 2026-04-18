#!/usr/bin/perl
# lazysite-audit - link audit for lazysite docroots
# Reports orphaned pages (exist but not linked) and broken links
#
# Usage: perl lazysite-audit.pl [options] [docroot]
#
# Options:
#   --exclude path,path,...   comma-separated canonical paths to exclude
#   --exclude-file FILE       file containing one exclusion per line
#   --scan                    write Markdown report and output JSON
#   --describe                print plugin descriptor JSON and exit
#   --docroot PATH            set docroot explicitly

use strict;
use warnings;
use File::Find;
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# --- Image and asset extensions to ignore as link targets ---

my %IGNORE_EXT = map { $_ => 1 } qw(
    svg png jpg jpeg gif webp ico bmp tiff
    pdf zip tar gz bz2 xz
    css js woff woff2 ttf eot
    mp4 mp3 ogg webm
);

# --- Parse arguments ---

my %exclude;
my $DOCROOT;
my $SCAN_MODE = 0;

while ( @ARGV ) {
    my $arg = shift @ARGV;
    if ( $arg eq '--describe' ) {
        print_describe();
        exit 0;
    }
    elsif ( $arg eq '--scan' ) {
        $SCAN_MODE = 1;
    }
    elsif ( $arg eq '--docroot' ) {
        $DOCROOT = shift @ARGV;
    }
    elsif ( $arg eq '--exclude' ) {
        my $list = shift @ARGV or die "Missing value for --exclude\n";
        $exclude{$_} = 1 for split /,/, $list;
    }
    elsif ( $arg eq '--exclude-file' ) {
        my $file = shift @ARGV or die "Missing value for --exclude-file\n";
        open( my $fh, '<', $file ) or die "Cannot read $file: $!\n";
        while (<$fh>) {
            chomp;
            s/^\s+|\s+$//g;
            $exclude{$_} = 1 if length;
        }
        close $fh;
    }
    else {
        $DOCROOT = $arg unless $DOCROOT;
    }
}

$DOCROOT = abs_path( $DOCROOT || '.' );
die "Docroot not found: $DOCROOT\n" unless -d $DOCROOT;

# Always exclude these from orphan report
$exclude{'404'} = 1;
$exclude{''}    = 1;

# --- Main ---

my $results = collect_audit_results();

if ( $SCAN_MODE ) {
    run_scan($results);
}
else {
    print_report($results);
}

# --- Collect results ---

sub collect_audit_results {
    my %pages;
    my %sources;

    find( sub {
        return unless -f;
        return unless /\.(md|url)$/;
        my $rel = $File::Find::name;
        $rel =~ s{^\Q$DOCROOT\E/}{};
        return if $rel =~ m{^lazysite/};
        return if $rel =~ m{(^|/)\.};
        my $canon = canonical($rel);
        $pages{$canon}   = 1;
        $sources{$canon} = $rel;
    }, $DOCROOT );

    my %inbound;
    my %outbound;

    find( sub {
        return unless -f && /\.md$/;
        my $rel = $File::Find::name;
        $rel =~ s{^\Q$DOCROOT\E/}{};
        return if $rel =~ m{^lazysite/};
        return if $rel =~ m{(^|/)\.};
        extract_links( $File::Find::name, $rel, \%inbound, \%outbound );
    }, $DOCROOT );

    find( sub {
        return unless -f && /\.url$/;
        my $rel = $File::Find::name;
        $rel =~ s{^\Q$DOCROOT\E/}{};
        return if $rel =~ m{(^|/)\.};
        ( my $html_path = $File::Find::name ) =~ s/\.url$/.html/;
        if ( -f $html_path ) {
            extract_links( $html_path, $rel, \%inbound, \%outbound );
        }
    }, $DOCROOT );

    if ( -d "$DOCROOT/lazysite/templates" ) {
        find( sub {
            return unless -f && /\.tt$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/}{};
            return if $rel =~ m{(^|/)\.};
            extract_links( $File::Find::name, $rel, \%inbound, \%outbound );
        }, "$DOCROOT/lazysite/templates" );
    }

    my @orphans;
    for my $canon ( sort keys %pages ) {
        next if $exclude{$canon};
        push @orphans, $canon unless $inbound{$canon};
    }

    my %seen_broken;
    my @broken;
    for my $source ( sort keys %outbound ) {
        for my $target ( @{ $outbound{$source} } ) {
            next if $pages{$target};
            ( my $with_index = $target ) =~ s{/index$}{};
            next if $pages{$with_index};
            next if $seen_broken{"$source->$target"}++;
            push @broken, { source => $source, target => $target };
        }
    }

    return {
        pages    => \%pages,
        sources  => \%sources,
        broken   => \@broken,
        orphaned => \@orphans,
    };
}

# --- Scan mode ---

sub run_scan {
    my ($results) = @_;

    my $report_dir = "$DOCROOT/editor";
    make_path($report_dir) unless -d $report_dir;

    my $report_path = "$report_dir/audit-report.md";
    my $report_url  = '/editor/audit-report';

    write_audit_report( $report_path, $results );

    my $cache = "$report_dir/audit-report.html";
    unlink $cache if -f $cache;

    require JSON::PP;
    print JSON::PP::encode_json({
        ok         => 1,
        report_url => $report_url,
        broken     => scalar @{ $results->{broken} },
        orphaned   => scalar @{ $results->{orphaned} },
    });
}

sub write_audit_report {
    my ( $path, $results ) = @_;

    require POSIX;
    my $now     = POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $now_iso = POSIX::strftime( '%Y-%m-%dT%H:%M:%S', localtime );

    my $broken   = $results->{broken}   // [];
    my $orphaned = $results->{orphaned} // [];
    my $b_count  = scalar @$broken;
    my $o_count  = scalar @$orphaned;

    my $md = "---\ntitle: Link Audit Report\nsubtitle: $now\ndate: $now_iso\n";
    $md .= "auth: required\nauth_groups:\n  - lazysite-admins\nsearch: false\n---\n\n";
    $md .= "## Summary\n\nAudit completed: $now\n\n";

    if ( $b_count == 0 && $o_count == 0 ) {
        $md .= "::: widebox\nNo broken links or orphaned pages found.\n:::\n";
    }
    else {
        $md .= "- $b_count broken link(s) found\n";
        $md .= "- $o_count orphaned page(s) found\n";
    }

    if ( $b_count > 0 ) {
        $md .= "\n## Broken internal links\n\n";
        $md .= "| Page | Broken link | Edit |\n";
        $md .= "| ---- | ----------- | ---- |\n";
        for my $item ( @$broken ) {
            my $page_md = $item->{source};
            $page_md =~ s{^/}{};
            $page_md .= '.md' unless $page_md =~ /\.\w+$/;
            my $edit_url = "/editor/edit?path=" . uri_encode("/$page_md");
            $md .= "| $item->{source} | /$item->{target} | [Edit]($edit_url) |\n";
        }
    }

    if ( $o_count > 0 ) {
        $md .= "\n## Orphaned pages\n\n";
        $md .= "Pages that exist but are not linked from any other page.\n\n";
        for my $page ( @$orphaned ) {
            my $page_md = $page;
            $page_md .= '.md' unless $page_md =~ /\.\w+$/;
            my $edit_url = "/editor/edit?path=" . uri_encode("/$page_md");
            $md .= "- /$page - [Edit]($edit_url)\n";
        }
    }

    open my $fh, '>:utf8', $path or die "Cannot write report: $!\n";
    print $fh $md;
    close $fh;
}

# --- CLI report ---

sub print_report {
    my ($results) = @_;
    my $broken   = $results->{broken};
    my $orphaned = $results->{orphaned};
    my $pages    = $results->{pages};
    my $sources  = $results->{sources};

    print "lazysite link audit: $DOCROOT\n";
    print "=" x 60 . "\n\n";

    print "ORPHANED PAGES (" . scalar(@$orphaned) . ")\n";
    print "Exist but are not linked from any scanned file.\n\n";
    if (@$orphaned) {
        printf "  %-40s  %s\n", "/$_", $sources->{$_} // '' for @$orphaned;
    }
    else { print "  None found.\n"; }

    print "\nBROKEN LINKS (" . scalar(@$broken) . ")\n";
    print "Links pointing to pages that do not exist.\n\n";
    if (@$broken) {
        for my $b ( sort { $a->{source} cmp $b->{source} } @$broken ) {
            printf "  %-40s  -> /%s\n", $b->{source}, $b->{target};
        }
    }
    else { print "  None found.\n"; }

    print "\nSUMMARY\n";
    printf "  Source pages:    %d\n", scalar keys %$pages;
    printf "  Orphaned:        %d\n", scalar @$orphaned;
    printf "  Broken links:    %d\n", scalar @$broken;
    print "\n";
}

# --- Plugin descriptor ---

sub print_describe {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'link-audit',
        name        => 'Link Audit',
        description => 'Scan for broken internal links and orphaned pages',
        version     => '1.0',
        config_file => '',
        config_schema => [],
        actions     => [
            {
                id          => 'run',
                label       => 'Run audit',
                confirm     => 'This will scan all pages and may take a moment on large sites.',
                endpoint    => 'plugin-action',
                on_complete => 'open_url',
                result_key  => 'report_url',
            }
        ],
    });
}

# --- Utilities ---

sub canonical {
    my ($rel) = @_;
    $rel =~ s/\.(md|url|html)$//;
    $rel =~ s{/index$}{};
    $rel =~ s{^index$}{};
    $rel =~ s{/$}{};
    return $rel;
}

sub extract_links {
    my ( $path, $label, $inbound, $outbound ) = @_;

    open( my $fh, '<:utf8', $path ) or return;
    my $content = do { local $/; <$fh> };
    close $fh;

    my @raw_links;
    while ( $content =~ /\[(?:[^\]]*)\]\(([^)]+)\)/g ) {
        push @raw_links, $1;
    }
    while ( $content =~ /(?:href|src)\s*=\s*["']([^"']+)["']/g ) {
        push @raw_links, $1;
    }

    for my $link (@raw_links) {
        next if $link =~ /\[%/;
        next if $link =~ m{^https?://};
        next if $link =~ m{^mailto:};
        next if $link =~ m{^#};
        next if $link =~ m{^data:};

        $link =~ s/[?#].*$//;
        next unless length $link;

        if ( $link =~ /\.(\w+)$/ ) {
            next if $IGNORE_EXT{ lc($1) };
        }

        $link =~ s{^/}{};
        next if $link =~ m{^assets/};

        $link =~ s/\.(html|md|url)$//;
        $link =~ s{/$}{};
        next unless length $link;

        push @{ $inbound->{$link} },  $label;
        push @{ $outbound->{$label} }, $link;
    }
}

sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^a-zA-Z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

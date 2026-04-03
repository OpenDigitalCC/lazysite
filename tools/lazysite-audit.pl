#!/usr/bin/perl
# lazysite-audit - link audit for lazysite docroots
# Reports orphaned pages (exist but not linked) and broken links
#
# Usage: perl lazysite-audit.pl [options] [docroot]
#
# Options:
#   --exclude path,path,...   comma-separated canonical paths to exclude
#                             from orphan report e.g. --exclude index,404
#   --exclude-file FILE       file containing one exclusion per line
#
# Docroot defaults to current directory if not given.

use strict;
use warnings;
use File::Find;
use File::Basename qw(dirname basename);
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

while ( my $arg = shift @ARGV ) {
    if ( $arg eq '--exclude' ) {
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
        $DOCROOT = $arg;
    }
}

$DOCROOT = abs_path( $DOCROOT || '.' );
die "Docroot not found: $DOCROOT\n" unless -d $DOCROOT;

# Always exclude these from orphan report
$exclude{'404'} = 1;
$exclude{''}    = 1;  # index (root page)

# --- Collect all source pages ---

my %pages;    # canonical path -> 1  e.g. 'about', 'docs/install'
my %sources;  # canonical path -> source file

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

# --- Collect all links ---

my %inbound;   # canonical target -> [ list of source files ]
my %outbound;  # source file -> [ list of canonical targets ]

# Scan .md files
find( sub {
    return unless -f && /\.md$/;

    my $rel = $File::Find::name;
    $rel =~ s{^\Q$DOCROOT\E/}{};
    return if $rel =~ m{^lazysite/};
    return if $rel =~ m{(^|/)\.};

    extract_links( $File::Find::name, $rel );

}, $DOCROOT );

# Scan .url files - use cached .html counterpart
find( sub {
    return unless -f && /\.url$/;

    my $rel = $File::Find::name;
    $rel =~ s{^\Q$DOCROOT\E/}{};
    return if $rel =~ m{(^|/)\.};

    ( my $html_path = $File::Find::name ) =~ s/\.url$/.html/;
    if ( -f $html_path ) {
        ( my $html_rel = $rel ) =~ s/\.url$/.html/;
        extract_links( $html_path, $rel );
    }

}, $DOCROOT );

# Scan all .tt files under lazysite/templates/
find( sub {
    return unless -f && /\.tt$/;

    my $rel = $File::Find::name;
    $rel =~ s{^\Q$DOCROOT\E/}{};
    return if $rel =~ m{(^|/)\.};

    extract_links( $File::Find::name, $rel );

}, "$DOCROOT/lazysite/templates" ) if -d "$DOCROOT/lazysite/templates";

# --- Identify orphaned pages ---

my @orphans;
for my $canon ( sort keys %pages ) {
    next if $exclude{$canon};
    push @orphans, $canon unless $inbound{$canon};
}

# --- Identify broken links ---

my %seen_broken;
my @broken;

for my $source ( sort keys %outbound ) {
    for my $target ( @{ $outbound{$source} } ) {
        # Check direct match
        next if $pages{$target};
        # Check if target/index exists (e.g. docs/index -> docs)
        ( my $with_index = $target ) =~ s{/index$}{};
        next if $pages{$with_index};
        next if $seen_broken{"$source->$target"}++;
        push @broken, { source => $source, target => $target };
    }
}

# --- Report ---

print "lazysite link audit: $DOCROOT\n";
print "=" x 60 . "\n\n";

print "ORPHANED PAGES (" . scalar(@orphans) . ")\n";
print "Exist but are not linked from any scanned file.\n\n";

if (@orphans) {
    for my $canon (@orphans) {
        printf "  %-40s  %s\n", "/$canon", $sources{$canon};
    }
}
else {
    print "  None found.\n";
}

print "\n";
print "BROKEN LINKS (" . scalar(@broken) . ")\n";
print "Links pointing to pages that do not exist.\n\n";

if (@broken) {
    for my $b ( sort { $a->{source} cmp $b->{source} } @broken ) {
        printf "  %-40s  -> /%s\n", $b->{source}, $b->{target};
    }
}
else {
    print "  None found.\n";
}

print "\n";
print "SUMMARY\n";
printf "  Source pages:    %d\n", scalar keys %pages;
printf "  Orphaned:        %d\n", scalar @orphans;
printf "  Broken links:    %d\n", scalar @broken;
print "\n";

# --- Functions ---

sub canonical {
    my ($rel) = @_;
    $rel =~ s/\.(md|url|html)$//;
    $rel =~ s{/index$}{};   # docs/index -> docs
    $rel =~ s{^index$}{};   # index -> ''  (root)
    $rel =~ s{/$}{};
    return $rel;
}

sub extract_links {
    my ( $path, $label ) = @_;

    open( my $fh, '<:utf8', $path ) or return;
    my $content = do { local $/; <$fh> };
    close $fh;

    my @raw_links;

    # Markdown links [text](url)
    while ( $content =~ /\[(?:[^\]]*)\]\(([^)]+)\)/g ) {
        push @raw_links, $1;
    }

    # HTML href and src attributes
    while ( $content =~ /(?:href|src)\s*=\s*["']([^"']+)["']/g ) {
        push @raw_links, $1;
    }

    for my $link (@raw_links) {
        # Skip TT variables - can't resolve statically
        next if $link =~ /\[%/;

        # Skip external, mailto, fragment, data URIs
        next if $link =~ m{^https?://};
        next if $link =~ m{^mailto:};
        next if $link =~ m{^#};
        next if $link =~ m{^data:};

        # Strip query string and fragment
        $link =~ s/[?#].*$//;

        # Skip empty
        next unless length $link;

        # Check extension - skip assets and images
        if ( $link =~ /\.(\w+)$/ ) {
            next if $IGNORE_EXT{ lc($1) };
        }

        # Strip leading slash
        $link =~ s{^/}{};

        # Skip asset paths
        next if $link =~ m{^assets/};

        # Normalise
        $link =~ s/\.(html|md|url)$//;
        $link =~ s{/$}{};

        next unless length $link;

        push @{ $inbound{$link} },  $label;
        push @{ $outbound{$label} }, $link;
    }
}

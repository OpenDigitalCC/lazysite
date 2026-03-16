#!/usr/bin/perl
use strict;
use warnings;
use Text::MultiMarkdown qw(markdown);
use Template;
use File::Basename qw(dirname);
use File::Path qw(make_path);

# --- Configuration ---

my $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

my $LAYOUT = "$DOCROOT/templates/layout.tt";

# --- Main ---

main();

sub main {
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Strip query string
    $uri =~ s/\?.*$//;

    # Sanitise URI against path traversal
    my $base = sanitise_uri($uri);
    unless ( defined $base ) {
        not_found($uri);
        return;
    }

    my $md_path   = "$DOCROOT/$base.md";
    my $html_path = "$DOCROOT/$base.html";

    # Serve from cache if fresh
    if ( is_fresh( $html_path, $md_path ) ) {
        output_page( read_file($html_path) );
        return;
    }

    # Found .md - process it
    if ( -f $md_path ) {
        my $page = process_md( $md_path, $html_path );
        output_page($page);
        return;
    }

    # No .md found - serve 404 page
    not_found($uri);
}

# --- Processing ---

sub sanitise_uri {
    my ($uri) = @_;

    # Strip leading slash and extension
    $uri =~ s{^/}{};
    $uri =~ s/\.(html|md)$//;

    # Reject null bytes
    return undef if $uri =~ /\0/;

    # Reject path traversal sequences
    return undef if $uri =~ m{(?:^|/)\.\.(?:/|$)};

    # Reject absolute paths or suspicious characters
    return undef if $uri =~ m{^/};
    return undef if $uri =~ m{[<>"'\\]};

    # Empty uri means docroot index
    $uri = 'index' unless length $uri;

    return $uri;
}

sub process_md {
    my ( $md_path, $html_path ) = @_;

    my $raw             = read_file($md_path);
    my ( $meta, $body ) = parse_yaml_front_matter($raw);
    my $converted       = convert_fenced_divs($body);
    my $html_body       = convert_md($converted);
    my $page            = render_template( $meta, $html_body );

    write_html( $html_path, $page );

    return $page;
}

sub is_fresh {
    my ( $html_path, $md_path ) = @_;
    return 0 unless -f $html_path;
    return 0 unless -f $md_path;
    return ( stat($html_path) )[9] >= ( stat($md_path) )[9];
}

sub parse_yaml_front_matter {
    my ($text) = @_;
    my %meta;

    if ( $text =~ s/\A---\s*\n(.*?)\n---\s*\n//s ) {
        my $yaml = $1;
        while ( $yaml =~ /^(\w+)\s*:\s*(.+)$/mg ) {
            $meta{$1} = $2;
        }
    }

    return ( \%meta, $text );
}

sub convert_fenced_divs {
    my ($text) = @_;

    $text =~ s{
        ^:::[ \t]+(\S+)[ \t]*\n  # opening ::: classname
        (.*?)                     # content
        ^:::[ \t]*\n              # closing :::
    }{<div class="$1">\n$2</div>\n}gsmx;

    return $text;
}

sub convert_md {
    my ($body) = @_;
    return markdown($body);
}

sub render_template {
    my ( $meta, $html_body ) = @_;

    my $tt = Template->new(
        ABSOLUTE => 1,
        ENCODING => 'utf8',
    ) or die "Template error: " . Template->error() . "\n";

    my $vars = {
        page_title    => $meta->{title}    || '',
        page_subtitle => $meta->{subtitle} || '',
        content       => $html_body,
    };

    my $output = '';
    $tt->process( $LAYOUT, $vars, \$output )
        or die "Template process error: " . $tt->error() . "\n";

    return $output;
}

sub write_html {
    my ( $html_path, $page ) = @_;

    my $dir = dirname($html_path);
    make_path($dir) unless -d $dir;

    open( my $fh, '>:utf8', $html_path ) or die "Cannot write $html_path: $!\n";
    print $fh $page;
    close $fh;
}

# --- Output ---

sub output_page {
    my ($content) = @_;
    print "Content-type: text/html\n\n";
    print $content;
}

sub not_found {
    my ($uri) = @_;

    my $md_path   = "$DOCROOT/404.md";
    my $html_path = "$DOCROOT/404.html";

    if ( -f $md_path ) {
        my $page = is_fresh( $html_path, $md_path )
            ? read_file($html_path)
            : process_md( $md_path, $html_path );
        print "Content-type: text/html\n\n";
        print $page;
        return;
    }

    # Bare fallback if no 404.md exists yet
    print "Content-type: text/html\n\n";
    print "<p>Page not found: <code>$uri</code></p>\n";
}

# --- Utilities ---

sub read_file {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

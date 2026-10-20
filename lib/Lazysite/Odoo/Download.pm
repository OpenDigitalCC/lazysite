package Lazysite::Odoo::Download;

# SM1225 (ruled 2026-10-20, "OOM Lab questions"): A REPORT IS A DOWNLOAD.
# "build the download route (a binding option answering the report as a GET with its
# content type and a size cap; replaces base64-in-JSON; covers the quotation PDF and
# L-22)". L-22: a payslip PDF came back as about 31 KB of base64 in one JSON answer,
# which "works at this size; a large report would want a download route".
#
# A binding with `answer: download` is answered, to a GET, with the DOCUMENT its
# operation returned - OOM's core.report with inline=1 (0.32+) puts each document in
# report.rows[] as content_base64 with name, mimetype and bytes. Everything before the
# answer is the call's own, unchanged: the gate (mode, callers, session or visitor
# key), the rate caps, the record and the audit. This module only turns the report the
# call returned into a response, and it is the same for the in-process path and for
# oomd, because both hand back the same report.
#
# WHAT THE RESPONSE IS:
#   Content-Type         from OOM (mimetype), checked to be a type/subtype name; anything
#                        else is application/octet-stream
#   Content-Disposition  attachment, or inline where the binding says so AND the type is
#                        one a browser shows without running anything of ours (a pdf,
#                        an image, plain text); html is always an attachment
#   filename             made safe: no path, no quote, no control character, no ';',
#                        ASCII only, at most 100 characters
#   Content-Length       of the bytes
#   Cache-Control        private, no-store - it is one person's document
#   X-Content-Type-Options: nosniff, and a sandbox Content-Security-Policy
#
# THE CAP: `download_max_kb` on the binding (default 10240, at most 20480). A document
# over it is REFUSED with a JSON too-large error that names the size and the cap; it is
# never cut short. The size is read from the base64's length before it is decoded.
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);

our $DEFAULT_MAX_KB = 10 * 1024;
our $CEILING_KB     = 20 * 1024;

my $MIME = qr{\A[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*\z};
my %INLINE_OK = map { $_ => 1 } qw(application/pdf image/png image/jpeg image/gif image/webp text/plain);
my %EXT = ( 'application/pdf' => 'pdf', 'text/html' => 'html', 'text/plain' => 'txt', 'image/png' => 'png',
    'image/jpeg' => 'jpg' );

sub max_bytes {
    my ($b) = @_;
    my $kb = ( ref $b eq 'HASH' && $b->{download_max_kb} ) ? $b->{download_max_kb} : $DEFAULT_MAX_KB;
    return $kb * 1024;
}

# The file name as it may appear in a header: the last part of any path, ASCII
# letters, digits and a few joiners, nothing that ends the quoted string or the header.
sub safe_name {
    my ( $name, $mime ) = @_;
    my $n = defined $name ? "$name" : '';
    $n =~ s{\A.*[/\\]}{}s;                  # no path, either separator
    $n =~ s/[^A-Za-z0-9._ -]+/_/g;          # quotes, ;, CR, LF, controls, non-ASCII, % and the rest
    $n =~ s/\A[ .]+//;                      # no hidden file, no leading space
    $n =~ s/[ .]+\z//;
    $n =~ s/_{2,}/_/g;
    $n = substr( $n, 0, 100 );
    $n = 'report' . ( $EXT{ $mime // '' } ? ".$EXT{$mime}" : '' ) unless length $n && $n =~ /[A-Za-z0-9]/;
    return $n;
}

# response( \%binding, \%answer ) -> { ok => 1, headers => [...], body => $bytes }
#                                 or { ok => 0, kind, error }
# %answer is the engine's answer to the call ({ ok => 1, report => {...} }).
sub response {
    my ( $b, $r ) = @_;
    my $rows = ( ref $r->{report} eq 'HASH' && ref $r->{report}{rows} eq 'ARRAY' ) ? $r->{report}{rows} : [];
    return _no( 'invalid',
        'this binding answers a download, and its operation did not return exactly one document '
            . '(a report with inline=1 and one record does)' )
        unless @$rows == 1 && ref $rows->[0] eq 'HASH';
    my $row = $rows->[0];
    my $b64 = $row->{content_base64};
    return _no( 'invalid', 'this binding answers a download, and its operation returned no document content (content_base64)' )
        unless defined $b64 && !ref $b64 && length $b64;

    $b64 =~ s/\s+//g;
    my $cap  = max_bytes($b);
    my $size = int( length($b64) * 3 / 4 ) - ( $b64 =~ /==\z/ ? 2 : $b64 =~ /=\z/ ? 1 : 0 );
    return _no( 'too-large',
        "the document is $size bytes; this binding sends at most " . ( $cap / 1024 ) . ' KB (download_max_kb)' )
        if $size > $cap;
    my $bytes = decode_base64($b64);
    return _no( 'too-large',
        'the document is ' . length($bytes) . ' bytes; this binding sends at most ' . ( $cap / 1024 ) . ' KB (download_max_kb)' )
        if length $bytes > $cap;

    my $mime = lc( $row->{mimetype} // '' );
    $mime = 'application/octet-stream' unless $mime =~ $MIME;
    my $disp = ( ( $b->{download_disposition} // 'attachment' ) eq 'inline' && $INLINE_OK{$mime} ) ? 'inline' : 'attachment';
    my $file = safe_name( $row->{name}, $mime );
    return {
        ok      => 1,
        body    => $bytes,
        headers => [
            "Content-Type: $mime",
            qq{Content-Disposition: $disp; filename="$file"},
            'Content-Length: ' . length($bytes),
            'Cache-Control: private, no-store',
            'X-Content-Type-Options: nosniff',
            "Content-Security-Policy: sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:",
        ],
    };
}

sub _no { return { ok => 0, kind => $_[0], error => $_[1] } }

1;

package Lazysite::Odoo::Upload;

# SM1162: A BINDING TAKES A FILE - the multipart half of the Odoo endpoint.
#
# WHY ITS OWN MODULE. The endpoint's cold path is light (SM1147): `?csrf=1`
# answers from two cookies. Reading a multipart body, with its limits, is needed
# only by a request that carries a file, so it is loaded only by that request.
#
# THE SHAPE OF THE REQUEST. POST to the endpoint with `?binding=ID` in the query
# (the binding must be known BEFORE the body is read: its cap, file_max_kb, is
# what the declared CONTENT_LENGTH is held to), content type multipart/form-data:
#
#   json         the JSON body a request carries today ({params, visitor_token,
#                token}); at most $JSON_LIMIT bytes, the limit the JSON body has
#   <field>      one part per file, named as the binding's file_params name the
#                request's file field, with a filename; a list repeats the name
#
# Anything else - a plain text part, a part with no name, a duplicate json part -
# is refused: a part that is not understood is not ignored, because what is
# ignored is what nobody checked.
#
# NOTHING IS WRITTEN. The body is held in memory while it is parsed and the bytes
# go to the operation from there: no temporary file exists to be left behind by a
# refusal or a death, and nothing is written under the docroot or anywhere else.
use strict;
use warnings;

# The JSON part: the endpoint's JSON body limit (lazysite-odoo.pl) stays 64 KB.
our $JSON_LIMIT = 64 * 1024;

# The most a multipart body may ever be, whatever a binding says: a request is
# held in memory. One file is at most Binding::FILE_CEILING_KB (20 MB).
our $MAX_BODY = 32 * 1024 * 1024;

# What the framing of a body adds to its files and JSON: the boundary lines and
# each part's headers. Generous per part; a body longer than the cap plus this is
# not a body of that binding's files.
our $PART_OVERHEAD = 2048;
our $MAX_PARTS     = 12;     # the json part and up to ten files, and one to spare

# is_multipart( $content_type ) -> boundary or undef
sub boundary {
    my ($ct) = @_;
    return undef unless defined $ct && $ct =~ m{\Amultipart/form-data\b}i;
    my ( $q, $u ) = $ct =~ m{;\s*boundary=(?:"([^"]{1,70})"|([^\s;"]{1,70}))}i;
    my $bnd = $q // $u;
    return ( defined $bnd && length $bnd ) ? $bnd : undef;
}

# allowance( $cap_bytes, $max_files ) -> the most a body for those files may be:
# the files at their cap, the JSON part, and the framing - never above $MAX_BODY.
sub allowance {
    my ( $cap, $files ) = @_;
    my $n = $cap * $files + $JSON_LIMIT + $PART_OVERHEAD * ( $files + 2 );
    return $n > $MAX_BODY ? $MAX_BODY : $n;
}

# parse( $body, $boundary ) -> ( { json => $text, files => { field => [ {name, bytes, claimed} ] } }, '' )
#                          or ( undef, why )
# Strict: the body is exactly --B CRLF headers CRLF CRLF content CRLF ... --B--.
sub parse {
    my ( $body, $bnd ) = @_;
    my $dash  = "--$bnd";
    my $start = index( $body, "$dash\r\n" );
    return ( undef, 'the body is not multipart/form-data (no opening boundary)' ) unless $start == 0;
    my $end  = "\r\n$dash--";
    my $stop = rindex( $body, $end );
    return ( undef, 'the body is cut short (no closing boundary)' ) if $stop < 0;
    my $inner = substr( $body, length($dash) + 2, $stop - length($dash) - 2 ); # parts only
    my @raw   = split_on( $inner, "\r\n$dash\r\n" );
    return ( undef, "a request holds at most $MAX_PARTS parts" ) if @raw > $MAX_PARTS;
    my ( $json, %files );
    for my $part (@raw) {
        my $sep = index( $part, "\r\n\r\n" );
        return ( undef, 'a part has no header block' ) if $sep < 0;
        my $head    = substr( $part, 0, $sep );
        my $content = substr( $part, $sep + 4 );
        my ($disp)  = $head =~ /^Content-Disposition:[ \t]*(.*)$/mi;
        return ( undef, 'a part has no Content-Disposition' ) unless defined $disp && $disp =~ /\Aform-data\b/i;
        my ($name) = $disp =~ /;\s*name="([^"]*)"/;
        return ( undef, 'a part has no name' ) unless defined $name && length $name;
        my ($file) = $disp =~ /;\s*filename="([^"]*)"/;
        my ($type) = $head =~ /^Content-Type:[ \t]*([^\r\n;]+)/mi;
        if ( !defined $file ) {
            return ( undef, "the part '$name' is not a file: send plain values in the part named json" )
                unless $name eq 'json';
            return ( undef, 'the json part is sent twice' ) if defined $json;
            return ( undef, "the json part is longer than $JSON_LIMIT bytes" ) if length $content > $JSON_LIMIT;
            $json = $content;
            next;
        }
        return ( undef, 'the part named json is a body, not a file' ) if $name eq 'json';
        return ( undef, "the file field '$name' is not a name" ) unless $name =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z/;
        my $fname = $file;
        utf8::decode($fname) or $fname =~ s/[^\x20-\x7e]/_/g;
        return ( undef, "the file field '$name' has no file name" ) unless length $fname;
        push @{ $files{$name} }, { name => $fname, bytes => $content, claimed => $type };
    }
    return ( { json => $json, files => \%files }, '' );
}

# Splits on a literal separator, without regex on binary content.
sub split_on {
    my ( $s, $sep ) = @_;
    my @out;
    my $pos = 0;
    while ( ( my $i = index( $s, $sep, $pos ) ) >= 0 ) {
        push @out, substr( $s, $pos, $i - $pos );
        $pos = $i + length $sep;
    }
    push @out, substr( $s, $pos );
    return @out;
}

1;

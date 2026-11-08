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

# is_multipart( $content_type ) -> boundary or undef. SM1369 X5 (H-4): the
# kit's, so the tokens of the json part are read by core before the endpoint
# runs anything of the extension (t/lint/351).
sub boundary {
    my ($ct) = @_;
    require Lazysite::Endpoint;
    return Lazysite::Endpoint::multipart_boundary($ct);
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
# The kit's strict parser, held to this endpoint's json limit and part count.
sub parse {
    my ( $body, $bnd ) = @_;
    require Lazysite::Endpoint;
    return Lazysite::Endpoint::parse_multipart( $body, $bnd, json_limit => $JSON_LIMIT, max_parts => $MAX_PARTS );
}

1;

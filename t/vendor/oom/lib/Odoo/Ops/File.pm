package Odoo::Ops::File;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use MIME::Base64 qw(encode_base64 decode_base64);

use Odoo::Error;

=head1 NAME

Odoo::Ops::File - the value of a file parameter: bytes, a name and a type, with no path on the host

=head1 SYNOPSIS

    # a program passes bytes in process, or through the daemon client
    { name => 'receipt.jpg', bytes => $raw, mimetype => 'image/jpeg' }

    my $v    = Odoo::Ops::File->check( 'core.attach', 'file', $given, { max_bytes => 5_000_000 } );
    my $slim = Odoo::Ops::File->slim($v);        # { name, bytes => N, sha256, mimetype }: what a plan shows

=head1 DESCRIPTION

A parameter declared C<< { type => 'file', max_bytes => N } > > takes one file
value; C<< { type => 'files', max => 10, max_bytes => N } >> takes a list of
them. The value is a hash with C<name> (a plain file name), C<bytes> (the raw
content) and optionally C<mimetype>. When C<mimetype> is absent it is read from
the first bytes for JPEG, PNG, GIF, WebP and PDF, else
C<application/octet-stream>.

C<check> refuses a value with no bytes, a name that is not a plain file name
(a slash, a NUL, empty, C<.> or C<..>, or over 255 bytes), and bytes over the
declaration's C<max_bytes> (default 25 MB) as C<refused/too-large>, naming the
size and the cap. A text value, which is what C<--set> gives, is refused and
the C<fix> names C<--file>.

C<slim> is the value as a plan, the audit and any output show it: name, size,
SHA-256 and type, never the content. C<to_wire> and C<from_wire> carry a value
over the daemon's JSON lines as C<< { name, base64, mimetype } >>.

=cut

use constant MAX_DEFAULT => 25 * 1024 * 1024;
use constant MAX_FILES   => 10;

sub max_default ($class) { MAX_DEFAULT }

=head2 is_value($v)

True for a hash holding C<name> and a C<bytes> that is a plain string (a value
before C<slim>).

=cut

sub is_value ($class, $v) {
    return 0 if ref $v ne 'HASH' || !exists $v->{bytes} || !defined $v->{bytes} || ref $v->{bytes} || !defined $v->{name} || ref $v->{name};
    return 0 if grep { !/\A(?:name|bytes|mimetype)\z/ } keys %$v;
    return 1;
}

=head2 sniff($bytes)

The mimetype the first bytes show, for JPEG, PNG, GIF, WebP and PDF, else
C<application/octet-stream>.

=cut

sub sniff ($class, $b) {
    return 'image/jpeg' if $b =~ /\A\xFF\xD8\xFF/;
    return 'image/png'  if $b =~ /\A\x89PNG\r\n\x1a\n/;
    return 'image/gif'  if $b =~ /\AGIF8[79]a/;
    return 'image/webp' if $b =~ /\ARIFF....WEBP/s;
    return 'application/pdf' if $b =~ /\A%PDF-/;
    return 'application/octet-stream';
}

sub _bad_name ($name) {
    my $n = $name;
    utf8::encode($n) if utf8::is_utf8($n);
    return 'is empty' if !length $n;
    return 'has a slash' if $n =~ m{[/\\]};
    return 'has a NUL' if $n =~ /\0/;
    return 'is . or ..' if $n eq '.' || $n eq '..';
    return 'is over 255 bytes' if length $n > 255;
    return undef;
}

=head2 check($op, $name, $value, \%decl)

The value normalised to C<< { name, bytes, mimetype } >>, or a usage or
C<refused/too-large> error naming the parameter.

=cut

sub check ($class, $op, $k, $v, $decl = {}) {
    my $fix = "give a file value { name, bytes, mimetype? }; on the command line use --file $k=PATH, never --set";
    if ( ref $v eq 'ARRAY' ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' takes one file, not a list", fix => $fix );
    }
    if ( ref $v ne 'HASH' ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' is a file, not a text value", fix => $fix );
    }
    if ( exists $v->{base64} && !exists $v->{bytes} ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' holds base64 where bytes are expected", fix => $fix );
    }
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has no bytes", fix => $fix )
        if !defined $v->{bytes} || ref $v->{bytes} || !length $v->{bytes};
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has no name", fix => $fix ) if !defined $v->{name} || ref $v->{name};
    for my $key ( keys %$v ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' holds an unknown key '$key' (a file takes name, bytes, mimetype)", fix => $fix )
            if $key !~ /\A(?:name|bytes|mimetype)\z/;
    }
    if ( my $why = _bad_name( $v->{name} ) ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k': the file name $why",
            fix => 'a file name is a plain name: no slash, no NUL, at most 255 bytes' );
    }
    my $max = $decl->{max_bytes} // MAX_DEFAULT;
    my $size = length $v->{bytes};
    Odoo::Error->throw( kind => 'refused', code => 'too-large',
        message => "$op: parameter '$k' is $size bytes; the limit is $max (max_bytes)",
        fix => 'send a smaller file, or raise max_bytes where the operation takes it' ) if $size > $max;
    my $mime = defined $v->{mimetype} && !ref $v->{mimetype} && length $v->{mimetype} ? "$v->{mimetype}" : $class->sniff( $v->{bytes} );
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k': the mimetype is not a type/subtype", fix => $fix )
        if $mime !~ m{\A[\w.+-]+/[\w.+-]+\z};
    return { name => "$v->{name}", bytes => $v->{bytes}, mimetype => $mime };
}

=head2 check_list($op, $name, $value, \%decl)

A list of file values, each checked; at most C<max> (default 10).

=cut

sub check_list ($class, $op, $k, $v, $decl = {}) {
    $v = [$v] if $class->is_value($v);
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' is a list of files, not a text value",
        fix => "give a list of file values; on the command line repeat --file $k=PATH" ) if ref $v ne 'ARRAY';
    my $max = $decl->{max} // MAX_FILES;
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has " . scalar(@$v) . " files; at most $max are allowed" ) if @$v > $max;
    my $i = 0;
    return [ map { $class->check( $op, "$k\[" . $i++ . ']', $_, $decl ) } @$v ];
}

=head2 slim($value)

C<< { name, bytes => N, sha256, mimetype } >>: a file as a plan shows it.

=cut

sub slim ($class, $v) {
    return { name => $v->{name}, bytes => length( $v->{bytes} ) + 0, sha256 => Digest::SHA::sha256_hex( $v->{bytes} ), mimetype => $v->{mimetype} // $class->sniff( $v->{bytes} ) };
}

=head2 slim_params($data)

C<$data> with every file value replaced by its C<slim> form, at any depth
(a new structure; the argument is not changed).

=cut

sub slim_params ($class, $d) {
    return $class->slim($d) if $class->is_value($d);
    return { map { $_ => $class->slim_params( $d->{$_} ) } keys %$d } if ref $d eq 'HASH';
    return [ map { $class->slim_params($_) } @$d ] if ref $d eq 'ARRAY';
    return $d;
}

=head2 base64($value)

The bytes as base64 on one line, the form Odoo's C<datas> takes.

=cut

sub base64 ($class, $v) { return encode_base64( $v->{bytes}, '' ) }

=head2 to_wire($data) and from_wire($data)

A file value as the daemon's JSON carries it, C<< { name, base64, mimetype } >>,
and back. Both walk the whole structure.

=cut

sub to_wire ($class, $d) {
    if ( $class->is_value($d) ) {
        return { name => $d->{name}, base64 => encode_base64( $d->{bytes}, '' ), ( defined $d->{mimetype} ? ( mimetype => $d->{mimetype} ) : () ) };
    }
    return { map { $_ => $class->to_wire( $d->{$_} ) } keys %$d } if ref $d eq 'HASH';
    return [ map { $class->to_wire($_) } @$d ] if ref $d eq 'ARRAY';
    return $d;
}

sub from_wire ($class, $d) {
    if ( ref $d eq 'HASH' && defined $d->{name} && !ref $d->{name} && defined $d->{base64} && !ref $d->{base64}
        && !grep { !/\A(?:name|base64|mimetype)\z/ } keys %$d )
    {
        Odoo::Error->throw( kind => 'usage', message => "a file named '$d->{name}' does not hold base64", fix => 'send the bytes as base64 text' )
            if $d->{base64} !~ m{\A[A-Za-z0-9+/=\s]*\z};
        return { name => $d->{name}, bytes => decode_base64( $d->{base64} ), ( defined $d->{mimetype} ? ( mimetype => $d->{mimetype} ) : () ) };
    }
    return { map { $_ => $class->from_wire( $d->{$_} ) } keys %$d } if ref $d eq 'HASH';
    return [ map { $class->from_wire($_) } @$d ] if ref $d eq 'ARRAY';
    return $d;
}

1;

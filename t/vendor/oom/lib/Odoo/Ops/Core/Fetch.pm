package Odoo::Ops::Core::Fetch;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC);
use File::Path qw(make_path);
use File::Spec;
use MIME::Base64 qw(decode_base64);

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Fetch - write a record's attachments to files

=head1 SYNOPSIS

    oom-ops run core.fetch --conf C --set model=res.partner --set record=ref=C001 --set dir=out/

=head1 DESCRIPTION

C<core.fetch> reads the attachments of one record (or one attachment by
id) and writes each to a file under C<dir> (created mode 0700 when
absent), mode 0600, named by the attachment's name made safe: the base
name only, anything outside letters, digits, C<.>, C<_>, C<-> and space
turned into C<_>, no leading dot. A file already there is not
overwritten unless C<overwrite> is on.

The report lists C<rows>, one per attachment: id, name, the path
written, the size, the checksum Odoo holds, and C<checksum_ok> (the
SHA-1 of what was written equals it). Content is never printed. An
attachment of type C<url> holds no file and is listed with C<skipped>.
An attachment on a record the user cannot read is refused by Odoo, and
the refusal is the operation's.

=cut

sub op_name ($class) { 'core.fetch' }
sub summary ($class) { 'Write the attachments of a record to files (mode 0600)' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model      => { type => 'str',  help => 'physical model, e.g. res.partner (not needed with attachment)' },
        record     => { type => 'str',  help => 'an id, or field=value such as ref=C001' },
        name       => { type => 'str',  help => 'only the attachment of this name' },
        attachment => { type => 'int',  help => 'one attachment by id (instead of model and record)' },
        dir        => { type => 'path', required => 1, help => 'directory the files are written to' },
        overwrite  => { type => 'bool', default => 0, help => 'replace a file already in dir' },
    };
}

sub read_scope ($class) { { 'ir.attachment' => [ 'search_read', 'read' ] } }

sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    if ( defined( my $m = $self->param('model') ) ) {
        $s->{$m} = [ sort keys %{ { ( map { $_ => 1 } @{ $s->{$m} // [] } ), search_read => 1 } } ] if $m =~ /\./;
    }
    return $s;
}

sub report ($self) {
    my @ids;
    if ( defined( my $aid = $self->param('attachment') ) ) {
        @ids = ($aid);
    }
    else {
        my ( $model, $rec ) = ( $self->param('model'), $self->param('record') );
        Odoo::Error->throw( kind => 'usage', message => 'core.fetch: give attachment, or model and record' )
            if !defined $model || !defined $rec;
        Odoo::Error->throw( kind => 'usage', message => "core.fetch: model must be a physical model name, got '$model'" ) if $model !~ /\./;
        my $id = $self->_record_id( $model, $rec );
        my @dom = ( [ 'res_model', '=', $model ], [ 'res_id', '=', $id ] );
        push @dom, [ 'name', '=', $self->param('name') ] if defined $self->param('name');
        my $found = $self->model('ir.attachment')->search_read( \@dom, ['id'] );
        @ids = map { $_->{id} } @$found;
    }
    my $dir = $self->param('dir');
    make_path( $dir, { mode => 0700 } ) if !-d $dir;
    Odoo::Error->throw( kind => 'usage', message => "cannot use dir $dir", fix => 'give a path this user can write (dir, out or name), then plan again' ) if !-d $dir || !-w _;

    my ( @rows, %used );
    my $att = $self->model('ir.attachment');
    for my $id (@ids) {
        my $r = $att->read_one( $id, [qw(name type file_size checksum mimetype datas res_model res_id)] );
        Odoo::Error->throw( kind => 'usage', message => "no attachment $id" ) if !$r;
        if ( defined $self->param('name') && $r->{name} ne $self->param('name') ) { next }
        my %row = ( id => $id, name => $r->{name}, res_model => $r->{res_model}, res_id => $r->{res_id} );
        if ( ( $r->{type} // '' ) eq 'url' || !$r->{datas} ) {
            push @rows, { %row, skipped => ( ( $r->{type} // '' ) eq 'url' ? 'a link, not a file' : 'no content' ) };
            next;
        }
        my $safe = _safe_name( $r->{name}, $id );
        $safe = "$id-$safe" if $used{ lc $safe }++;
        my $path = File::Spec->catfile( $dir, $safe );
        my $bytes = decode_base64( $r->{datas} );
        my $flags = O_WRONLY | O_CREAT | ( $self->param('overwrite') ? O_TRUNC : O_EXCL );
        sysopen( my $fh, $path, $flags, 0600 )
            or Odoo::Error->throw( -e $path
                ? ( kind => 'refused', code => 'exists', message => "cannot write $path: it exists; overwrite=1 replaces it", fix => 'pass --set overwrite=1' )
                : ( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path this user can write (dir, out or name), then plan again' ) );
        binmode $fh;
        print {$fh} $bytes;
        close $fh or Odoo::Error->throw( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path this user can write (dir, out or name), then plan again' );
        chmod 0600, $path;
        my $sum = Digest::SHA::sha1_hex($bytes);
        push @rows, { %row, path => $path, size => length($bytes), checksum => $r->{checksum}, checksum_ok => ( ( $r->{checksum} // '' ) eq $sum ? 1 : 0 ) };
    }
    return { rows => \@rows, count => scalar(@rows), dir => $dir };
}

sub _record_id ($self, $model, $rec) {
    my $m = $self->model($model);
    my $fields = $m->fields;
    my $dom;
    if ( $rec =~ /^\d+\z/ ) { $dom = [ [ 'id', '=', 0 + $rec ] ] }
    elsif ( my ( $f, $val ) = $rec =~ /^(\w+)=(.*)\z/s ) {
        Odoo::Error->throw( kind => 'usage', message => "core.fetch: $model has no field '$f'" ) if !$fields->{$f};
        $dom = [ [ $f, '=', $val ] ];
    }
    else { Odoo::Error->throw( kind => 'usage', message => "core.fetch: record '$rec' is neither an id nor field=value" ) }
    my $found = $m->search_read( $dom, ['id'] );
    Odoo::Error->throw( kind => 'usage', message => "core.fetch: no $model matches $rec" ) if !@$found;
    Odoo::Error->throw( kind => 'usage', message => "core.fetch: $rec matches $model records " . join( ', ', map { $_->{id} } @$found ) ) if @$found > 1;
    return $found->[0]{id};
}

sub _safe_name ($name, $id) {
    my $n = defined $name ? $name : '';
    $n =~ s{.*[/\\]}{};
    $n =~ s/[^A-Za-z0-9._ -]/_/g;
    $n =~ s/^\.+//;
    $n =~ s/^\s+|\s+\z//g;
    return length $n ? $n : "attachment-$id";
}

1;

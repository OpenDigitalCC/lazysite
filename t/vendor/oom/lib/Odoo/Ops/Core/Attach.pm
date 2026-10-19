package Odoo::Ops::Core::Attach;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use JSON::PP ();
use Odoo::JSON ();
use File::Basename qw(basename);
use MIME::Base64 qw(encode_base64 decode_base64);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Rows;
use Odoo::Ops::File;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Attach - put files on any record

=head1 SYNOPSIS

    oom-ops run core.attach --conf C --set rows=files.jsonl

    # one row per file
    { "model": "res.partner", "record": "ref=C001", "file": "/data/contract.pdf", "replace": true }

    # one file given as bytes, with no path on the host (a program, or the daemon)
    $client->run( 'core.attach', { model => 'res.partner', record => 7,
        file => { name => 'receipt.jpg', bytes => $raw, mimetype => 'image/jpeg' } } );
    oom-ops run core.attach --conf C --set model=res.partner --set record=7 --file file=./receipt.jpg

=head1 DESCRIPTION

C<core.attach>: rows of C<< { model, record, file, name?, mimetype?,
replace? } >> (C<records> in-process, or a C<rows> file as for
L<Odoo::Ops::Core::Import>) become C<ir.attachment> records on the
named records. C<record> is an id or C<field=value> (C<ref=C001>). The
name is the file's base name unless C<name> says otherwise; the
mimetype comes from the extension unless given.

C<file> as a parameter is the other way in: one file given as bytes (a hash
C<< { name, bytes, mimetype? } >>, see L<Odoo::Ops::File>) with C<model>,
C<record> and optionally C<name>, C<mimetype> and C<replace>, in place of
C<records> and C<rows>; exactly one of the three is given. The bytes go once to
the run's blob store and the plan shows C<< { name, bytes, sha256, mimetype } >>
only; apply checks the blob's digest and the SHA-1 and reads the attachment
back by size and checksum. A row of C<records> may also hold a file value as
its C<file>.

The plan never carries a file's bytes: it carries the path, the size and
the SHA-1 computed at planning. Apply reads the file again and refuses
(C<changed-since-plan>) when it no longer has that checksum, then reads
back the attachment's id, size and checksum - never its content.

A row lands in one bucket:

    attach               an attachment is planned (with replace: the
                         old one of that name is removed after the new one exists)
    unchanged            an attachment of that name with that content is already on the record
    exists               a different attachment of that name is there and replace is off - held
    unknown-record       the model or the record is not found - held
    ambiguous-record     the record key matches several - held
    file-missing         the file cannot be read - held
    too-large            over max_bytes (default 25 MB) - held
    duplicate-in-source  an earlier row names the same record and name
    invalid              the row lacks something, or carries an error

=cut

my $MAX_DEFAULT = 25 * 1024 * 1024;

our %MIME = (
    jpg => 'image/jpeg', jpeg => 'image/jpeg', png => 'image/png', gif => 'image/gif', webp => 'image/webp',
    heic => 'image/heic', svg => 'image/svg+xml', pdf => 'application/pdf', txt => 'text/plain', csv => 'text/csv',
    md => 'text/markdown', html => 'text/html', json => 'application/json', xml => 'application/xml',
    zip => 'application/zip',
);

sub op_name ($class) { 'core.attach' }
sub summary ($class) { 'Attach files to records of any model' }
sub pack    ($class) { undef }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'attach', meaning => 'a file is attached to the record' },
        { name => 'replaced', meaning => 'the record holds a different file of that name and replace is on; the old one goes first' },
        { name => 'unchanged', meaning => 'a file of that name with that content is already on the record' },
    ];
}
sub holds ($class) {
    return [
        { name => 'exists', meaning => 'a different file of that name is on the record and replace is off' },
        { name => 'unknown-record', meaning => 'the model or the record is not found' },
        { name => 'ambiguous-record', meaning => 'the record key matches more than one record' },
        { name => 'file-missing', meaning => 'the file cannot be read' },
        { name => 'too-large', meaning => 'the file is over max_bytes (default 25 MB)' },
        { name => 'duplicate-in-source', meaning => 'an earlier row names the same record and file name' },
        { name => 'invalid', meaning => 'the row is malformed' },
        { name => 'held-flag', meaning => 'the source flagged the row as held' },
    ];
}

sub params ($class) {
    {   records   => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
        rows      => { type => 'path', help => 'rows file: .jsonl, .json (a list) or .csv with model, record, file, name, mimetype, replace' },
        file      => { type => 'file', max_bytes => $MAX_DEFAULT, help => 'one file as bytes, in place of records and rows: --file file=PATH on the command line; with model and record' },
        model     => { type => 'str',  help => 'with file: the physical model of the record (res.partner)' },
        record    => { type => 'str',  help => 'with file: the record, an id or field=value (ref=C001)' },
        name      => { type => 'str',  help => 'with file: the attachment name (default: the file name)' },
        mimetype  => { type => 'str',  help => 'with file: the type (default: the file\'s own, else read from its first bytes)' },
        replace   => { type => 'bool', help => 'with file: swap an attachment of that name that holds other content' },
        max_bytes => { type => 'int',  default => $MAX_DEFAULT, help => 'refuse a file over this size (default 25 MB)' },
    };
}
sub read_scope  ($class) { { 'ir.attachment' => ['search_read'] } }
sub write_scope ($class) { { 'ir.attachment' => [ 'create', 'unlink' ] } }

# the models the rows name are known only once they are read
sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    for my $m ( keys %{ $self->{models} // {} } ) {
        my %have = map { $_ => 1 } @{ $s->{$m} // [] };
        $have{search_read} = 1;
        $s->{$m} = [ sort keys %have ];
    }
    return $s;
}

sub plan ($self) {
    my @in = grep { defined $self->param($_) } qw(records rows file);
    Odoo::Error->throw( kind => 'usage', message => 'core.attach: give exactly one of records, rows, file (got ' . ( @in ? "@in" : 'none' ) . ')' )
        if @in != 1;
    my $rows;
    if ( $in[0] eq 'file' ) {
        for my $need (qw(model record)) {
            Odoo::Error->throw( kind => 'usage', message => "core.attach: file needs $need", fix => "pass --set $need=... with --file file=PATH" ) if !defined $self->param($need);
        }
        my $f = $self->param('file');
        $rows = [ { key => $f->{name}, values => { model => $self->param('model'), record => $self->param('record'), file => $f,
            map { defined $self->param($_) ? ( $_ => $self->param($_) ) : () } qw(name mimetype replace) } } ];
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => 'core.attach: ' . join( ', ', grep { defined $self->param($_) } qw(model record name mimetype replace) ) . ' go with file; a row of records or rows names its own' )
            if grep { defined $self->param($_) } qw(model record name mimetype replace);
        $rows = Odoo::Ops::Rows->load( 'core.attach', map { $_ => $self->param($_) } @in );
    }
    my @items;
    for my $r (@$rows) {
        my $v = $r->{values};
        push @items, {
            key => $r->{key}, held => $r->{held}, error => $r->{error},
            map { $_ => ( ref $v eq 'HASH' ? $v->{$_} : undef ) } qw(model record file name mimetype replace),
        };
    }
    $self->{models} = { map { defined $_->{model} && $self->is_model_name( $_->{model} ) ? ( $_->{model} => 1 ) : () } @items };
    $self->ctx->guard->with_scope( $self->scope_for('read'), $self->op_name, sub {
        return $self->plan_items( \@items, max_bytes => $self->param('max_bytes') );
    } );
}

=head2 plan_items(\@items, max_bytes => N, replace => 0|1)

The planning proper, for L<Odoo::Ops::CRM::Attach> and other callers
that find their records another way. An item is C<< { key, model,
record, file, name?, mimetype?, replace?, held?, error? } >> with
C<model> a physical model and C<record> an id or C<field=value>;
C<< replace => 0 >> in the options switches replacing off for every
item. Returns the unfinalized plan; the operation calling it must have
the read scope for the models.

=cut

sub plan_items ($self, $items, %opt) {
    my $max = $opt{max_bytes} // $MAX_DEFAULT;
    my $plan = $self->new_plan( input_count => scalar @$items );
    my ( %seen, %att );
    for my $it (@$items) {
        my $row = { key => $it->{key} };
        my $hold = sub ($bucket, $why) { $plan->add( bucket => $bucket, action => 'hold', key => "src:$row->{key}", reason => $why ) };
        next if defined $it->{error} && $hold->( 'invalid', $it->{error} );
        next if $it->{held} && $hold->( 'held-flag', $it->{held} );
        my $given = Odoo::Ops::File->is_value( $it->{file} ) ? $it->{file} : undef;
        my ( $model, $rec, $file ) = map { ref $_ ? undef : ( defined $_ ? $_ =~ s/^\s+|\s+\z//gr : undef ) } @$it{qw(model record file)};
        $file = '' if $given;
        next if !$self->is_model_name($model) && $hold->( 'invalid', 'row needs model (a model name such as res.partner)' );
        next if ( !defined $rec  || $rec eq '' )  && $hold->( 'invalid', 'row needs record (an id, or field=value such as ref=C001)' );
        next if ( !defined $file || ( $file eq '' && !$given ) ) && $hold->( 'invalid', 'row needs file' );

        my $id = $self->_find_record( $model, $rec, $hold );
        next if !defined $id;

        my ( $size, $sha );
        if ($given) {
            $given = Odoo::Ops::File->check( 'core.attach', 'file', $given, { max_bytes => $max } ) if length( $given->{bytes} ) <= $max;
            $size = length $given->{bytes};
            if ( $size > $max ) { $hold->( 'too-large', "file $given->{name} is $size bytes; the limit is $max (max_bytes)" ); next }
            $sha = Digest::SHA::sha1_hex( $given->{bytes} );
        }
        else {
            if ( !-f $file || !-r _ ) { $hold->( 'file-missing', "cannot read file $file" ); next }
            $size = -s _;
            if ( $size > $max ) { $hold->( 'too-large', "file $file is $size bytes; the limit is $max (max_bytes)" ); next }
            $sha = _sha1_file($file);
        }

        my $name = defined $it->{name} && $it->{name} ne '' ? $it->{name} : $given ? $given->{name} : basename($file);
        my $dup  = "$model\0$id\0" . lc $name;
        if ( $seen{$dup}++ ) { $hold->( 'duplicate-in-source', "an earlier row attaches '$name' to the same record" ); next }

        my $have = $att{"$model\0$id"} //= $self->model('ir.attachment')->search_read(
            [ [ 'res_model', '=', $model ], [ 'res_id', '=', $id ] ], [ 'name', 'file_size', 'checksum' ] );
        my @same = grep { $_->{name} eq $name } @$have;
        if ( @same && !grep { ( $_->{checksum} // '' ) ne $sha } @same ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $id, key => "src:$row->{key}", reason => "'$name' with this content is already on the record" );
            next;
        }
        my $replace = defined $opt{replace} ? $opt{replace} : _true( $it->{replace} );
        if ( @same && !$replace ) {
            $hold->( 'exists', "'$name' is on the record with different content; pass replace to swap it" );
            next;
        }
        my $mime = defined $it->{mimetype} && $it->{mimetype} ne '' ? $it->{mimetype} : $given ? $given->{mimetype} : do { my ($e) = lc($name) =~ /\.(\w+)\z/; $e ? $MIME{$e} : undef };
        if ($given) {
            my $slim = Odoo::Ops::File->slim($given);
            $plan->add(
                bucket => 'attach', action => 'custom', model => 'ir.attachment', handler => 'core.attach', kind => 'attach',
                key => "src:$row->{key}", size => $size + 0, checksum => $sha, sha256 => $slim->{sha256}, calls => [ [ 'ir.attachment', 'create' ], [ 'ir.attachment', 'read' ] ],
                vals => { name => $name, res_model => $model, res_id => $id + 0, mimetype => $mime, datas => $plan->blob_value( Odoo::Ops::File->base64($given) ) },
                line => "attach $name ($size bytes, sha256 $slim->{sha256}, $mime) to $model $id",
                reason => 'the bytes are held once in the run folder (blobs/) and checked by digest at apply; the plan shows the name, size and digests',
            );
        }
        else {
        $plan->add(
            bucket => 'attach', action => 'custom', model => 'ir.attachment', handler => 'core.attach', kind => 'attach',
            key => "src:$row->{key}", file => $file, size => $size + 0, checksum => $sha, calls => [ [ 'ir.attachment', 'create' ], [ 'ir.attachment', 'read' ] ],
            vals => { name => $name, res_model => $model, res_id => $id + 0, ( defined $mime ? ( mimetype => $mime ) : () ) },
            reason => 'the file is read again at apply; the plan holds its path and checksum, not its bytes',
        );
        }
        # the old one goes after the new one exists: a changed file cannot lose the original
        for my $old (@same) {
            $plan->add( bucket => 'replaced', action => 'unlink', model => 'ir.attachment', id => $old->{id}, support => 1,
                key => "src:$row->{key}", before => { name => $old->{name}, file_size => $old->{file_size}, checksum => $old->{checksum} },
                reason => 'replaced by the new attachment of the same name' );
        }
    }
    return $plan;
}

sub _true ($v) {
    return 0 if !defined $v;
    return $v ? 1 : 0 if Odoo::JSON::is_bool($v);
    return $v =~ /^(1|true|yes|y)\z/i ? 1 : 0;
}

sub _sha1_file ($path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
    my $d = Digest::SHA->new(1);
    $d->addfile($fh);
    close $fh;
    return $d->hexdigest;
}

# the id of the one record, or undef after holding the row
sub _find_record ($self, $model, $rec, $hold) {
    my $fields = eval { $self->model($model)->fields };
    if ( !$fields || !%$fields ) { $hold->( 'unknown-record', "no model '$model' on this instance" ); return undef }
    my $dom;
    if ( $rec =~ /^\d+\z/ ) { $dom = [ [ 'id', '=', 0 + $rec ] ] }
    elsif ( my ( $f, $val ) = $rec =~ /^(\w+)=(.*)\z/s ) {
        if ( !$fields->{$f} ) { $hold->( 'unknown-record', "$model has no field '$f' to find '$rec' by" ); return undef }
        $dom = [ [ $f, '=', $val ] ];
    }
    else { $hold->( 'invalid', "record '$rec' is neither an id nor field=value" ); return undef }
    my $found = $self->{rec_cache}{ $model . "\0" . $rec } //= $self->model($model)->search_read( $dom, ['id'] );
    if ( !@$found ) { $hold->( 'unknown-record', "no $model matches $rec" ); return undef }
    if ( @$found > 1 ) { $hold->( 'ambiguous-record', "$rec matches $model records " . join( ', ', map { $_->{id} } @$found ) ); return undef }
    return $found->[0]{id};
}

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    Odoo::Error->throw( kind => 'usage', message => "core.attach cannot apply kind '$kind'" ) if $kind ne 'attach';
    my $att = $client->model('ir.attachment');
    my $vals;
    if ( defined $c->{vals}{datas} ) {
        # bytes given by the caller: the runner has read the blob back after checking its digest; the file's own SHA-1 is checked too
        Odoo::Error->throw( kind => 'refused', code => 'blob', message => "the bytes of attachment '$c->{vals}{name}' are not the file that was planned (checksum differs)",
            fix => 'plan again with oom-ops run core.attach' )
            if Digest::SHA::sha1_hex( decode_base64( $c->{vals}{datas} ) ) ne $c->{checksum};
        $vals = { %{ $c->{vals} } };
    }
    else {
        open my $fh, '<:raw', $c->{file}
            or Odoo::Error->throw( kind => 'refused', code => 'changed-since-plan', message => "file $c->{file} cannot be read now: $!" );
        my $bytes = do { local $/; <$fh> };
        close $fh;
        Odoo::Error->throw( kind => 'refused', code => 'changed-since-plan',
            message => "file $c->{file} no longer has the checksum it had when planned; re-plan" )
            if Digest::SHA::sha1_hex($bytes) ne $c->{checksum};
        $vals = { %{ $c->{vals} }, datas => encode_base64( $bytes, '' ) };
    }
    my $id  = $att->create($vals);
    my $row = $att->read_one( $id, [qw(name res_model res_id file_size checksum)] );
    my $ok  = $row && ( $row->{checksum} // '' ) eq $c->{checksum} && ( $row->{file_size} // -1 ) == $c->{size};
    # the read-back goes to the journal as returned: id, size and checksum, never the content
    return { id => $id, returned => { id => $id, file_size => $row->{file_size}, checksum => $row->{checksum} },
        after => ( $ok ? $row : undef ) };
}

=head2 undo_custom($class, $entry)

None: the revert holds the row. OOM defines no inverse for an attachment, and
Odoo deletes an attachment with the record it is on, so the hold says that.

=cut

sub undo_custom ($class, $entry) {
    my $v  = $entry->{vals} // {};
    my $on = defined $v->{res_model} && defined $v->{res_id} ? " on $v->{res_model} $v->{res_id}" : '';
    my $id = defined $entry->{id} ? " $entry->{id}" : '';
    return ( undef, "attachment$id$on is not undone by OOM: core.attach defines no inverse for it; Odoo deletes an attachment with the record it is on, so it goes when that record is deleted" );
}

1;

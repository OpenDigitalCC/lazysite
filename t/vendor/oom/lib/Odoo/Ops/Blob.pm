package Odoo::Ops::Blob;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use B ();
use Digest::SHA ();
use File::Path qw(make_path remove_tree);
use File::Spec ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Blob - large values kept once in the run folder, named by their digest

=head1 SYNOPSIS

    my %store;
    my $slim = Odoo::Ops::Blob->externalise( $change, min => 65536, store => \%store );
    Odoo::Ops::Blob->write( $run_dir, \%store );

    my $src  = Odoo::Ops::Blob->source( dirs => [$run_dir] );
    my $full = $src->resolve($slim);          # refuses (refused/blob) a missing or changed blob

=head1 DESCRIPTION

A plan and its journal keep every value of a change. A value over a threshold
(C<blob_min>, default 64 KiB), and every C<datas> and C<raw> value of an
C<ir.attachment> whatever its size, is written once to C<blobs/E<lt>sha256E<gt>>
in the run folder and replaced, in C<plan.json> and the journal, by

    { "blob": "sha256:<hex>", "bytes": N, "type": "base64" }

C<type> is C<base64> when the value is base64 text, else C<text>. The blob is
the value as UTF-8, the folder C<blobs/> is 0700 and each file 0600, so they go
with the run. A reference stands in the plan's seal: the fingerprint covers the
digest, so a blob that changed is a plan that changed.

C<externalise> never changes its argument: it returns the data with the
references in place and puts the values in C<store>, a hash of digest to value.
A number is never read as a string, so it stays a number in the JSON.

=cut

use constant MIN_DEFAULT => 64 * 1024;

# the keys of an attachment that hold its bytes
my %BYTES_KEY = map { $_ => 1 } qw(datas raw);

sub min_default ($class) { MIN_DEFAULT }

=head2 is_ref($value)

True for a reference: a hash with exactly C<blob>, C<bytes> and C<type>.

=cut

sub is_ref ($class, $v) {
    return 0 if ref $v ne 'HASH' || keys %$v != 3;
    return 0 if grep { !exists $v->{$_} } qw(blob bytes type);
    return $v->{blob} =~ /\Asha256:[0-9a-f]{64}\z/ ? 1 : 0;
}

sub _hex ($ref) { return substr( $ref->{blob}, 7 ) }

sub _octets ($value) {
    my $o = $value;
    utf8::encode($o);
    return $o;
}

sub _is_string ($v) {
    return 0 if !defined $v || ref $v;
    my $f = B::svref_2object( \$v )->FLAGS;
    return 0 if ( $f & ( B::SVp_IOK() | B::SVp_NOK() ) ) && !( $f & B::SVp_POK() );
    return 1;
}

=head2 externalise($data, min => N, store => \%store, attachment => 0|1)

C<$data> with each large value replaced by its reference. A hash whose
C<model> is C<ir.attachment> is read as an attachment (C<datas> and C<raw>
always go to a blob), and so is everything beneath it.

=cut

sub externalise ($class, $data, %o) {
    my $min = $o{min} // MIN_DEFAULT;
    my $store = $o{store} // {};
    return $class->_walk( $data, $min, $store, $o{attachment} ? 1 : 0, undef, { n => 0 } );
}

sub _walk ($class, $v, $min, $store, $att, $key, $st) {
    if ( ref $v eq 'HASH' ) {
        return $v if $class->is_ref($v);
        my $in = $att || ( _is_string( $v->{model} ) && $v->{model} eq 'ir.attachment' ) ? 1 : 0;
        my $was = $st->{n};
        my %new = map { $_ => $class->_walk( $v->{$_}, $min, $store, $in, $_, $st ) } keys %$v;
        return $st->{n} == $was ? $v : \%new;
    }
    if ( ref $v eq 'ARRAY' ) {
        my $was = $st->{n};
        my @new = map { $class->_walk( $_, $min, $store, $att, undef, $st ) } @$v;
        return $st->{n} == $was ? $v : \@new;
    }
    return $v if !_is_string($v) || !length $v;
    return $v if !( length($v) > $min || ( $att && defined $key && $BYTES_KEY{$key} ) );
    my $octets = _octets($v);
    my $hex    = Digest::SHA::sha256_hex($octets);
    $store->{$hex} = $v;
    $st->{n}++;
    return { blob => "sha256:$hex", bytes => length($octets) + 0, type => ( $v =~ /\A[A-Za-z0-9+\/=\r\n]+\z/ ? 'base64' : 'text' ) };
}

=head2 write($dir, \%store)

Writes each value of C<store> to C<$dir/blobs/E<lt>digestE<gt>> (0600, in a 0700
folder) unless a file is there. Returns the number written.

=cut

sub write ($class, $dir, $store) {
    return 0 if !%$store;
    my $bd = File::Spec->catdir( $dir, 'blobs' );
    if ( !-d $bd ) {
        make_path( $bd, { mode => 0700 } );
        -d $bd or Odoo::Error->throw( kind => 'config', message => "cannot make $bd: $!" );
    }
    my $n = 0;
    for my $hex ( sort keys %$store ) {
        my $path = File::Spec->catfile( $bd, $hex );
        next if -e $path;
        my $tmp = "$path.tmp$$";
        my $old = umask 0077;
        my $ok  = open my $fh, '>:raw', $tmp;
        umask $old;
        $ok or Odoo::Error->throw( kind => 'config', message => "cannot write blob $path: $!" );
        print {$fh} _octets( $store->{$hex} );
        close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write blob $path: $!" );
        chmod 0600, $tmp;
        rename $tmp, $path or Odoo::Error->throw( kind => 'config', message => "cannot write blob $path: $!" );
        $n++;
    }
    return $n;
}

=head2 list($dir)

C<< [ { blob => 'sha256:...', bytes => N } ] >> for the blobs in a run folder,
by digest: what C<oom-ops show> prints, never a content.

=cut

sub list ($class, $dir) {
    my $bd = File::Spec->catdir( $dir, 'blobs' );
    return [] if !-d $bd;
    opendir my $dh, $bd or return [];
    my @out = map { { blob => "sha256:$_", bytes => -s File::Spec->catfile( $bd, $_ ) } } sort grep { /\A[0-9a-f]{64}\z/ } readdir $dh;
    closedir $dh;
    return \@out;
}

=head2 purge($dir)

Removes the folder's blobs; returns how many there were.

=cut

sub purge ($class, $dir) {
    my $n  = @{ $class->list($dir) };
    my $bd = File::Spec->catdir( $dir, 'blobs' );
    remove_tree($bd) if -d $bd;
    return $n;
}

=head2 refs($data)

Every reference in C<$data>, in order.

=cut

sub refs ($class, $v) {
    return ($v) if $class->is_ref($v);
    return map { $class->refs( $v->{$_} ) } sort keys %$v if ref $v eq 'HASH';
    return map { $class->refs($_) } @$v if ref $v eq 'ARRAY';
    return ();
}

=head2 strip($data)

C<$data> without the keys whose value is a reference (a create's after-image is
compared on the rest).

=cut

sub strip ($class, $v) {
    return $v if ref $v ne 'HASH';
    return { map { $_ => $v->{$_} } grep { !$class->is_ref( $v->{$_} ) } keys %$v };
}

=head2 source(dirs => [...], mem => \%store)

A reader over the run folders given (and values held in memory).

=cut

sub source ($class, %o) {
    return bless { dirs => [ grep { defined } @{ $o{dirs} // [] } ], mem => $o{mem} // {} }, 'Odoo::Ops::Blob::Source';
}

package Odoo::Ops::Blob::Source;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

sub _refuse ($ref, $why) {
    Odoo::Error->throw( kind => 'refused', code => 'blob',
        message => "blob $ref->{blob} ($ref->{bytes} bytes) $why",
        fix => 'plan again with oom-ops run: the plan\'s blobs are in its run folder and a plan without them cannot be applied' );
}

sub _path ($self, $ref) {
    my $hex = Odoo::Ops::Blob::_hex($ref);
    for my $d ( @{ $self->{dirs} } ) {
        my $p = File::Spec->catfile( $d, 'blobs', $hex );
        return $p if -f $p;
    }
    return undef;
}

# the digest and size of the file, read in pieces
sub verify ($self, $ref) {
    my $hex = Odoo::Ops::Blob::_hex($ref);
    return 1 if exists $self->{mem}{$hex};
    my $p = $self->_path($ref) // _refuse( $ref, 'is missing from the run folder' );
    open my $fh, '<:raw', $p or _refuse( $ref, "cannot be read ($!)" );
    my $d = Digest::SHA->new(256);
    $d->addfile($fh);
    close $fh;
    _refuse( $ref, 'has changed since the plan was made (its digest differs)' ) if $d->hexdigest ne $hex;
    _refuse( $ref, 'has changed since the plan was made (its size differs)' ) if -s $p != $ref->{bytes};
    return 1;
}

sub get ($self, $ref) {
    my $hex = Odoo::Ops::Blob::_hex($ref);
    return $self->{mem}{$hex} if exists $self->{mem}{$hex};
    my $p = $self->_path($ref) // _refuse( $ref, 'is missing from the run folder' );
    open my $fh, '<:raw', $p or _refuse( $ref, "cannot be read ($!)" );
    my $octets = do { local $/; <$fh> };
    close $fh;
    $octets = '' if !defined $octets;
    _refuse( $ref, 'has changed since the plan was made (its digest differs)' ) if Digest::SHA::sha256_hex($octets) ne $hex || length($octets) != $ref->{bytes};
    utf8::decode($octets);
    return $octets;
}

sub resolve ($self, $v) {
    return $self->get($v) if Odoo::Ops::Blob->is_ref($v);
    return { map { $_ => $self->resolve( $v->{$_} ) } keys %$v } if ref $v eq 'HASH';
    return [ map { $self->resolve($_) } @$v ] if ref $v eq 'ARRAY';
    return $v;
}

1;

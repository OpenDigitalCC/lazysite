package Odoo::Cache;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
use Odoo::JSON ();

=head1 NAME

Odoo::Cache - the small owner-only cache directory a cold process reads

=head1 SYNOPSIS

    my $cache = Odoo::Cache->new( dir => Odoo::Cache->default_dir );
    $cache->keep( 'version.json', { 'https://odoo.example' => { at => time, version => {...} } } );
    my $data = $cache->recall('version.json');       # undef when absent, unreadable or not ours

=head1 DESCRIPTION

A directory of JSON files, each written 0600 (the directory 0700) through a
temporary name and a rename, so a reader sees a whole file or none. Reads and
writes are best effort: a cache that cannot be read or written is a cache
that is empty, never a failure of the call that asked. A file that is not
ours, or that group or other can read, is not read.

The directory holds what a process may know again without asking Odoo: the
operation index, a remembered uid, the server version, field definitions.
It never holds a key, a password, a session id or a field value. The
fingerprint of a key is a one-way digest (L</digest>) used to name an entry,
not to store the key.

=head1 METHODS

=head2 default_dir

C<$XDG_CACHE_HOME/oom>, else C<~/.cache/oom>.

=cut

sub default_dir ($class) {
    my $base = length( $ENV{XDG_CACHE_HOME} // '' ) ? $ENV{XDG_CACHE_HOME}
        : File::Spec->catdir( $ENV{HOME} // ( getpwuid($<) )[7] // '/tmp', '.cache' );
    return File::Spec->catdir( $base, 'oom' );
}

=head2 new(dir =E<gt> $dir)

=head2 dir

=cut

sub new ($class, %args) {
    return bless { dir => $args{dir} // $class->default_dir }, $class;
}

sub dir ($self) { $self->{dir} }

=head2 digest(@parts)

The SHA-256 (hex) of the parts joined with a NUL: the name of an entry made
from several facts, among them the fingerprint of a key.

=cut

sub digest ($class, @parts) {
    return Digest::SHA::sha256_hex( join "\0", map { $_ // '' } @parts );
}

sub _path ($self, $name) {
    die "bad cache name\n" if $name !~ /\A[\w.-]+\z/ || $name =~ /\A\./;
    return File::Spec->catfile( $self->{dir}, $name );
}

=head2 recall($name)

The decoded JSON of the file, or undef.

=cut

sub recall ($self, $name) {
    my $path = $self->_path($name);
    my @st = lstat $path or return undef;
    return undef if !-f _ || $st[4] != $< || ( $st[2] & 077 );
    open my $fh, '<:raw', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { Odoo::JSON::decode( $raw // '' ) };
    return $data;
}

=head2 keep($name, $data)

True when the file was written. The directory is made 0700 if it is new.

=cut

sub keep ($self, $name, $data) {
    my $path = $self->_path($name);
    my $ok = eval {
        if ( !-d $self->{dir} ) {
            my $old = umask 077;
            make_path( $self->{dir}, { mode => 0700 } );
            umask $old;
        }
        my $tmp = "$path.$$.tmp";
        my $old = umask 077;
        my $opened = open my $fh, '>:raw', $tmp;
        umask $old;
        die "cannot write\n" if !$opened;
        chmod 0600, $tmp;
        print {$fh} Odoo::JSON->new->encode($data);
        close $fh or die "cannot write\n";
        rename $tmp, $path or do { unlink $tmp; die "cannot write\n" };
        1;
    };
    return $ok ? 1 : 0;
}

=head2 forget($name)

=cut

sub forget ($self, $name) { unlink $self->_path($name); return 1 }

=head2 describe

What the directory is: C<< { dir, exists, mode, files => [ { name, mode } ] } >>.
File names and modes only, never contents.

=cut

sub describe ($self) {
    my %d = ( dir => $self->{dir}, exists => 0, mode => undef, files => [] );
    my @st = stat $self->{dir} or return \%d;
    $d{exists} = 1;
    $d{mode}   = sprintf '%04o', $st[2] & 0777;
    if ( opendir my $dh, $self->{dir} ) {
        for my $n ( sort grep { /\A[\w.-]+\.json\z/ } readdir $dh ) {
            my @f = stat File::Spec->catfile( $self->{dir}, $n ) or next;
            push @{ $d{files} }, { name => $n, mode => sprintf( '%04o', $f[2] & 0777 ) };
        }
        closedir $dh;
    }
    return \%d;
}

1;

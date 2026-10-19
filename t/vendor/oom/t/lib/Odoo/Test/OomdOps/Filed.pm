package Odoo::Test::OomdOps::Filed;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();

use parent 'Odoo::Ops::Operation';

# A read that takes files, for the tests of the file parameter through the daemon
# (ODOO_OPS_NAMESPACES=Odoo::Test::OomdOps): it reports what it was given by name, size, digest and type,
# and the digest of the bytes it saw, never the bytes.

sub op_name ($class) { 'test.file' }
sub summary ($class) { 'Report the files given, for tests' }
sub params  ($class) {
    return {
        file  => { type => 'file',  max_bytes => 100_000, help => 'one file' },
        files => { type => 'files', max => 10, max_bytes => 100_000, help => 'files' },
    };
}
sub report ($self) {
    my @all = ( ( grep { defined } $self->param('file') ), @{ $self->param('files') // [] } );
    return { count => scalar @all, rows => [ map { { name => $_->{name}, bytes => length $_->{bytes}, mimetype => $_->{mimetype}, seen => Digest::SHA::sha256_hex( $_->{bytes} ) } } @all ] };
}

1;

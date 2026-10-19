package Lazysite::Odoo::Decl;

# SM1180: A BINDING'S OPERATION, AS IT WAS WHEN THE BINDING WAS SAVED - SO THE
# REQUEST PATH CAN CALL oomd WITHOUT LOADING OOM.
#
# Inbox 2026-10-19-what-lazysite-adds-to-an-odoo-call.md: "lazysite and OOM must
# add minimal latency to Odoo"; "a fresh perl loading OOM 250 ms ... a fresh perl
# loading the oomd light client 61 ms"; "with oomd the endpoint needs no registry,
# since the daemon has it." SM1164 sent the call to oomd but left the registry
# read in the endpoint ("Binding and operation declarations are still read from
# OOM's registry in-process, before anything is sent"). What the request path
# asks of the operation is small and is data: its parameter declarations (the
# binding is checked against them and the request is assembled from them), whether
# it writes (the caps, the plan-or-apply decision, the GET refusal), and its
# summary (the bindings list). This module keeps that beside the binding, in the
# Odoo store (lazysite/odoo/decl/<binding>.json, never under the docroot), stamped
# with what could change it:
#
#   oom        the installed version (Odoo::Ops::Version, which loads nothing else)
#   packs      the site's odoo_packs
#   pack_dirs  the site's odoo_pack_dirs
#   operation  the operation the binding names (a binding edited to name another)
#
# A stamp that matches is used as it stands. A stamp that does not, or no file (a
# binding saved before this release), is re-checked ONCE in-process by the caller,
# which stores the answer again; this module only reads, writes and answers.
#
# THE ONE THING IT CANNOT ANSWER is OOM's check of a request's list of rows
# (Odoo::Ops::Operation->check_rows), which lives in a class that loads the
# registry. A request that feeds a rows parameter loads OOM for that check, and
# only that request; every other call does not.
#
# NO ODOO KNOWLEDGE (t/lint/240): the declaration is opaque data from OOM.
use strict;
use warnings;
use JSON::PP       ();
use File::Path     qw(make_path);
use Lazysite::Util qw(log_event);

our $FORMAT = 1;

sub dir { return $_[0] . '/decl' }

sub file {
    my ( $store, $id ) = @_;
    return undef unless defined $id && $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    return dir($store) . "/$id.json";
}

# The installed OOM's version without loading it, or undef (an OOM before the
# daemon has no such module, and has no daemon path either).
sub oom_version {
    return undef unless eval { require Odoo::Ops::Version; 1 };
    return $Odoo::Ops::Version::VERSION;
}

sub stamp_of {
    my ($conn) = @_;
    my $v = oom_version();
    return undef unless defined $v;
    return { oom => "$v", packs => [ @{ $conn->{packs} || [] } ], pack_dirs => [ @{ $conn->{pack_dirs} || [] } ] };
}

sub _same_list {
    my ( $x, $y ) = @_;
    return 0 unless ref $x eq 'ARRAY' && ref $y eq 'ARRAY' && @$x == @$y;
    for my $i ( 0 .. $#$x ) { return 0 unless ( $x->[$i] // '' ) eq ( $y->[$i] // '' ) }
    return 1;
}

# capture( $class, $operation, $conn ) -> \%declaration or undef
#
# What the request path reads of an operation class, with the stamp. undef when
# there is no stamp to give (no Version module) or when the declaration is not
# plain data JSON can hold - then nothing is stored and every call re-checks,
# which is today's behaviour.
sub capture {
    my ( $class, $op, $conn ) = @_;
    my $stamp = stamp_of($conn) or return undef;
    my $d     = {
        format    => $FORMAT,
        operation => $op,
        writes    => ( $class->writes ? 1 : 0 ),
        summary   => scalar( eval { $class->summary } // '' ),
        params    => ( $class->params || {} ),
        stamp     => $stamp,
    };
    my $ok = eval { JSON::PP->new->canonical->encode($d); 1 };
    return $ok ? $d : undef;
}

# store( $store_dir, $id, \%declaration ) -> 1 or 0. Atomic: a request never
# reads half a file.
sub store {
    my ( $store, $id, $d ) = @_;
    my $f = file( $store, $id ) or return 0;
    return 0 unless ref $d eq 'HASH';
    my $ok = eval {
        make_path( dir($store) );
        my $tmp = "$f.tmp.$$";
        open my $fh, '>:raw', $tmp or die "$tmp: $!\n";
        print {$fh} JSON::PP->new->canonical->encode($d);
        close $fh or die "$tmp: $!\n";
        chmod 0660, $tmp;
        rename $tmp, $f or do { unlink $tmp; die "$f: $!\n" };
        1;
    };
    log_event( 'WARN', 'odoo', 'a binding\'s operation declaration cannot be stored', binding => $id, error => "$@" )
        unless $ok;
    return $ok ? 1 : 0;
}

sub forget {
    my ( $store, $id ) = @_;
    my $f = file( $store, $id ) or return 0;
    return unlink($f) ? 1 : 0;
}

# fetch( $store_dir, $binding, $conn ) -> ( $decl_object, '' ) or ( undef, why )
#
# why is 'none' (no declaration was stored), or what differs. Never dies.
sub fetch {
    my ( $store, $b, $conn ) = @_;
    my $f = file( $store, $b->{id} ) or return ( undef, 'none' );
    open my $fh, '<:raw', $f or return ( undef, 'none' );
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json($raw) };
    return ( undef, 'unreadable' ) unless ref $d eq 'HASH' && ref $d->{params} eq 'HASH' && ref $d->{stamp} eq 'HASH';
    return ( undef, 'format' ) unless ( $d->{format} // 0 ) == $FORMAT;
    return ( undef, "operation $d->{operation} -> $b->{operation}" ) unless ( $d->{operation} // '' ) eq $b->{operation};
    my $now = stamp_of($conn) or return ( undef, 'OOM version unknown' );
    my $s   = $d->{stamp};
    return ( undef, "OOM " . ( $s->{oom} // '?' ) . " -> $now->{oom}" ) unless ( $s->{oom} // '' ) eq $now->{oom};
    return ( undef, 'odoo_packs changed' ) unless _same_list( $s->{packs}, $now->{packs} );
    return ( undef, 'odoo_pack_dirs changed' ) unless _same_list( $s->{pack_dirs}, $now->{pack_dirs} );
    return ( bless( { d => $d, conn => $conn, operation => $b->{operation} }, __PACKAGE__ ), '' );
}

# --- the object: what the engine asks of an operation class ----------------------

sub params  { return $_[0]{d}{params} }
sub writes  { return $_[0]{d}{writes} ? 1 : 0 }
sub summary { return $_[0]{d}{summary} // '' }

# The real class, loading OOM, for the few things a declaration cannot answer
# (check_rows) and for the in-process path when the daemon is down.
sub real {
    my ($self) = @_;
    return $self->{real} //= do {
        require Lazysite::Odoo;
        my ( $have, $why ) = Lazysite::Odoo::oom_check();
        die "$why\n" unless $have;
        my ( $class, $cwhy ) = Lazysite::Odoo::operation_class( $self->{conn}, $self->{operation} );
        die "$cwhy\n" unless $class;
        $class;
    };
}

sub check_rows {
    my $self = shift;
    return $self->real->check_rows(@_);
}

sub is_decl { return ref $_[0] && eval { $_[0]->isa(__PACKAGE__) } ? 1 : 0 }

1;

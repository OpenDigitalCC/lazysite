package Odoo::Cache::Data;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();

use Odoo::Ops ();

=head1 NAME

Odoo::Cache::Data - the opt-in data cache: a read answered from a file while Odoo's signal for the model still holds

=head1 SYNOPSIS

    my $data = Odoo::Cache::Data->new(
        dir => "$cache_dir", url => $url, db => $db, login => $login,
        rpc => sub ( $model, $method, $args, $kw ) { $client->execute_kw( $model, $method, $args, $kw ) } );
    my $got = $data->read(
        model => 'product.template', domain => [], fields => [ 'id', 'name' ], max_age => 30,
        fetch => sub { $client->model('product.template')->search_read( [], ['id','name'] ) } );
    # { rows => [...], cached => 1, age => 12, checked => 'signal' }

=head1 DESCRIPTION

The data cache is off unless the config says C<data_cache = 1>
(L<Odoo::Ops::Config>). It holds the rows of a read in a file, so a process
that asks for the same thing again does not ask Odoo.

=over

=item * B<The caller sets staleness, per read.> C<max_age> is seconds. A read
with no C<max_age>, or C<max_age = 0>, is live: it is not looked up and not
stored. OOM has no default.

=item * B<The signal keeps it true.> For each model the read depends on, the
newest C<write_date> and the number of records (archived ones counted, so an
archive, a create and an unlink all move it), read with one C<read_group>
and kept in a small file shared by every process of the login. A kept
answer is served only while the signal it was filled under is the signal
now. The signal is read again when its file is older than the read's
C<max_age>, so an answer is never older than C<max_age> behind Odoo. Odoo
reports C<write_date> to the second, so an answer filled less than
C<settle> (2) seconds after the newest C<write_date> is not trusted and is
filled again on the next read.

=item * B<Per login.> The files are in a directory per (url, db, login) under
C<data/> of the cache directory (mode 0700; files 0600), and the key of an
answer holds the url, db, login, model, domain, fields, order, limit, the
language, the pricelist and whether archived records are in. One login never
reads another's files.

=item * B<Never cached.> The models and fields of L</never_list> (stock
levels, reservations, pickings, order state) are always read live, whatever
C<max_age> says; the answer says C<< cached => 0, live => 'required' >>.

=item * B<Every answer says what it is>: C<cached> (1 or 0), C<age> (seconds
since the rows were read, when cached) and C<checked> (C<signal>, when
cached).

=item * B<A size cap per login>, C<max_mb> (default 200): when a login's
directory is over it, the oldest files go first. Writes are a temporary file
and a rename, so a reader sees a whole file or none.

=back

The files hold rows, so the directory is owner-only. Nothing here is printed or audited but the
facts of a read: C<cached>, C<age>, never a row.

=head1 METHODS

=head2 never_list

The models and fields that are never cached, as data:
C<< [ [ $model, $field_or_star, $why ], ... ] >>, sorted. C<*> is the whole
model. C<t/72-data-cache.t> lists it.

=cut

# One place. A model with a star is live whole; a model with fields is live
# when a field asked, or a field the domain or order names, is one of them.
my %NEVER_MODEL = (
    'stock.quant'     => 'stock levels and reservations',
    'stock.move'      => 'stock moves and reservations',
    'stock.move.line' => 'reservations',
    'stock.picking'   => 'pickings',
    'sale.order'      => 'order state',
);
my @QTY = qw(qty_available virtual_available free_qty incoming_qty outgoing_qty);
my %NEVER_FIELD = (
    'product.product'  => { map { $_ => 'stock quantity' } @QTY },
    'product.template' => { map { $_ => 'stock quantity' } @QTY },
    'stock.lot'        => { product_qty => 'stock quantity' },
    'account.move'     => { map { $_ => 'order state' } qw(state payment_state) },
    'sale.order.line'  => { map { $_ => 'order state' } qw(state invoice_status qty_delivered qty_invoiced qty_to_invoice) },
);
my %ANY_FIELD = map { $_ => 1 } map { keys %$_ } values %NEVER_FIELD;

sub never_list ($class) {
    return [
        sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } (
            ( map { [ $_, '*', $NEVER_MODEL{$_} ] } keys %NEVER_MODEL ),
            ( map { my $m = $_; map { [ $m, $_, $NEVER_FIELD{$m}{$_} ] } keys %{ $NEVER_FIELD{$m} } } keys %NEVER_FIELD ),
        )
    ];
}

=head2 live_reason($model, \@names)

Why a read of C<$model> that names the fields C<@names> (asked, in the
domain, in the order) must be live, or undef when it may be cached.

=cut

sub live_reason ( $class, $model, $names ) {
    return $NEVER_MODEL{$model} if $NEVER_MODEL{$model};
    my $f = $NEVER_FIELD{$model} // {};
    for my $n (@$names) {
        my ($head) = split /\./, $n, 2;
        return $f->{$head} if $f->{$head};
        # a path through a relation ends in the field that matters
        my $tail = ( split /\./, $n )[-1];
        return 'live data' if $n =~ /\./ && $ANY_FIELD{$tail};
    }
    return undef;
}

# the field names a domain mentions: leaves are [name, op, value]
sub _domain_names ($d) {
    return () if ref $d ne 'ARRAY';
    return ( $d->[0] ) if @$d >= 3 && defined $d->[0] && !ref $d->[0] && $d->[0] !~ /\A[|&!]\z/ && !ref $d->[1];
    return map { _domain_names($_) } @$d;
}

=head2 new(dir =E<gt> ..., url =E<gt> ..., db =E<gt> ..., login =E<gt> ..., rpc =E<gt> sub)

C<dir> is the cache directory (the files go in C<data/> under it); with no
C<dir>, or no C<login>, nothing is cached and every read is live. C<rpc> is
C<< sub ($model, $method, \@args, \%kwargs) >>, used for the signal. Optional:
C<lang>, C<max_mb> (200), C<now> (C<sub { time }>), C<settle> (2),
C<sweep_every> (10, seconds between two sweeps for the size cap).

=cut

sub new ( $class, %a ) {
    my $self = bless {
        dir         => $a{dir},
        url         => $a{url} // '',
        db          => $a{db} // '',
        login       => $a{login},
        lang        => $a{lang} // '',
        rpc         => $a{rpc},
        max_mb      => $a{max_mb} // 200,
        now         => $a{now} // sub { time },
        settle      => $a{settle} // 2,
        sweep_every => $a{sweep_every} // 10,
    }, $class;
    $self->{on} = defined $self->{dir} && defined $self->{login} && length $self->{login} && $self->{rpc} ? 1 : 0;
    return $self;
}

sub enabled ($self) { $self->{on} }

sub _ldir ($self) {
    return File::Spec->catdir( $self->{dir}, 'data',
        substr( Digest::SHA::sha256_hex( join "\0", $self->{url}, $self->{db}, $self->{login} ), 0, 20 ) );
}

sub _digest ( $self, @p ) { Digest::SHA::sha256_hex( join "\0", map { $_ // '' } @p ) }

# a file we wrote: ours, a plain file, no group or other access
sub _recall ( $self, $path ) {
    my @st = lstat $path or return undef;
    return undef if !-f _ || $st[4] != $< || ( $st[2] & 077 );
    open my $fh, '<:raw', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { Odoo::Ops::json()->decode( $raw // '' ) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _keep ( $self, $path, $data ) {
    my $ok = eval {
        my $dir = $self->_ldir;
        if ( !-d $dir ) {
            my $old = umask 077;
            make_path( File::Spec->catdir( $self->{dir}, 'data' ), $dir, { mode => 0700 } );
            umask $old;
        }
        my $tmp = "$path.$$.tmp";
        my $old = umask 077;
        my $opened = open my $fh, '>:raw', $tmp;
        umask $old;
        die "cannot write\n" if !$opened;
        chmod 0600, $tmp;
        print {$fh} Odoo::Ops::json()->encode($data);
        close $fh or die "cannot write\n";
        rename $tmp, $path or do { unlink $tmp; die "cannot write\n" };
        1;
    };
    return $ok ? 1 : 0;
}

# The newest write_date and the number of records, archived ones counted, of one model
sub _read_signal ( $self, $model ) {
    my $r = $self->{rpc}->( $model, 'read_group', [ [], ['write_date:max'], [] ], { context => { active_test => JSON::PP::false() } } );
    die "no signal\n" if ref $r ne 'ARRAY';
    # a table with no row at all may answer no group
    return [ '', 0 ] if !@$r;
    my $row = $r->[0];
    die "no signal\n" if ref $row ne 'HASH';
    my $count = $row->{__count} // $row->{id_count} // $row->{__count_all};
    my $wd = $row->{write_date} // $row->{'write_date:max'};
    die "no signal\n" if !defined $count || $count !~ /\A\d+\z/;
    $wd = '' if !defined $wd || ref $wd || $wd eq '0' || $wd eq '';
    return [ $wd, $count ];
}

# The shared signal of a model for this login: the file's, while younger than max_age, else read and kept.
sub _signal ( $self, $model, $max_age ) {
    my $path = File::Spec->catfile( $self->_ldir, 'sig-' . substr( $self->_digest( 'sig', $self->{url}, $self->{db}, $model ), 0, 32 ) . '.json' );
    my $now  = $self->{now}->();
    my $kept = $self->_recall($path);
    return $kept->{sig} if $kept && ref $kept->{sig} eq 'ARRAY' && defined $kept->{at}
        && $now >= $kept->{at} && $now - $kept->{at} < $max_age;
    $self->{checks}++;
    my $sig = $self->_read_signal($model);
    $self->_keep( $path, { at => $now, model => $model, sig => $sig } );
    return $sig;
}

=head2 read(%args)

C<model>, C<domain>, C<fields>, C<fetch> (a coderef that reads the rows
live) and, optional, C<order>, C<limit>, C<archived>, C<pricelist>,
C<max_age>, C<also> (more models whose signal the answer depends on, as the
pricelist rules are for a priced read). Returns C<< { rows, cached, age,
checked, live } >>; see L</DESCRIPTION>.

=cut

sub read ( $self, %a ) {
    my ( $model, $fields, $max_age ) = @a{qw(model fields max_age)};
    my $live = sub ($why) {
        return { rows => $a{fetch}->(), cached => 0, ( $why ? ( live => 'required' ) : () ) };
    };
    my $why = __PACKAGE__->live_reason( $model,
        [ @{ $fields // [] }, _domain_names( $a{domain} ), map { ( split ' ', $_ )[0] } grep { length } split /,/, $a{order} // '' ] );
    return $live->(1) if $why;
    return $live->(0) if !$self->{on} || !defined $max_age || $max_age < 1;

    my @models = ( $model, @{ $a{also} // [] } );
    my $key = $self->_digest( 'rd', $self->{url}, $self->{db}, $self->{login}, $model,
        Odoo::Ops::json()->encode( [ $a{domain} // [], $fields // [] ] ), $a{order} // '', $a{limit} // 0,
        $self->{lang}, $a{pricelist} // '', $a{archived} ? 1 : 0 );
    my $path = File::Spec->catfile( $self->_ldir, 'rd-' . substr( $key, 0, 40 ) . '.json' );

    # the signal first: a write between it and the rows makes the next read fill again, never serve old rows as new
    my @sig = eval { map { $self->_signal( $_, $max_age ) } @models };
    return $live->(0) if @sig != @models;
    my $sig    = join ';', map { "$models[$_]=$sig[$_][0]|$sig[$_][1]" } 0 .. $#models;
    my ($newest) = sort { $b cmp $a } grep { length } map { $_->[0] } @sig;

    my $now   = $self->{now}->();
    my $entry = $self->_recall($path);
    if ( $entry && ( $entry->{sig} // '' ) eq $sig && ref $entry->{rows} eq 'ARRAY' && defined $entry->{stored} && $now >= $entry->{stored}
        && $self->_settled($entry) ) {
        return { rows => $entry->{rows}, cached => 1, age => $now - $entry->{stored}, checked => 'signal' };
    }
    my $rows = $a{fetch}->();
    my $stored = $self->{now}->();
    if ( $self->_keep( $path, { stored => $stored, sig => $sig, newest => $newest // '', model => $model, rows => $rows } ) ) {
        $self->_sweep($stored);
    }
    return { rows => $rows, cached => 0 };
}

# an answer filled within the settle window of the newest write_date could miss a second write of that second
sub _settled ( $self, $entry ) {
    my $nw = $entry->{newest};
    return 1 if !defined $nw || $nw eq '';
    my $w = _utc($nw) // return 0;
    return $entry->{stored} - $w >= $self->{settle} ? 1 : 0;
}

sub _utc ($s) {
    return undef if $s !~ /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/;
    require Time::Local;
    return eval { Time::Local::timegm( $6, $5, $4, $3, $2 - 1, $1 ) };
}

# Over max_mb, the oldest files go first. Not on every fill: at most once per sweep_every seconds
# per login (a marker file's modification time), so a fill costs a write, not a directory walk.
sub _sweep ( $self, $now ) {
    my $dir  = $self->_ldir;
    my $mark = File::Spec->catfile( $dir, '.sweep' );
    my @m = stat $mark;
    return if @m && $self->{sweep_every} > 0 && $now - $m[9] < $self->{sweep_every};
    if ( open my $fh, '>', $mark ) { close $fh; chmod 0600, $mark; utime $now, $now, $mark }
    opendir my $dh, $dir or return;
    my ( @files, $total );
    my $stale = $now - 3600;
    for my $n ( readdir $dh ) {
        next if $n =~ /\A\./;
        my $p = File::Spec->catfile( $dir, $n );
        my @st = lstat $p or next;
        next if !-f _;
        if ( $n =~ /\.tmp\z/ ) { unlink $p if $st[9] < $stale; next }
        push @files, [ $st[9], $n, $st[7], $p ];
        $total += $st[7];
    }
    closedir $dh;
    my $cap = $self->{max_mb} * 1024 * 1024;
    return if ( $total // 0 ) <= $cap;
    # signals are small and cheap to read again; answers go first by age
    for my $f ( sort { $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1] } grep { $_->[1] !~ /\Asig-/ } @files ) {
        last if $total <= $cap;
        $total -= $f->[2] if unlink $f->[3];
    }
    return;
}

=head2 says($got)

The keys of an answer that a read puts in its report: C<cached> always,
C<age> and C<checked> when it was cached, C<live> when the read had to be live.

=cut

sub says ( $class, $got ) {
    return (
        cached => $got->{cached} ? 1 : 0,
        ( $got->{cached} ? ( age => $got->{age}, checked => $got->{checked} ) : () ),
        ( $got->{live} ? ( live => $got->{live} ) : () ),
    );
}

=head2 pricelist_models

The models whose signal a read with a C<pricelist> depends on besides its own:
the pricelist and its rules.

=cut

sub pricelist_models ($class) { return ( 'product.pricelist', 'product.pricelist.item' ) }

=head2 checks

How many times this object read a signal from Odoo (a count, for tests and the bench).

=cut

sub checks ($self) { $self->{checks} // 0 }

=head2 describe($cache_dir)

What the data cache holds, never contents:
C<< { dir, exists, files, bytes, logins } >>.

=cut

sub describe ( $class, $dir ) {
    my %d = ( dir => File::Spec->catdir( $dir, 'data' ), exists => 0, files => 0, bytes => 0, logins => 0 );
    opendir my $dh, $d{dir} or return \%d;
    $d{exists} = 1;
    for my $l ( grep { /\A\w+\z/ } readdir $dh ) {
        my $ld = File::Spec->catdir( $d{dir}, $l );
        opendir my $lh, $ld or next;
        $d{logins}++;
        for my $n ( grep { /\A(?:rd|sig)-[\w]+\.json\z/ } readdir $lh ) {
            my @st = lstat File::Spec->catfile( $ld, $n ) or next;
            $d{files}++;
            $d{bytes} += $st[7];
        }
        closedir $lh;
    }
    closedir $dh;
    return \%d;
}

1;

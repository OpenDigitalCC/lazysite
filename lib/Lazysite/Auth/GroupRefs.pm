package Lazysite::Auth::GroupRefs;

# SM1387: WHERE ANYTHING NAMES A GROUP.
#
# The users tool's group-delete (and through it the control API's group-delete,
# MCP delete_group and the manager's Groups page) refuses to delete a group that
# something still names, and says where. A deleted group is not an empty one: a
# rule naming it admits nobody through it, and a group created later under the
# same name would inherit every grant those places make. AddressRefs is the model
# (SM1141): one walk, reading the files itself and loading nothing of the engine's,
# so it answers the same from the shell and the manager.
#
# The places a group name is stored, and only these (surveyed for SM1387):
#   page front matter     auth_groups: [a, b] (a block list too); bare names
#   acls.json entry       read, write: "@name" entries (a bare entry is an account)
#   lazysite.conf         allowed_groups, locked_groups (the primary, SM1332/SM1334);
#                         alias.<host>.allowed_groups, alias.<host>.locked_groups;
#                         auth_group_map (right-hand sides, SM1135). The retired
#                         manager_groups is not: the users tool migrates it to the
#                         operator flag on its first use, and the operator group is
#                         never deleted
#   db/tables/*.yaml      writable_by (a data table's writers)
#   handlers.conf         a type-odoo binding's callers
#   connectors.json       a connector's callers
#   odoo.conf             odoo_group_map (right-hand sides)
# Not counted: a group's own record and membership (deleted with it, and a
# member is refused separately), its name nested in another group's member list
# (un-nested by the delete, as since N141B-E), bundles-adopted.json (a record that
# a shipped group was once had, kept so a deleted one stays deleted), and
# sessions (a copy taken at sign-in).
#
# refs($docroot) -> { refs => [ {where, ref, name} ], faults => [ text ] }
#   where  'page' | 'acl' | 'conf' | 'domain' | 'table' | 'binding' | 'connector' | 'odoo'
#   ref    page path, acl path, conf key, host, table name, binding id, connector id
# A store that exists and cannot be read or decoded is a FAULT, named, never read
# as "names nothing" (SM1024).

use strict;
use warnings;
use File::Find ();
use JSON::PP   ();
use Exporter 'import';
use Lazysite::Paths   ();
use Lazysite::Private ();

our @EXPORT_OK = qw(refs describe);

sub _names {
    my ($v) = @_;
    return () unless defined $v;
    my @n = ref $v eq 'ARRAY' ? ( grep { defined $_ && !ref $_ } @{$v} ) : ( ref $v ? () : ($v) );
    return grep { length } map { s/\A\s+|\s+\z//gr } map { s/\A["']|["']\z//gr }
        map { s/\A\s+|\s+\z//gr } map { split /,/ } @n;
}

# The right-hand sides of a `left = group, left = group` map.
sub _map_targets {
    my ($spec) = @_;
    return () unless defined $spec;
    return grep { length } map { my ( undef, $to ) = split /=/, $_, 2; ( $to // '' ) =~ s/\A\s+|\s+\z//gr }
        grep { /=/ } split /,/, $spec;
}

sub _slurp {
    my ( $path, $what, $faults ) = @_;
    open my $fh, '<:utf8', $path or do {
        push @{$faults}, "$what could not be read ($!)" unless $!{ENOENT};
        return undef;
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw // '';
}

sub _json {
    my ( $path, $what, $faults ) = @_;
    my $raw = _slurp( $path, $what, $faults );
    return undef unless defined $raw;
    my $d = eval { JSON::PP::decode_json( length $raw ? $raw : '{}' ) };
    unless ( ref $d eq 'HASH' ) {
        push @{$faults}, "$what does not decode as a JSON object";
        return undef;
    }
    return $d;
}

# A key's names from YAML-ish text: `key: [a, b]`, `key: a, b`, or `- a` lines
# under it. $indent allows the key to sit inside a record.
sub _list_key {
    my ( $text, $key ) = @_;
    my ( @out, $in );
    for my $line ( split /\n/, $text // '' ) {
        if ( $line =~ /^\s*\Q$key\E\s*:\s*(.*?)\s*$/ ) {
            my $v = $1;
            $v = $1 if $v =~ /\A\[(.*)\]\z/;
            push @out, _names($v);
            $in = !length $v;
            next;
        }
        if ( $in && $line =~ /^[ \t]*-[ \t]*(.+?)\s*$/ ) { push @out, _names($1); next }
        $in = 0;
    }
    return @out;
}

sub _front_matter {
    my ($p) = @_;
    open my $fh, '<:utf8', $p or return '';
    my $first = <$fh>;
    my $head  = '';
    if ( defined $first && $first =~ /^---\s*$/ ) {
        while ( my $l = <$fh> ) { last if $l =~ /^---\s*$/; $head .= $l }
    }
    close $fh;
    return $head;
}

sub refs {
    my ($docroot) = @_;
    my ( @refs, @faults );
    my $lz = Lazysite::Paths::lazysite_dir($docroot);

    # Pages: the served tree and the private store, the engine's own tree pruned.
    my @roots = ($docroot);
    my $priv  = Lazysite::Private::private_root($docroot);
    push @roots, $priv if defined $priv && -d $priv;
    my $internal = Lazysite::Paths::internal_lazysite_dir($docroot);
    my %unread;
    local $SIG{__WARN__} = sub {
        my ($m) = @_;
        if ( $m =~ /\ACan't (?:opendir|stat|cd to)\s*\(?(.*?)\)?: ([^\n]*)/ ) { $unread{$1} //= $2; return }
        print STDERR $m;
    };
    for my $root (@roots) {
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    my $p = $File::Find::name;
                    if ( -d $p ) {
                        $File::Find::prune = 1 if defined $internal && $p eq $internal;
                        return;
                    }
                    return unless $p =~ /\.md\z/;
                    ( my $rel = $p ) =~ s{\A\Q$root\E/}{};
                    push @refs, { where => 'page', ref => $rel, name => $_ }
                        for _list_key( _front_matter($p), 'auth_groups' );
                },
            },
            $root
        ) if -d $root;
    }
    push @faults, "could not read directory $_ ($unread{$_})" for sort keys %unread;

    # Access rules: "@group" in read and write.
    my $acls = _json( "$lz/auth/acls.json", 'acls.json', \@faults );
    for my $path ( sort keys %{ $acls || {} } ) {
        my $e = $acls->{$path};
        next unless ref $e eq 'HASH';
        for my $f (qw(read write)) {
            push @refs, { where => 'acl', ref => $path, name => $_ }
                for map { substr $_, 1 } grep { /\A@./ } _names( $e->{$f} );
        }
    }

    # lazysite.conf: domain access, the directory map.
    if ( defined( my $conf = _slurp( "$lz/lazysite.conf", 'lazysite.conf', \@faults ) ) ) {
        for my $l ( split /\n/, $conf ) {
            next if $l =~ /^\s*#/;
            if ( $l =~ /^(allowed_groups|locked_groups)\s*:\s*(.*?)\s*$/ ) {
                push @refs, { where => 'domain', ref => "(default) $1", name => $_ } for _names($2);
            }
            elsif ( $l =~ /^alias\.(\S+?)\.(allowed_groups|locked_groups)\s*:\s*(.*?)\s*$/ ) {
                push @refs, { where => 'domain', ref => "$1 $2", name => $_ } for _names($3);
            }
            elsif ( $l =~ /^auth_group_map\s*:\s*(.*?)\s*$/ ) {
                push @refs, { where => 'conf', ref => 'auth_group_map', name => $_ } for _map_targets($1);
            }
        }
    }

    # Data tables: writable_by.
    my $tdir = "$lz/db/tables";
    if ( opendir my $dh, $tdir ) {
        for my $f ( sort grep { /\.ya?ml\z/ } readdir $dh ) {
            ( my $t = $f ) =~ s/\.ya?ml\z//;
            my $raw = _slurp( "$tdir/$f", "table $t", \@faults );
            next unless defined $raw;
            push @refs, { where => 'table', ref => $t, name => $_ } for _list_key( $raw, 'writable_by' );
        }
        closedir $dh;
    }
    elsif ( -e $tdir ) { push @faults, "db/tables could not be read ($!)" }

    # handlers.conf: an Odoo binding's callers.
    if ( defined( my $h = _slurp( "$lz/forms/handlers.conf", 'handlers.conf', \@faults ) ) ) {
        my ( $id, $type, @callers, @recs );
        my $close = sub { push @recs, [ $id, $type, [@callers] ] if defined $id; ( $id, $type, @callers ) = () };
        for my $line ( split /\n/, $h ) {
            next if $line =~ /\A\s*(?:#|\z)/;
            if ( $line =~ /\A[ \t]*-[ \t]+id[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) { $close->(); $id = $1; next }
            if ( defined $id && $line =~ /\A[ \t]+type[ \t]*:[ \t]*(\S+)/ ) { $type = $1; next }
            if ( defined $id && $line =~ /\A[ \t]+callers[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
                ( my $v = $1 ) =~ s/\A\[(.*)\]\z/$1/;
                push @callers, _names($v);
                next;
            }
            $close->() if $line =~ /\A\S/;
        }
        $close->();
        for my $r (@recs) {
            next unless ( $r->[1] // '' ) eq 'odoo';
            push @refs, { where => 'binding', ref => $r->[0], name => $_ } for @{ $r->[2] };
        }
    }

    # connectors.json: a connector's callers.
    my $conn = _json( "$lz/connectors/connectors.json", 'connectors.json', \@faults );
    for my $c ( sort keys %{ $conn || {} } ) {
        my $e = $conn->{$c};
        next unless ref $e eq 'HASH';
        push @refs, { where => 'connector', ref => $c, name => $_ } for _names( $e->{callers} );
    }

    # odoo.conf: the Odoo group map's lazysite side.
    if ( defined( my $o = _slurp( "$lz/odoo.conf", 'odoo.conf', \@faults ) ) ) {
        for my $l ( split /\n/, $o ) {
            push @refs, { where => 'odoo', ref => 'odoo_group_map', name => $_ }
                for $l =~ /\A\s*odoo_group_map\s*:\s*(.*?)\s*\z/ ? _map_targets($1) : ();
        }
    }

    return { refs => \@refs, faults => \@faults };
}

# "pages a, b; access rules for ...": one line saying where, capped at five each.
sub describe {
    my (@r) = @_;
    my %by;
    push @{ $by{ $_->{where} } }, $_->{ref} for @r;
    my %label = (
        page      => 'page',
        acl       => 'access rule for',
        domain    => 'domain',
        conf      => 'lazysite.conf key',
        table     => 'data table',
        binding   => 'Odoo binding',
        connector => 'connector',
        odoo      => 'odoo.conf key',
    );
    my @out;
    for my $w (qw(page acl domain table binding connector conf odoo)) {
        next unless $by{$w};
        my %u;
        my @refs = grep { !$u{$_}++ } sort @{ $by{$w} };
        my $more = @refs > 5 ? ' (and ' . ( @refs - 5 ) . ' more)' : '';
        splice @refs, 5 if @refs > 5;
        push @out, "$label{$w} " . join( ', ', @refs ) . $more;
    }
    return join( '; ', @out );
}

1;

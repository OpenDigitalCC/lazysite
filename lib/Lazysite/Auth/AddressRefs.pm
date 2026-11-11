package Lazysite::Auth::AddressRefs;

# SM1141 (slice D of SM1134): WHERE A RULE NAMES AN ADDRESS PROFILE.
#
# Two readers need the same answer and must not each carry their own walk:
# `lazysite check` (warn when a rule names a profile that is not in the store, or
# when rules exist and the front end is not trusted) and the users tool's
# address-profile-delete (refuse to delete a profile a rule still names, and say where).
# A deleted profile is not an empty one - a rule allowing it admits nobody
# (SM1138) - so a delete that did not look would lock a page, a folder, a group or
# the manager out with nothing said.
#
# The places a rule names profiles are the SM1134 contract's, and only these:
#   page front matter     addresses: [a]      addresses_deny: [b]
#   acls.json entry       fields addresses, addresses_deny (a list of names)
#   groups-settings.json  fields addresses, addresses_deny (a list of names)
#   lazysite.conf         manager_addresses, manager_addresses_deny (comma list)
#                         signin_addresses, signin_addresses_deny
#                         bad_url_exempt (SM1321: profile names only, ruling 84; the
#                         blocker asks membership only, so slot 'match')
#   handlers.conf         a handler's fields of type `address_profiles` (SM1369 X3, I-13):
#                         the handler catalogue says which fields of which types
#                         name profiles, and in which slot (Lazysite::Handlers::
#                         address_profile_fields) - a session binding's sign-in limit
#                         (SM1229; SM1159 held it on the binding's calls) and the
#                         profile its operation is told about (SM1280) are the
#                         extension's own declaration now, found by type, not by name
# This module reads the files itself and loads nothing else of the engine's but the
# handler catalogue, so it answers the same from the shell, the check and the
# manager, and does not depend on the slices that enforce the rules being installed.
#
# rules($docroot) -> { rules => [ {where, ref, slot, name} ], faults => [ text ] }
#   where  'page' | 'acl' | 'group' | 'conf' | 'binding'
#   ref    page path (docroot-relative), acl path, group name, conf key, handler id
#   slot   'allow' | 'deny' (the profile allowed or denied, SM1343: a profile has no
#          kind, the slot is the choice), or 'match' for a field that asks membership
#          only (SM1280)
# A store that exists and will not read or decode is a FAULT, named, never read as
# "no rules" (SM1024): the caller cannot say a profile is unreferenced then.

use strict;
use warnings;
use File::Find ();
use JSON::PP   ();
use Exporter 'import';
use Lazysite::Paths   ();
use Lazysite::Private ();

our @EXPORT_OK = qw(rules describe page_names);

my %SLOT = ( addresses => 'allow', addresses_deny => 'deny' );

sub _json {
    my ( $path, $what, $faults ) = @_;
    open my $fh, '<:raw', $path or do {
        unless ( $!{ENOENT} ) {
            # n818 (SM1440): who could not read it, and the owner: unix users to the CLI, the
            # web server's user and "the owner of the file" through a web door (ruling 243).
            my $err = "$!";
            require Lazysite::Util;
            push @{$faults}, "$what " . Lazysite::Util::unreadable_clause( $path, $err );
        }
        return undef;
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( length( $raw // '' ) ? $raw : '{}' ) };
    unless ( ref $d eq 'HASH' ) {
        push @{$faults}, "$what does not decode as a JSON object";
        return undef;
    }
    return $d;
}

# A names field is a list of names; a lone string or a comma list is read the same.
sub _names {
    my ($v) = @_;
    return () unless defined $v;
    my @n = ref $v eq 'ARRAY' ? ( grep { defined $_ && !ref $_ } @{$v} ) : ( ref $v ? () : ($v) );
    return grep { length } map { s/\A\s+|\s+\z//gr } map { split /,/ } @n;
}

# Front matter: flow list, scalar or comma list, or a block list under the key.
sub _page_names {
    my ($text) = @_;
    my ($fm)   = $text =~ /\A---\s*\n(.*?)\n---\s*(?:\n|\z)/s or return ();
    my ( @out, $key );
    for my $line ( split /\n/, $fm ) {
        if ( $line =~ /^(addresses|addresses_deny)\s*:\s*(.*?)\s*$/ ) {
            $key = $1;
            my $v = $2;
            if ( $v =~ /\A\[(.*)\]\z/ ) { $v = $1 }
            for my $n ( _names( [ split /,/, $v ] ) ) {
                $n =~ s/\A["']|["']\z//g;
                push @out, [ $SLOT{$key}, $n ] if length $n;
            }
            $key = undef if length $v;
            next;
        }
        if ( defined $key && $line =~ /^[ \t]+-[ \t]*(.+?)\s*$/ ) {
            ( my $n = $1 ) =~ s/\A["']|["']\z//g;
            push @out, [ $SLOT{$key}, $n ] if length $n;
            next;
        }
        $key = undef if $line !~ /^[ \t]/;
    }
    return @out;
}

# n812: the profiles a page's front matter names, [ slot, name ] pairs, for the write
# doors that refuse a page naming one the store lacks (Manager::Common).
sub page_names { return _page_names(@_) }

sub _conf_names {
    my ($conf) = @_;
    my %v;
    open my $fh, '<:utf8', $conf or return %v;
    while ( my $l = <$fh> ) {
        $v{$1} = $2 if $l =~ /^( (?:manager|signin)_addresses(?:_deny)? | bad_url_exempt )\s*:\s*(.*?)\s*$/x;
    }
    close $fh;
    return %v;
}

# SM1229: a handler's own address-profile fields. The records are read straight
# from lazysite/forms/handlers.conf; which fields name profiles, and in which slot,
# is the handler catalogue's answer (SM1369 X3: by the field type `address_profiles`,
# so a type an extension declares is found as a core one would be). A field
# carrying names uses them exactly as lazysite.conf's keys do, so deleting one it
# names would leave a session binding refusing every call (a rule allowing a
# deleted profile admits nobody, SM1138). Disabled handlers count: they can be
# switched on again.
sub _binding_rules {
    my ( $path, $rules, $faults, $docroot ) = @_;
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $fields = Lazysite::Handlers::address_profile_fields();
    return unless %$fields;
    open my $fh, '<:utf8', $path or do {
        push @{$faults}, "handlers.conf could not be read ($!)" unless $!{ENOENT};
        return;
    };
    my ( $cur, @recs );
    while ( my $line = <$fh> ) {
        $line =~ s/\r?\n\z//;
        next if $line =~ /\A\s*(?:#|\z)/;
        if ( $line =~ /\A[ \t]*-[ \t]+id[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) {
            $cur = { id => $1 };
            push @recs, $cur;
            next;
        }
        if ( $cur && $line =~ /\A[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
            $cur->{$1} = $2 if length $2;
            next;
        }
        undef $cur if $line =~ /\A\S/;
    }
    close $fh;
    for my $r (@recs) {
        my $of = $fields->{ $r->{type} // '' } or next;
        for my $f (@$of) {
            ( my $v = $r->{ $f->{key} } // '' ) =~ s/\A\[(.*)\]\z/$1/;
            push @{$rules}, { where => 'binding', ref => $r->{id}, slot => $f->{slot}, name => $_ }
                for map { s/\A["']|["']\z//gr } _names( [ split /,/, $v ] );
        }
    }
    return;
}

sub rules {
    my ($docroot) = @_;
    my ( @rules, @faults );
    my $lz   = Lazysite::Paths::lazysite_dir($docroot);
    my $auth = "$lz/auth";

    # Pages: the served tree and the private store, the engine's own tree pruned.
    my @roots = ($docroot);
    my $priv  = Lazysite::Private::private_root($docroot);
    push @roots, $priv if defined $priv && -d $priv;
    my $internal = Lazysite::Paths::internal_lazysite_dir($docroot);
    # A directory this run cannot open is a place a rule could hide: told as a
    # fault, once each, never as File::Find's raw warning (t/tools/108).
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
                    open my $fh, '<:utf8', $p or return;
                    my $head = '';
                    # Only the front matter is wanted; stop at its closing line.
                    my $first = <$fh>;
                    if ( defined $first && $first =~ /^---\s*$/ ) {
                        $head = $first;
                        while ( my $l = <$fh> ) { $head .= $l; last if $l =~ /^---\s*$/ }
                    }
                    close $fh;
                    ( my $rel = $p ) =~ s{\A\Q$root\E/}{};
                    for my $r ( _page_names($head) ) {
                        push @rules, { where => 'page', ref => $rel, slot => $r->[0], name => $r->[1] };
                    }
                },
            },
            $root
        );
    }

    push @faults, "could not read directory $_ ($unread{$_})" for sort keys %unread;

    my $acls = _json( "$auth/acls.json", 'acls.json', \@faults );
    for my $path ( sort keys %{ $acls || {} } ) {
        my $e = $acls->{$path};
        next unless ref $e eq 'HASH';
        for my $f ( sort keys %SLOT ) {
            push @rules, { where => 'acl', ref => $path, slot => $SLOT{$f}, name => $_ } for _names( $e->{$f} );
        }
    }

    my $groups = _json( "$auth/groups-settings.json", 'groups-settings.json', \@faults );
    for my $g ( sort keys %{ $groups || {} } ) {
        my $e = $groups->{$g};
        next unless ref $e eq 'HASH';
        for my $f ( sort keys %SLOT ) {
            push @rules, { where => 'group', ref => $g, slot => $SLOT{$f}, name => $_ } for _names( $e->{$f} );
        }
    }

    my %conf = _conf_names("$lz/lazysite.conf");
    push @rules, { where => 'conf', ref => 'manager_addresses', slot => 'allow', name => $_ }
        for _names( $conf{manager_addresses} );
    push @rules, { where => 'conf', ref => 'manager_addresses_deny', slot => 'deny', name => $_ }
        for _names( $conf{manager_addresses_deny} );
    # SM1159: sign-in's own limit names profiles too, so a profile it uses is not deleted.
    push @rules, { where => 'conf', ref => 'signin_addresses', slot => 'allow', name => $_ }
        for _names( $conf{signin_addresses} );
    push @rules, { where => 'conf', ref => 'signin_addresses_deny', slot => 'deny', name => $_ }
        for _names( $conf{signin_addresses_deny} );
    # SM1321: the bad-URL blocker's exempt profiles (ruling 84: names only, so every item
    # is one, and one the store lacks is reported like any other; `none` is no name).
    push @rules, { where => 'conf', ref => 'bad_url_exempt', slot => 'match', name => $_ }
        for grep { lc $_ ne 'none' } _names( $conf{bad_url_exempt} );

    _binding_rules( "$lz/forms/handlers.conf", \@rules, \@faults, $docroot );

    return { rules => \@rules, faults => \@faults };
}

# "pages /a, /b; folders ...": one line saying where the given rules are, capped.
sub describe {
    my (@r) = @_;
    my %by;
    push @{ $by{ $_->{where} } }, $_->{ref} for @r;
    my %label = ( page => 'page', acl => 'access rule for', group => 'group', conf => 'lazysite.conf key', binding => 'handler' );
    my @out;
    for my $w (qw(page acl group conf binding)) {
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

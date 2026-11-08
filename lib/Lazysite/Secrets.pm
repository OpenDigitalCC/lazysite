package Lazysite::Secrets;

# SM1369 X6, H-11 (ruling 55): THE ONE SECRETS STORE.
#
# A secret is something the site holds to hand to another system - a connector's
# token, an extension's API key - and never shows again. Core had two stores for
# them: the connectors' (lazysite/connectors/secrets.json, SM579, SM768) and the
# Odoo extension's (lazysite/odoo/keys/<account>.key, SM747 R1, "stored as
# connector secrets are"). This is the one both use now, and the one any
# extension uses, by its id. Its rules are the connectors' store's, which R1 held
# the other to:
#
#   * WRITTEN ON ITS OWN, ATOMICALLY, 0600 FROM THE MOMENT IT EXISTS: a temporary
#     file created under a 077 umask, then renamed into place, in a 0700
#     directory - there is no instant at which a secret sits in a file group or
#     other could read. Its group follows the directory (secure_write_perms).
#   * NEVER LISTED, NEVER READ BACK BY A LISTING: there is no list here. has()
#     answers 1 (there), 0 (none) or undef - the file exists and this process
#     cannot open it (SM768: a store that cannot be read is a refusal, never an
#     absence, so 0 would invite re-entering a secret that is still in place).
#   * ONE SECRET, ONE FILE: lazysite/<owner>/keys/<name>.key. A consumer that is
#     handed a file rather than a value - OOM's `file` credential, which refuses a
#     file group or other can read - is given path(); the Odoo keys were already
#     laid out this way and are read where they are.
#
# An extension reaches only its own secrets: the owner is its id, and its own
# code passes it (G-7). The connectors' older map, secrets.json, is read by
# Lazysite::Manager::Connectors as a fallback until each secret is next set or
# cleared, so a secret set before this store stays readable across the upgrade.
use strict;
use warnings;
use File::Path     qw(make_path);
use Lazysite::Util qw(cannot_read secure_write_perms);

my $OWNER = qr/\A[a-z][a-z0-9-]{0,31}\z/;
my $NAME  = qr/\A[a-z0-9][a-z0-9_-]{0,63}\z/;

sub valid_owner { my ($o) = @_; return defined $o && !ref $o && $o =~ $OWNER ? 1 : 0 }
sub valid_name  { my ($n) = @_; return defined $n && !ref $n && $n =~ $NAME  ? 1 : 0 }

sub dir {
    my ( $lz, $owner ) = @_;
    return undef unless defined $lz && length $lz && valid_owner($owner);
    return "$lz/$owner/keys";
}

# The file a secret is in, for a consumer handed a path. Never shown to a
# caller: an error names the secret, never the host path.
sub path {
    my ( $lz, $owner, $name ) = @_;
    my $d = dir( $lz, $owner ) // return undef;
    return undef unless valid_name($name);
    return "$d/$name.key";
}

# ( $value, 'ok' ), ( undef, 'absent' ) or ( undef, 'unreadable' ). The value is
# the file's first line; a file with nothing in it is absent.
sub get {
    my ( $lz, $owner, $name ) = @_;
    my $p = path( $lz, $owner, $name ) // return ( undef, 'absent' );
    open my $fh, '<', $p or do {
        return ( undef, 'absent' ) if $!{ENOENT};
        cannot_read( "the secret '$name' of $owner", $p );
        return ( undef, 'unreadable' );
    };
    my $v = <$fh>;
    close $fh;
    chomp $v if defined $v;
    return defined $v && $v =~ /\S/ ? ( $v, 'ok' ) : ( undef, 'absent' );
}

# 1, 0, or undef for "cannot tell".
sub has {
    my ( $lz, $owner, $name ) = @_;
    my ( undef, $state ) = get( $lz, $owner, $name );
    return $state eq 'ok' ? 1 : $state eq 'absent' ? 0 : undef;
}

sub _cannot_write {
    my ( $owner, $what ) = @_;
    my ($who) = getpwuid($>);
    $what =~ s{/\S+/}{}g;    # the file's name, never the host path
    return "cannot write $owner/keys - $what (unix user " . ( $who // $> ) . ')';
}

# ( 1, '' ) or ( 0, why ). One line, as it will be handed on; the owner's own
# rules for what a value may be (a key's length, its characters) are its own
# and are checked before this. Refused over a secret that is there and cannot be
# read: writing past it would hide the fault that made it unreadable.
sub put {
    my ( $lz, $owner, $name, $value ) = @_;
    return ( 0, 'no such owner of secrets' ) unless valid_owner($owner);
    return ( 0, 'the secret\'s name must be lower-case letters, digits, - or _' ) unless valid_name($name);
    return ( 0, 'a secret is required' ) unless defined $value && !ref $value && length $value;
    return ( 0, 'a secret must be one line' ) if $value =~ /[\r\n\0]/;
    my $p = path( $lz, $owner, $name );
    return ( 0, "the secret '$name' exists and cannot be read by this process; nothing was written" )
        unless defined has( $lz, $owner, $name );

    my $d    = dir( $lz, $owner );
    my $made = eval { make_path( $d, { mode => 0700 } ) unless -d $d; 1 };
    return ( 0, _cannot_write( $owner, "the key directory: $@" ) ) unless $made;
    my $tmp = "$p.tmp.$$";
    my $old = umask 077;
    my $ok  = open my $fh, '>', $tmp;
    umask $old;
    return ( 0, _cannot_write( $owner, "$name.key: $!" ) ) unless $ok;
    print {$fh} "$value\n";
    close $fh or do { unlink $tmp; return ( 0, _cannot_write( $owner, "$name.key: $!" ) ) };
    secure_write_perms( $tmp, 0600 );
    rename $tmp, $p or do { unlink $tmp; return ( 0, _cannot_write( $owner, "$name.key: $!" ) ) };
    return ( 1, '' );
}

# ( 1, '' ) or ( 0, why ). Gone already is cleared.
sub clear {
    my ( $lz, $owner, $name ) = @_;
    my $p = path( $lz, $owner, $name )
        // return ( 0, 'the secret\'s name must be lower-case letters, digits, - or _' );
    if ( !unlink $p ) {
        return ( 1, '' ) if $!{ENOENT};
        return ( 0, _cannot_write( $owner, "$name.key: $!" ) );
    }
    return ( 1, '' );
}

1;

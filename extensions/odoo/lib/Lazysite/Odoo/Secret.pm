package Lazysite::Odoo::Secret;

# SM747 CU / OB1 (amended 2026-10-12, R1): THE CONNECTION USER'S API KEY.
#
# The one Odoo credential lazysite stores, on the terms R1 set: "stored as
# connector secrets are" - in its own 0600 file, written on its own, never
# listed, never returned by any action or tool, never logged, and `has_secret`
# answering 1, 0, or null for "cannot tell".
#
# ONE FILE PER ACCOUNT, NOT ONE JSON FOR ALL. The key reaches OOM through OOM's
# own `file` credential strategy (api_key_file), which reads one key from one
# file and refuses a file group or other can read (Odoo::Ops::Credential). So
# the store IS that file, and OOM's mode check applies on top of this one. Q2
# (ruled 2026-10-12) gives an MCP grant an account of its own; that is a second
# file under the same directory, named by the account.
#
# AN API KEY, NEVER A PASSWORD. OOM refuses a password in its config; the key
# is what an Odoo administrator issues for the connection user.
use strict;
use warnings;
use File::Path      qw(make_path);
use Lazysite::Util  qw(log_event cannot_read);
use Lazysite::Paths ();

our $DOCROOT = '';

sub _dir { return Lazysite::Paths::lazysite_dir($DOCROOT) . '/odoo/keys' }

sub _valid_account { return defined $_[0] && $_[0] =~ /\A[a-z][a-z0-9_-]{0,63}\z/ }

# The path OOM is given. Never shown to a caller: an error names the account.
sub key_path {
    my ($account) = @_;
    return undef unless _valid_account($account);
    return _dir() . "/$account.key";
}

# 1 (a key is there), 0 (none), undef (the file exists and this process cannot
# open it - SM768: unopenable is not absent, and 0 would invite re-entering a
# key that is still in place).
sub has_key {
    my ($account) = @_;
    my $p = key_path($account) // return 0;
    open my $fh, '<', $p or do {
        return 0 if $!{ENOENT};
        cannot_read( "the Odoo key for '$account'", $p );
        return undef;
    };
    my $k = <$fh>;
    close $fh;
    return ( defined $k && $k =~ /\S/ ) ? 1 : 0;
}

# Written on its own, alone in its file, 0600 from the moment it exists: the
# temporary file is created under a 077 umask, so there is no instant at which
# the key sits in a file group or other could read.
sub set_key {
    my ( $account, $key ) = @_;
    return ( 0, 'the account name must be lower-case letters, digits, - or _' )
        unless _valid_account($account);
    return ( 0, 'an API key is required' ) unless defined $key && length $key;
    return ( 0, 'the API key must be one line' )              if $key =~ /[\r\n]/;
    return ( 0, 'the API key is longer than 512 characters' ) if length $key > 512;
    return ( 0, 'the API key must be printable characters with no spaces' )
        unless $key =~ /\A[\x21-\x7e]+\z/;

    my $dir  = _dir();
    my $made = eval { make_path( $dir, { mode => 0700 } ) unless -d $dir; 1 };
    return ( 0, _cannot_write("the key directory: $@") ) unless $made;
    my $path = key_path($account);
    my $tmp  = "$path.tmp.$$";
    my $old  = umask 077;
    my $ok   = open my $fh, '>', $tmp;
    umask $old;
    return ( 0, _cannot_write("$account.key: $!") ) unless $ok;
    print {$fh} "$key\n";
    close $fh or do { unlink $tmp; return ( 0, _cannot_write("$account.key: $!") ) };
    chmod 0600, $tmp;
    rename $tmp, $path or do { unlink $tmp; return ( 0, _cannot_write("$account.key: $!") ) };
    log_event( 'INFO', 'odoo', 'odoo key set', account => $account );
    return ( 1, '' );
}

sub clear_key {
    my ($account) = @_;
    my $p = key_path($account)
        // return ( 0, 'the account name must be lower-case letters, digits, - or _' );
    if ( !unlink $p ) {
        return ( 1, '' ) if $!{ENOENT};
        return ( 0, _cannot_write("$account.key: $!") );
    }
    log_event( 'INFO', 'odoo', 'odoo key cleared', account => $account );
    return ( 1, '' );
}

sub _cannot_write {
    my ($what) = @_;
    my ($who)  = getpwuid($>);
    $what =~ s{/\S+/}{}g;    # the file's name, never the host path
    return "cannot write odoo/keys - $what (unix user " . ( $who // $> ) . ')';
}

1;

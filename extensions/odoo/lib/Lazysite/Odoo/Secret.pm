package Lazysite::Odoo::Secret;

# SM747 CU / OB1 (amended 2026-10-12, R1): THE CONNECTION USER'S API KEY.
#
# The one Odoo credential lazysite stores, on the terms R1 set: "stored as
# connector secrets are" - in its own 0600 file, written on its own, never
# listed, never returned by any action or tool, never logged, and `has_secret`
# answering 1, 0, or null for "cannot tell".
#
# SM1369 X6, H-11 (n782): IN THE ONE SECRETS STORE. The store is core's now,
# Lazysite::Secrets, shared with the connectors and with any extension; this
# extension's secrets are its own by its id, at lazysite/odoo/keys/<account>.key,
# where they always were, so every key set before the change is read where it
# is. What is this extension's is what a key may be (below) and the log line.
#
# ONE FILE PER ACCOUNT, NOT ONE JSON FOR ALL. The key reaches OOM through OOM's
# own `file` credential strategy (api_key_file), which reads one key from one
# file and refuses a file group or other can read (Odoo::Ops::Credential). So
# the store's file IS that file (Lazysite::Secrets::path), and OOM's mode check
# applies on top of the store's. Q2 (ruled 2026-10-12) gives an MCP grant an
# account of its own; that is a second secret of the same owner, named by the
# account.
#
# AN API KEY, NEVER A PASSWORD. OOM refuses a password in its config; the key
# is what an Odoo administrator issues for the connection user.
use strict;
use warnings;
use Lazysite::Util    qw(log_event);
use Lazysite::Paths   ();
use Lazysite::Secrets ();

our $DOCROOT = '';

my $OWNER = 'odoo';

sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }

sub _valid_account { return defined $_[0] && $_[0] =~ /\A[a-z][a-z0-9_-]{0,63}\z/ }

# The path OOM is given. Never shown to a caller: an error names the account.
sub key_path {
    my ($account) = @_;
    return undef unless _valid_account($account);
    return Lazysite::Secrets::path( _lz(), $OWNER, $account );
}

# 1 (a key is there), 0 (none), undef (the file exists and this process cannot
# open it - SM768: unopenable is not absent, and 0 would invite re-entering a
# key that is still in place).
sub has_key {
    my ($account) = @_;
    return 0 unless _valid_account($account);
    return Lazysite::Secrets::has( _lz(), $OWNER, $account );
}

# Written on its own, alone in its file, 0600 from the moment it exists (the
# store's rule).
sub set_key {
    my ( $account, $key ) = @_;
    return ( 0, 'the account name must be lower-case letters, digits, - or _' )
        unless _valid_account($account);
    return ( 0, 'an API key is required' ) unless defined $key && length $key;
    return ( 0, 'the API key must be one line' )              if $key =~ /[\r\n]/;
    return ( 0, 'the API key is longer than 512 characters' ) if length $key > 512;
    return ( 0, 'the API key must be printable characters with no spaces' )
        unless $key =~ /\A[\x21-\x7e]+\z/;
    my ( $ok, $why ) = Lazysite::Secrets::put( _lz(), $OWNER, $account, $key );
    return ( 0, $why ) unless $ok;
    log_event( 'INFO', 'odoo', 'odoo key set', account => $account );
    return ( 1, '' );
}

sub clear_key {
    my ($account) = @_;
    return ( 0, 'the account name must be lower-case letters, digits, - or _' )
        unless _valid_account($account);
    my ( $ok, $why ) = Lazysite::Secrets::clear( _lz(), $OWNER, $account );
    return ( 0, $why ) unless $ok;
    log_event( 'INFO', 'odoo', 'odoo key cleared', account => $account );
    return ( 1, '' );
}

1;

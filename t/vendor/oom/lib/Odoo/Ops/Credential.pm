package Odoo::Ops::Credential;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Time::Local ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Credential - credential strategies

=head1 DESCRIPTION

One contract for every strategy: C<< resolve($config) >> returns the
arguments L<Odoo::Client> needs to authenticate (C<login> plus
C<api_key>). Everything downstream is strategy-independent - the same
shape SM747 OA1 asks the lazysite extension to keep.

Strategies:

    file     an API key in its own file, readable by the owner only.
             Shipped.
    password a login and a password file: the context exchanges them once
             for Odoo's web session (Odoo::Transport::Session) and every
             call, RPC and report route alike, runs as that user over it.
             The config carries `credential = password`, `login` and
             `password_file` (the password alone on its first line,
             owner-only, refused otherwise). An API key cannot open a web
             session on any series: Odoo's web login takes the password,
             which is why this strategy exists. Shipped (0.16).
    session  a web session id the CALLER holds at run time (never a
             file): the config carries it under `session`, built in
             memory with Odoo::Ops::Config->new. The context then
             speaks Odoo::Transport::Session as that user. Shipped
             (0.03).
    cookie   reserved; a consumer that replays a per-user credential
             from a cookie turns it into a session first.
    dsn      not an Odoo login: the database a Source dbi reader reads.
             A file of dsn, user and password lines (see L</dsn>),
             owner-only, never inline in a mapping or config. Shipped
             (0.08).
    lazysite_token
             not an Odoo login: the token of a lazysite site's manager
             API, read by a Source lazysite-table reader. A JSON file of
             partner, token and expires, owner-only (see
             L</lazysite_token>). Shipped (0.08).

A reserved strategy dies as kind C<config>, by name, rather than
falling back to anything.

=cut

my %STRATEGY = (
    file    => \&_file,
    password => \&_password,
    session => \&_session,
    cookie  => sub ($c) { _reserved('cookie') },
);

sub resolve ($class, $config) {
    my $name = $config->get('credential') // 'file';
    my $impl = $STRATEGY{$name}
        or Odoo::Error->throw( kind => 'config', message => "unknown credential strategy '$name'" );
    return $impl->($config);
}

sub _file ($config) {
    my $path = $config->get('api_key_file')
        or Odoo::Error->throw( kind => 'config', message => 'file credential needs api_key_file' );
    my @st = stat $path
        or Odoo::Error->throw( kind => 'config', message => "cannot stat api_key_file $path: $!" );
    Odoo::Error->throw(
        kind    => 'config',
        message => sprintf( 'api_key_file %s is mode %04o; it must deny group and other (chmod 600)',
            $path, $st[2] & 07777 ),
    ) if $st[2] & 077;
    open my $fh, '<', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot read api_key_file $path: $!" );
    my $key = <$fh>;
    close $fh;
    chomp $key if defined $key;
    Odoo::Error->throw( kind => 'config', message => "api_key_file $path is empty" )
        if !defined $key || $key eq '';
    return ( login => $config->get('login'), api_key => $key );
}

=head2 secret_file($path, $what)

The first line of an owner-only file, for a secret kept apart from the
configuration (an LDAP bind password). Refuses a file readable by group
or other, a missing one and an empty one, naming the file and never
the value.

=cut

sub secret_file ($class, $path, $what = 'secret file') {
    my $text = _owner_only_text( $path, $what );
    my ($line) = split /\n/, $text, 2;
    Odoo::Error->throw( kind => 'config', message => "$what $path is empty" )
        if !defined $line || $line eq '';
    return $line;
}

=head2 dsn($path)

The credential of a database for a Source C<dbi> reader: a file of
C<key = value> lines (comments with C<#>, blank lines ignored) naming
C<dsn> (required), C<user> and C<password>. Mode must deny group and
other. Returns C<< { dsn, user, password } >>; the password is never
part of an error message.

=cut

sub dsn ($class, $path) {
    my $text = _owner_only_text( $path, 'dsn credential' );
    my %c;
    for my $line ( split /\n/, $text ) {
        next if $line =~ /^\s*(?:#|\z)/;
        my ( $k, $v ) = $line =~ /^\s*(\w+)\s*=\s*(.*?)\s*\z/
            or Odoo::Error->throw( kind => 'config', message => "dsn credential $path: expected key = value" );
        Odoo::Error->throw( kind => 'config', message => "dsn credential $path: unknown key '$k' (dsn, user, password)" )
            if $k !~ /^(?:dsn|user|password)\z/;
        $c{$k} = $v;
    }
    Odoo::Error->throw( kind => 'config', message => "dsn credential $path has no dsn line" )
        if !defined $c{dsn} || $c{dsn} eq '';
    return \%c;
}

=head2 lazysite_token($path, %opts)

The credential of a lazysite site's manager API: a JSON file
C<< { "partner": "...", "token": "...", "expires": "..." } >> (mode must
deny group and other). C<partner> and C<token> are required. C<expires>
is optional: an ISO 8601 date-time (C<2026-10-14T09:00:00Z>) or epoch
seconds. A token past it is refused as kind C<config> naming the file,
because rotation is not done here. C<< now => $epoch >> overrides the
clock for tests. The token is never part of an error message.

=cut

sub lazysite_token ($class, $path, %opts) {
    my $text = _owner_only_text( $path, 'lazysite_token credential' );
    my $c = eval { JSON::PP->new->utf8->decode($text) };
    Odoo::Error->throw( kind => 'config', message => "lazysite_token credential $path is not a JSON object" )
        if ref $c ne 'HASH';
    for my $k (qw(partner token)) {
        Odoo::Error->throw( kind => 'config', message => "lazysite_token credential $path has no $k" )
            if !defined $c->{$k} || ref $c->{$k} || $c->{$k} eq '';
    }
    if ( defined $c->{expires} && $c->{expires} ne '' ) {
        my $at = _epoch( $c->{expires} );
        Odoo::Error->throw( kind => 'config', message => "lazysite_token credential $path: cannot read expires '$c->{expires}' (ISO 8601 date-time or epoch seconds)" )
            if !defined $at;
        Odoo::Error->throw( kind => 'config', message => "lazysite_token credential $path has expired ($c->{expires}); it needs a fresh pairing, rotation is not done here" )
            if $at <= ( $opts{now} // time );
    }
    return { partner => $c->{partner}, token => $c->{token}, expires => $c->{expires} };
}

sub _epoch ($v) {
    return $v + 0 if $v =~ /^\d+(?:\.\d+)?\z/;
    my ( $y, $mo, $d, $h, $mi, $s, $z ) =
        $v =~ /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?\s*(Z|[-+]\d\d:?\d\d)?\z/
        or return undef;
    my $t = Time::Local::timegm( $s // 0, $mi, $h, $d, $mo - 1, $y );
    if ( $z && $z ne 'Z' ) {
        my ( $sg, $zh, $zm ) = $z =~ /^([-+])(\d\d):?(\d\d)\z/;
        my $off = $zh * 3600 + $zm * 60;
        $t -= $sg eq '+' ? $off : -$off;
    }
    return $t;
}

sub _owner_only_text ($path, $what) {
    my @st = stat $path
        or Odoo::Error->throw( kind => 'config', message => "cannot stat $what $path: $!" );
    Odoo::Error->throw(
        kind    => 'config',
        message => sprintf( '%s %s is mode %04o; it must deny group and other (chmod 600)', $what, $path, $st[2] & 07777 ),
    ) if $st[2] & 077;
    open my $fh, '<', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot read $what $path: $!" );
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text // '';
}

# The password stays in memory only as long as the context needs it to open
# the session; the file is named, never the value.
sub _password ($config) {
    my $path = $config->get('password_file')
        or Odoo::Error->throw( kind => 'config', message => 'password credential needs password_file' );
    my $login = $config->get('login');
    Odoo::Error->throw( kind => 'config', message => 'password credential needs login' )
        if !defined $login || $login eq '';
    my $pw = __PACKAGE__->secret_file( $path, 'password_file' );
    return ( login => $login, password => $pw, password_file => $path );
}

sub _session ($config) {
    my $sid = $config->get('session');
    Odoo::Error->throw( kind => 'config', message => 'session credential needs a run-time session value' )
        if !defined $sid || $sid eq '';
    return ( session => $sid );
}

sub _reserved ($name) {
    Odoo::Error->throw(
        kind    => 'config',
        message => "credential strategy '$name' is reserved for the lazysite extension (SM747) and not implemented here",
    );
}

1;

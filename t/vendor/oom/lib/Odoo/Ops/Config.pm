package Odoo::Ops::Config;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

=head1 NAME

Odoo::Ops::Config - key=value connection files

=head1 SYNOPSIS

    my $conf = Odoo::Ops::Config->load('/srv/data/conf/crm.conf');
    $conf->get('url');
    $conf->allow_writes;     # true only for a literal "allow_writes = 1"

=head1 DESCRIPTION

The same format the OOM integration tests use: one C<key = value> per
line, C<#> comments, blank lines ignored. Recognised keys:

    url db login          the connection (required)
    credential            strategy name, default 'file' (Odoo::Ops::Credential)
    api_key_file          for the file strategy; mode must deny group/other
    transport             jsonrpc (default), xmlrpc or json2 (19+; needs an API key)
    timeout               seconds per request
    max_response_bytes    cap on one answer
    lang tz               default context
    actor                 who is running operations (audit), default $USER
    runs_dir              where run folders are created
    profile_dir           extra profile search root
    profile_series        pin a profile series instead of the server's
    allow_writes          1 to permit apply on this instance; anything
                          else, or absent, means read-only
    approval              required (default): apply needs an approved run;
                          none: apply needs no approval (tests, trusted batch)
    plan_ttl              seconds a plan stays applicable, default 86400

An unknown key is refused, so a typo in C<allow_writes> can never
silently read as "writes off" or "writes on".

Values are never echoed by this module; C<api_key> inline is refused
outright - keys live in their own file.

=cut

my %KNOWN = map { $_ => 1 } qw(
    url db login credential api_key_file transport timeout
    max_response_bytes lang tz actor runs_dir profile_dir
    profile_series allow_writes name ssl_ca_file ssl_verify session
    approval plan_ttl
);

sub load ($class, $path) {
    open my $fh, '<', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot read config $path: $!" );
    my %conf;
    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /^\s*(#|\z)/;
        my ( $k, $v ) = $line =~ /^\s*([\w.]+)\s*=\s*(.*?)\s*\z/
            or Odoo::Error->throw(
                kind    => 'config',
                message => "$path line $.: expected key = value",
            );
        Odoo::Error->throw(
            kind    => 'config',
            message => "$path: api_key inline is refused; use api_key_file",
        ) if $k eq 'api_key' || $k eq 'password';
        Odoo::Error->throw(
            kind    => 'config',
            message => "$path: a session is a run-time value, never a file entry",
        ) if $k eq 'session';
        Odoo::Error->throw(
            kind    => 'config',
            message => "$path line $.: unknown key '$k'",
        ) if !$KNOWN{$k};
        $conf{$k} = $v;
    }
    close $fh;
    return $class->new( %conf, _path => $path );
}

sub new ($class, %conf) {
    for my $req ( qw(url db), ( defined $conf{session} ? () : 'login' ) ) {
        Odoo::Error->throw( kind => 'config', message => "config missing $req" )
            if !defined $conf{$req} || $conf{$req} eq '';
    }
    Odoo::Error->throw( kind => q(config), message => "approval must be required or none, not '$conf{approval}'" )
        if defined $conf{approval} && $conf{approval} !~ /^(?:required|none)\z/;
    Odoo::Error->throw( kind => q(config), message => "plan_ttl must be a whole number of seconds, not '$conf{plan_ttl}'" )
        if defined $conf{plan_ttl} && $conf{plan_ttl} !~ /^[1-9]\d*\z/;
    return bless {%conf}, $class;
}

sub get ($self, $key) { $self->{$key} }

sub path ($self) { $self->{_path} }

sub allow_writes ($self) { ( $self->{allow_writes} // '' ) eq '1' }

sub approval ($self) { $self->{approval} // q(required) }

sub plan_ttl ($self) { $self->{plan_ttl} // 86400 }

# Stable identity of the target, for binding plans to an instance.
sub instance ($self) {
    return { url => $self->{url} =~ s{/+\z}{}r, db => $self->{db}, login => $self->{login} };
}

1;

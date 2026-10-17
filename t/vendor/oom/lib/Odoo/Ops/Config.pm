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
    password_file         for the password strategy: a file holding the login's
                          password alone, owner-only; the context opens a web
                          session with it (needed by core.report's render)
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
                          self: the same gate, and a workflow tool (oom-mailshot)
                          may record the approval of the plan it has just
                          planned, as the actor, so one call plans, approves
                          and applies; oom-ops itself treats it as required;
                          none: apply needs no approval (tests, trusted batch)
    mailcatcher           optional URL of a mail catcher's JSON API (Mailpit,
                          http://127.0.0.1:8025) that oom-mailshot reads to
                          show a test mail; a development aid, never a target
    plan_ttl              seconds a plan stays applicable, default 86400
    record_reads          1 (default): oom-ops run of a read leaves a run folder with
                          its report.json; 0: it prints and leaves nothing, as
                          --check does (a shared instance, an agent that reads a lot)
    audit_log             a path: one JSON-lines file, appended to by every command run with this
                          config (created 0600; refused at load when other users can write it)
    audit_syslog          1: send each audit line to syslog as well (default 0)
    audit_syslog_facility user (default), auth, authpriv, daemon, local0 .. local7
    audit_level           core (default): one line per event; transaction: and one per RPC call
    audit_required        1: a command does not start unless every destination can be written,
                          and stops before the next call to Odoo if a line cannot be written

An unknown key is refused, so a typo in C<allow_writes> can never
silently read as "writes off" or "writes on".

Values are never echoed by this module; C<api_key> inline is refused
outright - keys live in their own file.

=cut

my %KNOWN = map { $_ => 1 } qw(
    url db login credential api_key_file password_file transport timeout
    max_response_bytes lang tz actor runs_dir profile_dir
    profile_series allow_writes name ssl_ca_file ssl_verify session
    approval plan_ttl mailcatcher record_reads
    audit_log audit_syslog audit_syslog_facility audit_level audit_required
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
    Odoo::Error->throw( kind => q(config), message => "approval must be required, self or none, not '$conf{approval}'" )
        if defined $conf{approval} && $conf{approval} !~ /^(?:required|self|none)\z/;
    Odoo::Error->throw( kind => q(config), message => "mailcatcher must be an http:// or https:// URL, not '$conf{mailcatcher}'" )
        if defined $conf{mailcatcher} && $conf{mailcatcher} !~ m{^https?://[^\s/]+(?::\d+)?(?:/\S*)?\z};
    Odoo::Error->throw( kind => q(config), message => "plan_ttl must be a whole number of seconds, not '$conf{plan_ttl}'" )
        if defined $conf{plan_ttl} && $conf{plan_ttl} !~ /^[1-9]\d*\z/;
    Odoo::Error->throw( kind => q(config), message => "record_reads must be 0 or 1, not '$conf{record_reads}'" )
        if defined $conf{record_reads} && $conf{record_reads} !~ /^[01]\z/;
    Odoo::Error->throw( kind => q(config), message => "audit_syslog must be 0 or 1, not '$conf{audit_syslog}'" )
        if defined $conf{audit_syslog} && $conf{audit_syslog} !~ /^[01]\z/;
    Odoo::Error->throw( kind => q(config), message => "audit_required must be 0 or 1, not '$conf{audit_required}'" )
        if defined $conf{audit_required} && $conf{audit_required} !~ /^[01]\z/;
    Odoo::Error->throw( kind => q(config), message => "audit_level must be core or transaction, not '$conf{audit_level}'" )
        if defined $conf{audit_level} && $conf{audit_level} !~ /^(?:core|transaction)\z/;
    if ( defined $conf{audit_syslog_facility} ) {
        require Odoo::Ops::Trail;
        my @ok = Odoo::Ops::Trail->facilities;
        Odoo::Error->throw( kind => q(config), message => "audit_syslog_facility must be one of " . join( ', ', @ok ) . ", not '$conf{audit_syslog_facility}'" )
            if !grep { $_ eq $conf{audit_syslog_facility} } @ok;
    }
    Odoo::Error->throw( kind => q(config), message => 'audit_log must be a path, not empty' )
        if defined $conf{audit_log} && $conf{audit_log} eq '';
    if ( defined $conf{audit_log} && -e $conf{audit_log} ) {
        my @st = stat $conf{audit_log};
        Odoo::Error->throw( kind => q(config),
            message => sprintf( 'audit_log %s is mode %04o; other users can write it (chmod 600)', $conf{audit_log}, $st[2] & 07777 ) )
            if $st[2] & 022;
    }
    Odoo::Error->throw( kind => q(config), message => 'audit_required needs audit_log or audit_syslog = 1' )
        if ( $conf{audit_required} // 0 ) eq '1' && !defined $conf{audit_log} && ( $conf{audit_syslog} // 0 ) ne '1';
    return bless {%conf}, $class;
}

# One sentence, said by doctor and by oom-mailshot test, so an agent meets the
# same words wherever the missing key shows (second try-out, item 1).
sub no_catcher_sentence ($class) {
    return 'no mailcatcher key: oom-mailshot test shows mailing.preview\'s rendering instead; on a development cluster add `mailcatcher = http://127.0.0.1:8025`';
}

sub get ($self, $key) { $self->{$key} }

sub path ($self) { $self->{_path} }

sub allow_writes ($self) { ( $self->{allow_writes} // '' ) eq '1' }

sub approval ($self) { $self->{approval} // q(required) }

sub plan_ttl ($self) { $self->{plan_ttl} // 86400 }

# whether a read leaves a run folder; a write always does
sub record_reads ($self) { ( $self->{record_reads} // 1 ) eq '1' }

# the audit a config asks for: a file, syslog, or both
sub audit_enabled  ($self) { defined $self->{audit_log} || ( $self->{audit_syslog} // 0 ) eq '1' }
sub audit_syslog   ($self) { ( $self->{audit_syslog} // 0 ) eq '1' }
sub audit_required ($self) { ( $self->{audit_required} // 0 ) eq '1' }
sub audit_level    ($self) { $self->{audit_level} // 'core' }
sub audit_facility ($self) { $self->{audit_syslog_facility} // 'user' }

# Stable identity of the target, for binding plans to an instance.
sub instance ($self) {
    return { url => $self->{url} =~ s{/+\z}{}r, db => $self->{db}, login => $self->{login} };
}

1;

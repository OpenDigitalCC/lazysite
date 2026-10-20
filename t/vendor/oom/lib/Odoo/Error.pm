package Odoo::Error;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use overload
    '""'     => sub { $_[0]->{message} },
    fallback => 1;

=head1 NAME

Odoo::Error - exception object for the Odoo mapper

=head1 DESCRIPTION

Every die from Odoo::Client and the transports is an Odoo::Error, so
callers can distinguish a server fault (bad domain, access denied)
from a transport problem (connection refused, proxy page, HTTP 502).
Only transport errors are retried.

Kinds: C<fault> (the server answered with an error), C<transport>
(the request never got a usable answer), C<refused> (a policy said no
before or instead of an answer: a redirect, an oversized response, a
call outside an operation's declared scope - never retried), C<config>
and C<usage> (caller mistakes, raised before any network traffic).

=head2 fix

An optional one-line statement of what to do about it (C<fix =E<gt> 'oom-ops
list'>), beside C<kind>, C<code> and C<message>. A refusal that a person or a
program can act on carries one, so the caller never has to parse the message
to learn the next step; C<oom-ops> prints it on a line of its own and, with
C<--json>, in the error object.

=head2 Fault classes

A fault carries C<fault_class>, the server's own exception name
(C<odoo.exceptions.AccessError> and so on) where the wire gave one:
JSON-RPC sends it as C<error.data.name>, XML-RPC only inside the
traceback text, from which it is recovered. C<fault_category> folds
it into the distinctions an application acts on:

    access      AccessError   - the user lacks rights; do not retry
    credential  AccessDenied  - login/key refused (also 'oom.AuthRefused': the
                login call answered false, which is all Odoo says of an
                archived login, a deleted or expired key, a wrong secret)
    session     SessionExpiredException - re-authenticate
    second-factor-required  the login and password were right and the user has
                two-factor on: the sign-in is pending until the authenticator code
                is given (fault_class 'oom.SecondFactorRequired'; the fix line says
                to complete the sign-in with complete_totp). A wrong password stays
                'credential'
    second-factor  Odoo refused the authenticator code (fault_class
                'oom.SecondFactor', Odoo's own words); the pending sign-in stays open
    validation  ValidationError, UserError - the data was refused
    missing     MissingError  - the record is gone
    lazysite    a lazysite manager API answered ok:false (fault_class
                'lazysite', raised by Odoo::Ops::Source::Lazysite)
    other       anything else, or no class on the wire

=cut

my %CATEGORY = (
    'odoo.exceptions.AccessError'          => 'access',
    'odoo.exceptions.AccessDenied'         => 'credential',
    'odoo.http.SessionExpiredException'    => 'session',
    'odoo.exceptions.ValidationError'      => 'validation',
    'odoo.exceptions.UserError'            => 'validation',
    'odoo.exceptions.MissingError'         => 'missing',
    'lazysite'                             => 'lazysite',
    'oom.SecondFactorRequired'             => 'second-factor-required',
    'oom.SecondFactor'                     => 'second-factor',
    'oom.AuthRefused'                      => 'credential',
);

sub new ($class, %args) {
    return bless {
        kind        => $args{kind}    // 'error',
        message     => $args{message} // 'unknown error',
        code        => $args{code},
        fix         => $args{fix},
        fault_class => $args{fault_class},
        sent        => $args{sent},
        write       => $args{write},
    }, $class;
}

sub throw ($class, %args) { die $class->new(%args) }

sub kind        ($self) { $self->{kind} }
sub message     ($self) { $self->{message} }
sub code        ($self) { $self->{code} }
sub fault_class ($self) { $self->{fault_class} }

=head2 sent, write, unanswered_write

A transport error says whether the request left. C<sent> is true when it may have
reached Odoo (a read timeout, a connection closed or reset after the request was
written, an HTTP error or an unreadable answer from a proxy), false when it did not
(connect refused, DNS, TLS, a failure while writing the request), and undef when
the transport does not know. C<write> is true when the call was one that changes
Odoo. C<unanswered_write> is true when both hold: Odoo may have made the change and
no answer came, which is what L<Odoo::Ops::Runner> records as C<unknown>.

=cut

sub sent             ($self) { $self->{sent} }
sub write            ($self) { $self->{write} }
sub unanswered_write ($self) { $self->{kind} eq 'transport' && $self->{sent} && $self->{write} ? 1 : 0 }

=head2 fix, and the fix of an access fault

C<fix> is the line a caller set, or, for an access fault
(C<fault_category> C<access>) that has none, the one worded here for every
pack: which model this user may not touch and what for, the groups Odoo's
text names, what was being read when the guard knew it (C<reading>, set by
L<Odoo::Ops::Guard>: C<model.method fields a,b,c>), and what to do. So an
access fault never reads C<fix: null>.

=cut

sub fix ($self) {
    return $self->{fix} if defined $self->{fix};
    return $self->credential_fix if $self->is_invalid_credential;
    return 'Odoo found no row for an id it was sent: the id is not a record of that model, is gone, or was sent as text; ids are positive integers' if ( $self->{message} // '' ) =~ /Database fetch misses ids/;
    return undef if !$self->is_access_denied;
    return $self->access_fix;
}

=head2 credential_fix

The C<fix> of a credential fault (a refused login, key or password) that has
none. Odoo gives one answer for an archived login, a key that was deleted or
has expired, and a wrong secret. The line says so and names what reads the cause
with an administrator config: C<oom-accounts probe> reads whether the login is
archived and whether the key is past its date. Nothing is guessed.

=cut

sub credential_fix ($self) {
    return 'Odoo gives one answer for an archived login, a deleted or expired key and a wrong secret; '
        . 'with an administrator config, oom-accounts probe reads whether the login is archived or the key expired';
}

# The model Odoo's access text names ("... (account.move) records"), or undef.
sub access_model ($self) {
    my ($model) = ( $self->{message} // '' ) =~ /\(([a-z][\w.]*\.[\w.]+)\)/;
    return $model;
}

# The groups Odoo lists as allowed, once each, in its order.
sub access_groups ($self) {
    my %seen;
    return grep { !$seen{$_}++ } ( $self->{message} // '' ) =~ /^\s*-\s*(\S[^\n]*?)\s*$/mg;
}

# What was refused: read, create, write or delete (Odoo says access, create, modify, delete).
sub access_verb ($self) {
    my ($v) = ( $self->{message} // '' ) =~ /not allowed to (access|create|modify|delete)\b/;
    return { access => 'read', modify => 'write' }->{ $v // 'access' } // $v;
}

=head2 reading

What the call was when the guard saw this fault (C<mailing.mailing fields
subject,state,total>), or undef.

=cut

sub reading ($self) { $self->{reading} }

sub access_fix ($self) {
    my $model  = $self->access_model;
    my @groups = $self->access_groups;
    my $what   = defined $model ? $model : 'a model this call reaches';
    my $needs  = @groups ? ' (needs ' . join( ' or ', @groups[ 0 .. ( $#groups < 3 ? $#groups : 3 ) ] ) . ( @groups > 4 ? ' or others' : '' ) . ')' : '';
    return 'this user may not ' . $self->access_verb . " $what$needs"
        . ( defined $self->{reading} ? "; the call was $self->{reading}" : '' )
        . '; ask the administrator for the group, or narrow the call to records and fields that do not reach it';
}

sub is_fault     ($self) { $self->{kind} eq 'fault' }
sub is_transport ($self) { $self->{kind} eq 'transport' }
sub is_refused   ($self) { $self->{kind} eq 'refused' }

# Odoo words a fetch that found no row for an id it was sent as an access error
# ("Database fetch misses ids"); it says nothing about rights, so it is not
# one here.
sub fault_category ($self) {
    return undef if !$self->is_fault;
    return 'missing' if ( $self->{message} // '' ) =~ /Database fetch misses ids/;
    return $CATEGORY{ $self->{fault_class} // '' } // 'other';
}

sub is_access_denied       ($self) { ( $self->fault_category // '' ) eq 'access' }
sub is_invalid_credential  ($self) { ( $self->fault_category // '' ) eq 'credential' }
sub is_session_expired     ($self) { ( $self->fault_category // '' ) eq 'session' }
sub is_validation          ($self) { ( $self->fault_category // '' ) eq 'validation' }
sub is_missing             ($self) { ( $self->fault_category // '' ) eq 'missing' }
sub is_no_session          ($self) { ( $self->fault_category // '' ) eq 'second-factor-required' }
sub is_wrong_code          ($self) { ( $self->fault_category // '' ) eq 'second-factor' }

=head2 is_no_session

True for the fault of category C<second-factor-required>: the login and
password were right, the user has two-factor authentication and the
sign-in waits for the authenticator code (L<Odoo::Transport::Session>
C<complete_totp>). A refused password is C<credential> and is not this. The wording of the message is
free to change: test this, not the text.

=cut

=head2 is_wrong_code

True for the fault of category C<second-factor>: Odoo refused the
authenticator code.

=cut

=head2 fault_class_from_text($text)

Class function: the last dotted Odoo exception name in a traceback
(C<odoo.exceptions.AccessError: ...>), or undef. The XML-RPC wire
carries the class only this way.

=cut

sub fault_class_from_text ($text) {
    return undef if !defined $text;
    my @found = $text =~ /\b(odoo(?:\.\w+)*\.[A-Z]\w*)\b/g;
    return @found ? $found[-1] : undef;
}

1;

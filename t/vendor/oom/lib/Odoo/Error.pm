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

=head2 Fault classes

A fault carries C<fault_class>, the server's own exception name
(C<odoo.exceptions.AccessError> and so on) where the wire gave one:
JSON-RPC sends it as C<error.data.name>, XML-RPC only inside the
traceback text, from which it is recovered. C<fault_category> folds
it into the distinctions an application acts on:

    access      AccessError   - the user lacks rights; do not retry
    credential  AccessDenied  - login/key refused
    session     SessionExpiredException - re-authenticate
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
);

sub new ($class, %args) {
    return bless {
        kind        => $args{kind}    // 'error',
        message     => $args{message} // 'unknown error',
        code        => $args{code},
        fault_class => $args{fault_class},
    }, $class;
}

sub throw ($class, %args) { die $class->new(%args) }

sub kind        ($self) { $self->{kind} }
sub message     ($self) { $self->{message} }
sub code        ($self) { $self->{code} }
sub fault_class ($self) { $self->{fault_class} }

sub is_fault     ($self) { $self->{kind} eq 'fault' }
sub is_transport ($self) { $self->{kind} eq 'transport' }
sub is_refused   ($self) { $self->{kind} eq 'refused' }

sub fault_category ($self) {
    return undef if !$self->is_fault;
    return $CATEGORY{ $self->{fault_class} // '' } // 'other';
}

sub is_access_denied       ($self) { ( $self->fault_category // '' ) eq 'access' }
sub is_invalid_credential  ($self) { ( $self->fault_category // '' ) eq 'credential' }
sub is_session_expired     ($self) { ( $self->fault_category // '' ) eq 'session' }
sub is_validation          ($self) { ( $self->fault_category // '' ) eq 'validation' }
sub is_missing             ($self) { ( $self->fault_category // '' ) eq 'missing' }

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

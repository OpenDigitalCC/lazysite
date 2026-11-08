package Lazysite::Odoo::Hooks;

# SM1369 X3 (ruling 55): WHAT THE ODOO EXTENSION HOOKS INTO CORE.
#
# Core names no extension (t/lint/321). What a page reads from Odoo (`odoo:`,
# `odoo-identity:`) and what a form or the timer runs (a handler of type odoo)
# used to be lines in lazysite-processor/sources.pm, Lazysite::Validate and
# Lazysite::Handlers that called this extension by name. They are declared here
# instead - extensions/odoo.pl, `owns.hooks` - and core calls these functions
# through the one loader (Lazysite::Extensions::Hooks::call_hook), only while
# the extension is on, only from this payload lib.
#
# THE RULES ARE THE SAME ONES, moved: a render never writes, a visitor's binding
# is not a page's, a session binding runs for nobody but the person, a form and
# the timer have no visitor and nobody to confirm. What core keeps is the part
# that belongs to a shared render and a shared catalogue - the per-viewer cache
# rule, the inert value, the cap gate, the origin gate, the schema check - so
# this file decides what Odoo does and never what the engine guarantees.
#
# Each function answers what its hook's contract says (Lazysite::Handlers,
# lazysite-processor/sources.pm, Lazysite::Validate), and what it reads from the
# site it finds through the docroot core hands it.

use strict;
use warnings;
use Lazysite::Util          ();
use Lazysite::Odoo          ();
use Lazysite::Odoo::Binding ();

# --- H-2: page sources -------------------------------------------------------

# `odoo:<binding>` - a public read's report for a page. Answers ( $report ) or
# ( undef, $why, %detail ); core makes the report inert and logs a refusal.
sub source_binding {
    my ( $id, $ctx ) = @_;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $ctx->{docroot};
    my ( $b, $why ) = Lazysite::Odoo::find_binding($id);
    return ( undef, "names no usable binding: $why" ) unless $b;
    return ( undef, 'refused - the binding works on a visitor\'s key, and a page render is shared; '
            . 'read it through the Odoo endpoint instead', binding => $id )
        if length $b->{visitor_param};
    return ( undef, 'refused - the binding is told whether the call came from inside an address profile, ' # SM1280
            . 'and a page render is shared and cached; read it through the Odoo endpoint instead', binding => $id )
        if length( $b->{address_param} // '' );
    return ( undef, "refused - the binding '$id' answers a download (answer: download); the document " # SM1225
            . 'would be put in the page as base64. Link to the Odoo endpoint instead', binding => $id )
        if ( $b->{answer} // '' ) eq 'download';
    return ( undef, 'refused - the binding runs as a person signed in to Odoo, and a page render is shared '
            . 'and cached; what one person may see is never put in it', binding => $id )
        if ( $b->{credential} // '' ) eq 'session';
    my $w = Lazysite::Odoo::writes_of($b);
    return ( undef, 'refused - a render never runs an operation that writes'
            . ( defined $w ? '' : ' (and this one could not be asked whether it does)' ), binding => $id )
        unless defined $w && !$w;
    my $r = Lazysite::Odoo::call( $b, {}, mode => 'public', ip => ( $ctx->{address} // '' ),
        host => ( $ctx->{host} // '' ) ); # E-Q1: a domain's binding renders only on its own host
    return ( undef, ( $r->{error} // '' ), binding => $id, kind => ( $r->{kind} // '' ) ) unless $r->{ok};
    require Lazysite::Odoo::Fields;
    return ( Lazysite::Odoo::Fields::page_report( $r->{report} ) );
}

# `odoo-identity:` - who the viewer is in Odoo, for the page to PRESENT (SM747
# C: OI1, OI4, OI5). Declared per_viewer, so core hands it the request's cookie
# header and never caches the page for another viewer. An empty mapping is what
# a page renders for a viewer who has not signed in, whose cookie has ended, or
# whose cookie does not verify: a tampered one is no identity.
sub source_identity {
    my ( $spec, $ctx ) = @_;
    require Lazysite::Odoo::Identity;
    require Lazysite::Odoo::Visitor;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT          = $ctx->{docroot};
    local $Lazysite::Odoo::Visitor::DOCROOT = $ctx->{docroot};
    my $id = Lazysite::Odoo::Identity::identity_from_cookie( $ctx->{cookie} // '', ttl => Lazysite::Odoo::identity_ttl() );
    return ( $id || {} );
}

# At a page's save (Lazysite::Validate): a binding that answers a download
# (SM1225) would be the page's base64, so the render refuses it and the save
# says so first. Answers a list of { kind, message }.
sub check_binding {
    my ( $id, $docroot ) = @_;
    return [] unless defined $id && $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $docroot;
    my ($b) = Lazysite::Odoo::find_binding($id);
    return [] unless ref $b eq 'HASH' && ( $b->{answer} // '' ) eq 'download';
    return [ { kind => 'odoo-binding-is-a-download',
            message => "this page binds odoo:$id, and '$id' answers a download (answer: download): "
                . 'its document would be put in the page as base64, so a render refuses it. '
                . 'Link to the Odoo endpoint instead (?binding=' . $id . ').' } ];
}

# --- H-3: the handler type `odoo` ---------------------------------------------
#
# SM747 CU: AN ODOO BINDING - a named OOM operation, run as the site's
# connection user (the extension's config), with what a request may set and who
# may cause it. Configuring one is manage_odoo's (OM3, ruling 71; ruling 178 moved
# the type's cap from manage_connectors with X4, in 0.16.9): it is authority over
# where site data goes. A group holding manage_connectors is topped up with it
# (capability_info's top_up_from), by the users tool and by the upgrade.

# At save: the shape, in the one parser the call uses - so what is saved is what
# will run. Whether the operation exists is handler_save's.
sub handler_parse {
    my ($h) = @_;
    my ( $b, $why, $field ) = Lazysite::Odoo::Binding::parse($h);
    return $b ? { ok => 1 } : { ok => 0, why => $why, field => $field };
}

# At save, after the shape: the binding against the operation's OWN declaration,
# when the registry can be read. OOM absent or the connection unconfigured is NOT
# a refusal - unvalidated is not invalid - and the call checks again.
sub handler_save {
    my ( $h, $ctx ) = @_;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $ctx->{docroot};
    my $problem = eval {
        my ($have) = Lazysite::Odoo::oom_check();
        my ($conn) = $have ? Lazysite::Odoo::connection() : ();
        return '' unless $conn;
        my ($b) = Lazysite::Odoo::Binding::parse($h);
        return '' unless $b;    # the shape was refused by handler_parse already
        my ( $class, $why ) = Lazysite::Odoo::operation_class( $conn, $b->{operation} );
        return "operation: $why" unless $class;
        my $w = Lazysite::Odoo::Binding::check_against( $b, $class );
        return "params: $w" if length $w;

        # SM1180: what the request path needs of the operation, kept beside the
        # binding and stamped, so a call that oomd answers loads no OOM.
        Lazysite::Odoo::store_decl( $b->{id}, $class, $b->{operation}, $conn );
        return '';
    };
    return { ok => 0, why => $problem } if defined $problem && length $problem;
    return { ok => 1 };
}

# At delete: its stored operation declaration goes with it (SM1180).
sub handler_delete {
    my ( $h, $ctx ) = @_;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $ctx->{docroot};
    my $ok = eval { Lazysite::Odoo::forget_decl( $h->{id} ); 1 };
    return $ok ? { ok => 1 } : { ok => 0, why => ( $@ =~ s/\s+\z//r ) };
}

# A form or the timer runs an Odoo binding. A form is PUBLIC - that path has no
# verified actor (SM402) - and the timer is SCHEDULED, exactly as a connector is
# told; the binding's modes decide whether either may.
#
# NEITHER HAS A VISITOR OR ANYBODY TO CONFIRM. A binding that works on a
# visitor's key belongs on a page (the Odoo endpoint mints and checks the key),
# and a write that waits for a confirm would wait for ever - so both are
# refused here by name rather than planned into a void.
sub handler_deliver {
    my ( $h, $fields, $ctx ) = @_;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $ctx->{docroot};
    my ( $b, $why ) = Lazysite::Odoo::Binding::parse($h);
    return { ok => 0, why => "the Odoo binding cannot be used: $why" } unless $b;
    return { ok => 0, why => "the Odoo binding '$b->{id}' works on a visitor's key, which only "
            . 'the Odoo page endpoint carries - bind it on a page, not a form or the schedule' }
        if length $b->{visitor_param};
    return { ok => 0, why => "the Odoo binding '$b->{id}' runs as a person signed in to Odoo, which "
            . 'only the Odoo page endpoint carries - not a form or the schedule' }
        if ( $b->{credential} // '' ) eq 'session';
    return { ok => 0, why => "the Odoo binding '$b->{id}' waits for a confirm, and a form or the "
            . 'schedule has nobody to give one - set apply: immediate on it (Q1)' }
        if $b->{apply} ne 'immediate' && _writes($b);
    my $timer = ( $ctx->{origin} // '' ) eq 'timer';
    my $r     = Lazysite::Odoo::call( $b, {%$fields},
        mode  => ( $timer ? 'scheduled' : 'public' ),
        actor => $ctx->{actor} // '',
        ip    => $ctx->{ip}    // '',
        # E-Q1: a form is a request on a host, and a domain's binding runs only
        # there; the timer has no host and runs what the operator scheduled.
        ( $timer ? () : ( host => $ctx->{host} // '' ) ) );
    return { ok => 1 } if $r->{ok};

    # SM1148 (OOM Lab L-3): APPLIED WITH A WARNING IS DELIVERED. OOM reports an
    # apply as not ok when an invariant on the result failed after the change was
    # made (its O-4: the record WAS made). That reached the form as a failure, so
    # it sent the visitor to outcome=undelivered, they sent it again, and Odoo
    # held a duplicate. It is delivered, with the warning in `note` - which the
    # delivery's audit line carries as its detail and the event log as a WARN -
    # and the engine's call record already holds the kind. Only a result in which
    # every change that was attempted is done counts: a change that failed, or
    # was never attempted, is not a delivery and keeps its refusal.
    if ( ( $r->{kind} // '' ) eq 'apply-incomplete' && $r->{applied} ) {
        my $c = ( ref $r->{result} eq 'HASH' && ref $r->{result}{counts} eq 'HASH' ) ? $r->{result}{counts} : {};
        return { ok => 1,
            note => 'the change was applied in Odoo, and its checks afterwards reported apply-incomplete - see the Odoo call record' }
            if ( $c->{done} // 0 ) > 0 && !( $c->{failed} // 0 ) && !( $c->{unknown} // 0 ) && !( $c->{not_attempted} // 0 );
    }
    return { ok => 0, why => 'the Odoo operation did not complete: ' . ( $r->{error} // $r->{kind} // 'failed' ) };
}

# Whether the binding's operation writes - asked of OOM's registry, and treated
# as a WRITE when it cannot be asked, so the refusal above errs closed.
sub _writes {
    my ($b) = @_;
    my $w = eval { Lazysite::Odoo::writes_of($b) }; # SM1180: the stored declaration with the daemon on
    return defined $w ? $w : 1;
}

1;

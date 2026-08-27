#!/usr/bin/perl

# DP-3: the data endpoint - a page's own JavaScript reading a table.
#
# WHY THIS EXISTS SEPARATELY FROM THE CONTROL API. The control API is the
# sysop's and the agent's door: it is capability-gated, CSRF-gated on the
# cookie path, and every action is audited. A rendered PAGE asking for rows is
# a different question with a different answer - it is a visitor, usually
# anonymous.
#
# READS ARE GATED (SM476), and this endpoint used to be the reason they were
# not. A page bound to a table inherits the PAGE's gate; this endpoint is
# reached by its own URL and inherited nothing, so it was a second door to the
# same rows with no lock on it. A table now has to be PUBLISHED before an
# anonymous visitor sees anything, and an acls.json read list narrows it
# further. The decision lives in Lazysite::Data::Access, and read_rows will not
# answer at all without being told who is asking.
#
# IT VALIDATES ITS OWN IDENTITY, and that is the whole reason SM411 exists.
#
# The front door routes lazysite-*.pl, but only the processor and manager-api
# are WRAPPED - so a direct-CGI plugin sees X-Remote-User exactly as the client
# sent it. Trusting it here would be SM402's defect reintroduced by
# specification: a header anybody can set, believed. So this verifies the
# session cookie itself, through the same module lazysite-auth.pl mints with,
# and treats an unverified request as ANONYMOUS rather than as whoever it
# claimed to be.
#
# WRITES ARE AUTHENTICATED, ALWAYS, AND `writable=` DOES NOT CHANGE THAT.
#
# The plan called this half "inline writable= writes", and the obvious reading -
# a page declaring a table writable makes it writable - is the one thing this
# must not do. The endpoint is reached by a URL; it cannot see which page
# called it, so a marker in a page's front matter could never gate anything. A
# page saying `writable` would be a promise the enforcement layer never hears.
#
# So the rule is stated where it can be enforced: a write needs a VERIFIED
# session whose account holds manage_data, and a CSRF token. `writable=` on a
# binding is a note to the page's own JavaScript about whether to offer editing
# controls - presentation, and deliberately not a permission.
#
# ANONYMOUS WRITES ARE WHAT FORMS ARE FOR. A public visitor submitting data is
# a solved problem here, with rate limits, spam controls and a handler that
# vets what it accepts. Letting a data binding take anonymous writes would
# rebuild that surface without any of it, so it does not.

use strict;
use warnings;
use JSON::PP ();

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

exit main() if !caller;

sub reply {
    my ( $status, $data ) = @_;
    my $body = JSON::PP->new->canonical->encode($data);
    print "Status: $status\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n";

    # Never cached by anything in front. What a visitor may see depends on who
    # they are, so a shared cache holding one answer would hand it to the next
    # person.
    print "Cache-Control: no-store\r\n";
    print "Content-Length: " . length($body) . "\r\n\r\n";
    print $body;
    return 0;
}

sub main {
    my $docroot = $ENV{DOCUMENT_ROOT} // '';
    return reply( 500, { ok => 0, error => 'no document root' } )
        unless length $docroot && -d $docroot;

    my $method = $ENV{REQUEST_METHOD} // 'GET';
    return reply( 405,
        { ok => 0, error => 'this endpoint takes GET to read and POST to write' } )
        unless $method eq 'GET' || $method eq 'POST';

    # SM557: the package is require'd at runtime, so this file mentions the
    # variable once by design - t/lint/04 refuses the 'used only once' warning.
    no warnings 'once';
    require Lazysite::Manager::Plugins;
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;
    return reply( 403,
        { ok => 0,
            error => 'The data plugin is disabled. A sysop can enable it '
                . 'on the Plugin Manager page.' } )
        unless Lazysite::Manager::Plugins::plugin_enabled('plugins/data.pl');

    my %q;
    for my $pair ( split /&/, ( $ENV{QUERY_STRING} // '' ) ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && length $k;
        for ( $k, $v ) {
            next unless defined;
            tr/+/ /;
            s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        }
        $q{$k} = $v // '';
    }

    # A CSRF request names no table, so the requirement comes after it.
    my $table = $q{table} // '';
    return reply( 400, { ok => 0, error => 'table required' } )
        unless length $table || ( $q{csrf} // '' ) eq '1';

    no warnings 'once';    # SM557
                           # THE IDENTITY, verified here rather than taken from a header.
    require Lazysite::Auth::Session;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$docroot/lazysite";
    # IT RETURNS A SESSION, NOT A NAME. verify_session_cookie answers
    # ( { user, sid, groups }, undef ) on success and ( undef, $why ) on
    # failure - so treating the first value as a username put the string
    # "HASH(0x...)" into the identity below, which is the value the ACL layer
    # then reads. It failed closed here only by accident.
    my ($session) = Lazysite::Auth::Session::verify_session_cookie();
    my $user = ( ref $session eq 'HASH' ) ? ( $session->{user} // '' ) : '';

    # DISABLED AND REVOKED ARE ALREADY DECIDED, and re-deciding them here was
    # wrong twice: verify_session_cookie returns undef with 'disabled' or
    # 'revoked' for both, so the account never reaches this line - and the
    # re-check called session_revoked() with NO ARGUMENTS, which reads the
    # revocation list and asks it about an undefined user. A second
    # implementation of a decision already made cannot agree with the first;
    # it can only disagree eventually.

    # The requester goes in the environment, where the rest of the stack reads
    # it from. Set from the VERIFIED identity, never from what arrived:
    # anything the client could have sent is cleared first.
    #
    # THIS DOES NOT GATE THE READ. Nothing consults a table ACL, because tables
    # have none - see the header. It is set so that anything downstream which
    # does read an identity sees the true one rather than a forged header.
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_/ } keys %ENV;
    if ( length $user ) {
        $ENV{HTTP_X_REMOTE_USER} = $user;

        # The groups the session already resolved, rather than resolving them
        # again: two answers to "which groups is this account in" is the
        # disagreement SM288 exists to remove.
        my $groups = $session->{groups};
        $groups = join( ',', @{$groups} ) if ref $groups eq 'ARRAY';
        $ENV{HTTP_X_REMOTE_GROUPS} = $groups
            if defined $groups && length $groups;
    }

    # Split once, from the value the block above just set - the writable_by
    # narrowing and the read binding both asked the environment the same
    # question and got the same answer.
    my @groups = split /\s*,\s*/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' );

    # A token for this session, so a page's JavaScript can write. Minted only
    # for a verified account: an anonymous caller has nothing to protect and
    # gets nothing to replay.
    if ( ( $q{csrf} // '' ) eq '1' ) {
        return reply( 403, { ok => 0, error => 'not signed in' } )
            unless length $user;
        return reply( 200,
            { ok => 1,
                token => Lazysite::Auth::Session::generate_csrf_token($user) } );
    }

    require Lazysite::Data::Tables;

    # --- writes ------------------------------------------------------------
    if ( $method eq 'POST' ) {
        return reply( 403,
            { ok => 0, kind => 'anonymous',
                error => 'writing needs a signed-in account. A public form is '
                    . 'the way to collect data from visitors.' } )
            unless length $user;

        # CSRF. The cookie travels automatically, so without this any page
        # anywhere could make a signed-in reader's browser write to this site.
        my $sent = $ENV{HTTP_X_CSRF_TOKEN} // '';
        return reply( 403,
            { ok => 0, kind => 'csrf',
                error => 'missing or stale CSRF token - fetch a fresh one from '
                    . '?csrf=1 and retry' } )
            unless Lazysite::Auth::Session::verify_csrf_token( $sent, $user );

        no warnings 'once';    # SM557
        require Lazysite::Manager::Data;
        local $Lazysite::Manager::Data::DOCROOT = $docroot;

        # THE CAPABILITY, resolved for the verified account. `writable=` on a
        # page cannot reach here and does not try; this is the only gate.
        require Lazysite::Auth::Settings;
        local $Lazysite::Auth::Settings::AUTH_DIR = "$docroot/lazysite/auth";
        my $caps = Lazysite::Auth::Settings::caps_for($user) || {};
        return reply( 403,
            { ok => 0, kind => 'forbidden',
                error => 'this account does not hold manage_data' } )
            unless $caps->{manage_data};

        # `writable_by` NARROWS, and only narrows. The descriptor has carried
        # it since DP-1 - validated, exported, named in the MCP tool's own
        # documentation - and NOTHING HAS EVER ENFORCED IT. A sysop writing
        # `writable_by: [editors]` was given a promise no code kept, which is
        # worse than the key not existing: they would have stopped looking for
        # another way to say it.
        #
        # NARROWING ONLY, deliberately. Widening - letting a listed group write
        # WITHOUT manage_data - would make a YAML file a grant of capability,
        # and that file can be written over MCP by an agent holding
        # manage_data. An agent could then hand write access to a group it
        # chose. So the capability is still required and the list only takes
        # access away.
        #
        # An EMPTY list means "no extra narrowing", which is what every
        # existing descriptor has.
        my $desc = Lazysite::Data::Tables::load_table( $docroot, $table );
        my $wb
            = ( $desc->{ok} && ref $desc->{writable_by} eq 'ARRAY' )
            ? $desc->{writable_by}
            : [];
        if ( @{$wb} ) {
            my %in = map { $_ => 1 } @groups;
            unless ( grep { $in{$_} } @{$wb} ) {
                return reply( 403,
                    { ok => 0, kind => 'forbidden',
                        error => "table '$table' is writable by: "
                            . join( ', ', @{$wb} )
                            . ' - this account is in none of them' } );
            }
        }

        my $len = $ENV{CONTENT_LENGTH} || 0;
        return reply( 413, { ok => 0, error => 'body too large' } )
            if $len > 256 * 1024;
        my $body = '';
        read( STDIN, $body, $len ) if $len;
        my $req = eval { JSON::PP->new->decode($body) } // {};
        return reply( 400, { ok => 0, error => 'body must be a JSON object' } )
            unless ref $req eq 'HASH';

        my $r
            = $req->{delete}
            ? Lazysite::Manager::Data::action_data_row_delete( $table,
            $req->{key} )
            : Lazysite::Manager::Data::action_data_row_save( $table,
            $req->{key}, $req->{row} );
        return reply( $r->{ok} ? 200 : 400, $r );
    }

    # THE SAME PARSER THE PAGE BINDING USES, and it has to be. This built its
    # own %opt and handed it to read_rows, so the two doors into one table
    # applied DIFFERENT RULES - a grammar restriction on the page, none here.
    # That is the shape of the SM476 defect exactly, and it would have grown
    # back every time the grammar changed on one side.
    #
    # The binding is assembled from the query string, so every part is checked
    # against a strict pattern FIRST. A value carrying a comma or a bracket
    # would otherwise inject a second parameter into the grammar - `order_by`
    # arriving as `name,limit=99999` is not a hypothetical, it is what a query
    # string is for.
    my @args;
    if ( defined $q{order_by} && length $q{order_by} ) {
        return reply( 400, { ok => 0, error => 'order_by must be a field name' } )
            unless $q{order_by} =~ /\A[a-z][a-z0-9_]*\z/;
        my $dir = ( ( $q{order} // '' ) =~ /\Adesc\z/i ) ? '-' : '';
        push @args, "order=$dir$q{order_by}";
    }
    for my $n (qw(limit offset)) {
        next unless defined $q{$n} && length $q{$n};
        return reply( 400, { ok => 0, error => "$n must be a whole number" } )
            unless $q{$n} =~ /\A\d+\z/;
        push @args, "$n=$q{$n}";
    }
    my $binding = $table . ( @args ? '(' . join( ',', @args ) . ')' : '' );

    # SM606: say what was IGNORED, rather than refusing it or staying silent.
    #
    # This endpoint assembles its binding from order_by, order, limit and offset
    # and reads nothing else, so `?table=t&chunk=AAA` returned every row - in a
    # reply shaped EXACTLY like a filtered one. A bad VALUE is a 400; an unknown
    # PARAMETER was silence, and the caller could not tell the two apart. The
    # site agent had written it up as a hazard to work around, which is the
    # right instinct and the wrong resting place.
    #
    # REFUSING would have been the obvious fix and is the wrong one: any caller
    # passing a harmless extra - a cache-buster is the ordinary case - would
    # break, and that is a behaviour change deserving its own decision rather
    # than arriving inside a defect fix. Naming them costs nothing, breaks
    # nobody, and closes the silence, which was the whole complaint.
    my %READS   = map       { $_ => 1 } qw(table order_by order limit offset csrf);
    my @ignored = sort grep { !$READS{$_} } keys %q;

    # THE VISITOR (SM476), with no sysop bypass. This endpoint is the page's
    # data source, so it must answer exactly what the page's own binding would
    # - a sysop who saw more here than their site's visitors do would be
    # testing a different site.
    # A BAD BINDING IS A 400, NOT A 404. "no such table" for a limit that is
    # not a number would send a caller looking for a table that is right there.
    my $r = Lazysite::Data::Tables::resolve_binding(
        $docroot, $binding,
        { user => $user,
            groups => [ grep { length } @groups ],
        }
    );
    unless ( $r->{ok} ) {
        return reply( 400, { ok => 0, error => $r->{error} } )
            unless ( $r->{kind} // '' ) eq 'no_such_table';

        # A table nobody declared and a table this caller may not read answer
        # the SAME WAY, which is why the wording was chosen before the gate
        # existed: adding the gate changed no caller-visible string. Telling an
        # anonymous caller which tables a site has is most of what is worth
        # having from a store they cannot read.
        return reply( 404,
            { ok => 0, error => 'no such table, or not available to you' } );
    }

    return reply( 200,
        { ok => 1,
            table => $r->{table},
            rows  => $r->{rows},

            # SM511: the endpoint answers exactly what the page's binding
            # does - the true count beside the (possibly capped) rows, and
            # any clamp warning said rather than swallowed.
            ( defined $r->{total} ? ( total => 0 + $r->{total} ) : () ),

            # SM606: both, deliberately. `ignored` is the machine-readable
            # answer; the warning rides the EXISTING channel so a client that
            # already surfaces warnings shows this one without being changed -
            # and the caller who needs to see it most is the one who wrote
            # `chunk=` expecting it to filter and got every row back.
            ( @ignored ? ( ignored => \@ignored ) : () ),
            ( ( $r->{warnings} || @ignored )
                ? ( warnings => [
                        @{ $r->{warnings} || [] },
                        ( @ignored
                            ? ( 'ignored parameter'
                                    . ( @ignored == 1 ? '' : 's' ) . ': '
                                    . join( ', ', @ignored )
                                    . ' - this endpoint reads table, order_by, '
                                    . 'order, limit and offset' )
                            : () ),
                ] )
                : ()
            ),
            ( $r->{pending_schema} ? ( pending_schema => JSON::PP::true ) : () ),
        } );
}

1;

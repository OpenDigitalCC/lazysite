#!/usr/bin/perl

# DP-3: the data endpoint - a page's own JavaScript reading a table.
#
# WHY THIS EXISTS SEPARATELY FROM THE CONTROL API. The control API is the
# operator's and the agent's door: it is capability-gated, CSRF-gated on the
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

    require Lazysite::Manager::Plugins;
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;
    return reply( 403,
        { ok => 0,
            error => 'The data plugin is disabled. An operator can enable it '
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
        # documentation - and NOTHING HAS EVER ENFORCED IT. An operator writing
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
        require Lazysite::Data::Tables;
        my $desc = Lazysite::Data::Tables::load_table( $docroot, $table );
        my $wb
            = ( $desc->{ok} && ref $desc->{writable_by} eq 'ARRAY' )
            ? $desc->{writable_by}
            : [];
        if ( @{$wb} ) {
            my %in = map { $_ => 1 }
                split /\s*,\s*/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' );
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


    require Lazysite::Data::Tables;
    my %opt;
    $opt{order_by} = $q{order_by} if defined $q{order_by} && length $q{order_by};
    $opt{order}    = $q{order}    if defined $q{order}    && length $q{order};
    $opt{limit}    = $q{limit}    if defined $q{limit}    && length $q{limit};
    $opt{offset}   = $q{offset}   if defined $q{offset}   && length $q{offset};

    # THE VISITOR (SM476), with no operator bypass. This endpoint is the page's
    # data source, so it must answer exactly what the page's own binding would
    # - an operator who saw more here than their site's visitors do would be
    # testing a different site.
    my $r = Lazysite::Data::Tables::read_rows(
        $docroot, $table,
        as => {
            user   => $user,
            groups => [
                grep { length }
                    split /\s*,\s*/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' )
            ],
        },
        %opt
    );
    unless ( $r->{ok} ) {
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
            ( $r->{pending_schema} ? ( pending_schema => JSON::PP::true ) : () ),
        } );
}

1;

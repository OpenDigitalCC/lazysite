#!/usr/bin/perl

# DP-3: the data endpoint - a page's own JavaScript reading a table.
#
# WHY THIS EXISTS SEPARATELY FROM THE CONTROL API. The control API is the
# operator's and the agent's door: it is capability-gated, CSRF-gated on the
# cookie path, and every action is audited. A rendered PAGE asking for rows is
# a different question with a different answer - it is a visitor, usually
# anonymous, and what it may see is decided by the same rules that decide what
# the page itself may show.
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
# READ ONLY, DELIBERATELY, in this first cut. Writing from a page is DP-3's
# `writable=` half and needs a CSRF story of its own; shipping the read half
# first means a page can render data without a write surface existing at all.

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

    # GET only. A read endpoint that accepts POST invites a write to be added
    # to it later without the CSRF question being asked.
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    return reply( 405, { ok => 0, error => 'this endpoint reads; use GET' } )
        unless $method eq 'GET';

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

    my $table = $q{table} // '';
    return reply( 400, { ok => 0, error => 'table required' } )
        unless length $table;

    # THE IDENTITY, verified here rather than taken from a header.
    require Lazysite::Auth::Session;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$docroot/lazysite";
    my ($user) = Lazysite::Auth::Session::verify_session_cookie();
    $user = '' unless defined $user;

    # An account that has been disabled or whose session was revoked is
    # ANONYMOUS from here, not "the user it used to be". Checked because a
    # cookie outlives both.
    if ( length $user ) {
        $user = ''
            if Lazysite::Auth::Session::account_disabled($user)
            || Lazysite::Auth::Session::session_revoked();
    }

    # The ACL gate reads the requester from the environment, exactly as the
    # render path does - so a table inside a gated section answers the same way
    # a page in it would. Set from the VERIFIED identity, never from what
    # arrived: anything the client could have sent is cleared first.
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_/ } keys %ENV;
    if ( length $user ) {
        $ENV{HTTP_X_REMOTE_USER} = $user;
        my @groups = Lazysite::Auth::Session::load_user_groups($user);
        $ENV{HTTP_X_REMOTE_GROUPS} = join ',', @groups if @groups;
    }

    require Lazysite::Data::Tables;
    my %opt;
    $opt{order_by} = $q{order_by} if defined $q{order_by} && length $q{order_by};
    $opt{order}    = $q{order}    if defined $q{order}    && length $q{order};
    $opt{limit}    = $q{limit}    if defined $q{limit}    && length $q{limit};
    $opt{offset}   = $q{offset}   if defined $q{offset}   && length $q{offset};

    my $r = Lazysite::Data::Tables::read_rows( $docroot, $table, %opt );
    unless ( $r->{ok} ) {
        # A table nobody declared and a table this visitor may not see must
        # answer the SAME WAY. Distinguishing them tells an anonymous caller
        # which tables exist, which is the disclosure the gate exists to
        # prevent - and it is free to get wrong, because the honest error is
        # more helpful and nobody notices the leak.
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

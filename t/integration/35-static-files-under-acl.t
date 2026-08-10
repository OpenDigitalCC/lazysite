#!/usr/bin/perl
# SM223: a source-less static file is governed by the ACL on the public path.
#
# The reported case: a set of single-file browser applications, and the private
# material they produce, were about to be published as static HTML on the
# strength of a site-wide auth default. auth_default never covered a static file
# - no .md source means no front matter, no check_auth, no decision at all - so
# the operator would have had no way to detect the exposure from the
# configuration they had written.
#
# What this asserts, and the shape of the decision taken 2026-08-09:
#
#   * auth_default STILL does not reach static files. A file with no ACL entry is
#     served exactly as before. Protecting one is an explicit act, and direct
#     static serving remains a supported use.
#   * an ACL entry with a `read` list refuses an anonymous request (bounce to
#     login) and a wrong-user request (403), and serves the named user.
#   * folder scope works, because a folder is an entry in the SAME store rather
#     than a second mechanism in lazysite.conf.
#   * an entry carrying only an owner is NOT a read restriction - matching the
#     authoring channels, where it is not one either.
#   * a governed file is never stored by a shared cache.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/private");
make_path("$docroot/public");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nauth_default: required\n";
close $cf;

# A page source, so the site has something ordinary in it.
open my $ix, '>', "$docroot/index.md" or die $!;
print {$ix} "---\ntitle: Home\n---\nHome.\n";
close $ix;

# Source-less statics: exactly the files the web server hands over directly.
for my $f (
    [ "$docroot/private/brief.html", '<h1>private</h1>' ],
    [ "$docroot/private/notes.pdf",  'PDFDATA' ],
    [ "$docroot/public/open.html",   '<h1>open</h1>' ],
    )
{
    open my $fh, '>', $f->[0] or die $!;
    print {$fh} $f->[1];
    close $fh;
}

sub write_acls {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}

sub get {
    my ( $uri, %env ) = @_;
    return run_processor( $docroot, $uri, %env );
}

# Authenticated request. The processor REFUSES a client-supplied X-Remote-*
# header unless LAZYSITE_AUTH_TRUSTED is set, and lazysite-auth.pl sets it after
# validating the session cookie. That is precisely why SM223's vhost rules route
# a static file through the AUTH WRAPPER rather than straight at the processor:
# routing at the processor would arrive with no usable identity and every
# protected file would bounce to login for everyone, including the people
# entitled to read it.
sub get_as {
    my ( $uri, $user, $groups ) = @_;
    return get(
        $uri,
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => $user,
        ( defined $groups ? ( HTTP_X_REMOTE_GROUPS => $groups ) : () ),
    );
}

# --- with NO ACL store, auth_default does not reach a static file ------------
# This is the decision, and it is the opposite of what the filing originally
# recommended: a site declaring itself required has NOT thereby closed its
# assets. Anything else would start refusing assets on every live site that
# upgrades.
subtest 'no ACL store: a source-less static is served, auth_default or not' => sub {
    unlink "$docroot/lazysite/auth/acls.json";
    my $out = get('/private/brief');
    like( $out, qr/private/, 'the .html sibling is served' );
    unlike( $out, qr/Status: 40[13]/, 'not refused' );

    # A PDF in the PRIMARY docroot is 404 from the processor here, and that is
    # correct rather than a gap: without an ACL store the front end serves it
    # directly and the processor never sees it, so the processor has no reason
    # to duplicate the web server. It starts serving them only once a store
    # exists and the vhost begins routing them here - which is the whole
    # "sites that have not asked for this pay nothing" property.
    my $pdf = get('/private/notes.pdf');
    like( $pdf, qr/Status: 404/,
        'a docroot PDF is the front end\'s job while no ACL store exists' );
};

# --- an ACL entry protects it ------------------------------------------------
subtest 'an ACL read list refuses the anonymous public' => sub {
    write_acls( { 'private/brief.html' => { read => ['alice'] } } );

    my $out = get('/private/brief');
    like( $out, qr{Status: 302},      'anonymous bounces to login rather than 403' );
    like( $out, qr{Location: /login}, 'and is sent somewhere useful' );
    unlike( $out, qr/private<\/h1>/, 'the content is NOT served' );
    like( $out, qr/Cache-Control: no-store/,
        'and the refusal is not stored by a shared cache' );
};

subtest 'the named user is served, a different user is refused' => sub {
    write_acls( { 'private/brief.html' => { read => ['alice'] } } );

    my $ok = get_as( "/private/brief", "alice" );
    like( $ok, qr/private/, 'alice is served' );

    my $no = get_as( "/private/brief", "bob" );
    like( $no, qr/Status: 403/, 'bob gets 403 - logging in again will not help' );
    unlike( $no, qr/private<\/h1>/, 'and no content' );
};

subtest 'a @group entry is honoured' => sub {
    write_acls( { 'private/brief.html' => { read => ['@staff'] } } );

    my $ok = get_as( "/private/brief", "carol", "staff" );
    like( $ok, qr/private/, 'a member of the group is served' );

    my $no = get_as( "/private/brief", "dave", "other" );
    like( $no, qr/Status: 403/, 'a non-member is refused' );
};

# --- folder scope, in the same store -----------------------------------------
subtest 'a folder entry covers everything beneath it' => sub {
    write_acls( { 'private' => { read => ['alice'] } } );

    my $pdf = get('/private/notes.pdf');
    like( $pdf, qr/Status: 302/, 'a PDF under the folder is refused too' );
    unlike( $pdf, qr/PDFDATA/, 'and its bytes do not appear' );

    my $ok = get_as( "/private/notes.pdf", "alice" );
    like( $ok, qr/PDFDATA/, 'alice gets it' );

    # A folder rule must not reach outside itself.
    my $open = get('/public/open');
    like( $open, qr/open/, 'a file outside the folder is unaffected' );
};

subtest 'the longest matching folder wins' => sub {
    write_acls(
        { 'private' => { read => ['alice'] },
            'private/notes.pdf' => { read => ['bob'] },
        }
    );
    my $bob = get_as( "/private/notes.pdf", "bob" );
    like( $bob, qr/PDFDATA/, 'the exact entry beats the folder above it' );

    my $alice = get_as( "/private/notes.pdf", "alice" );
    like( $alice, qr/Status: 403/,
        'and the broader rule does not still admit alice' );
};

# --- an owner-only entry is not a read restriction ---------------------------
# Same as the authoring channels: Auth::Acl allows when the mode has no list.
# Stated as a test because it is the one place an operator could reasonably
# expect otherwise, and silence about it would be its own SM223.
subtest 'an entry with only an owner does not restrict reading' => sub {
    write_acls( { 'private/brief.html' => { owner => 'alice' } } );
    my $out = get('/private/brief');
    like( $out, qr/private/,
        'served - an owner is not a read list, here or in the manager' );
};

# --- a governed file is never shared-cached ----------------------------------
subtest 'a governed file that IS served still says no-store' => sub {
    write_acls( { 'private/brief.html' => { read => ['alice'] } } );
    my $out = get_as( "/private/brief", "alice" );
    like( $out, qr/private/, 'served to the permitted user' );
    like( $out, qr/Cache-Control:[^\n]*no-store/,
        'and marked no-store, because the response depended on who asked' );
};

# --- an unmentioned file is untouched by any of it ---------------------------
subtest 'a file with no entry is served even while others are protected' => sub {
    write_acls( { 'private' => { read => ['alice'] } } );
    my $out = get('/public/open');
    like( $out, qr/open/, 'no entry means served - protection is opt-in' );
    unlike( $out, qr/no-store/,
        'and it stays ordinary cacheable public content' );
};

# --- the .brief deny still holds once the engine is in the path --------------
# SM073's production deny is an Apache <FilesMatch>, which matches on the
# RESOLVED file - so once SM223's rewrite sends the request to the CGI instead,
# that deny no longer applies to it. The processor's own .brief guard is what
# covers the newly-routed case, and it existed before this change for the dev
# server. Asserted here because SM223 is what made it load-bearing in production.
subtest 'a .brief sidecar is still refused when routed through the engine' => sub {
    write_acls( { 'private' => { read => ['alice'] } } );
    open my $bf, '>', "$docroot/private/brief.md.brief" or die $!;
    print {$bf} 'authoring intent, never public';
    close $bf;

    my $out = get('/private/brief.md.brief');
    unlike( $out, qr/authoring intent/, 'the sidecar body is not served' );

    # Even to the user the ACL would otherwise admit: .brief is never content.
    my $ok = get_as( "/private/brief.md.brief", "alice" );
    unlike( $ok, qr/authoring intent/,
        'and not to a permitted user either - it is not content at all' );
};

# --- SM268 01-L2: the route SM223 actually uses carries an ENCODED path -------
#
# Apache does not set REDIRECT_* for a rewrite in server context, which is where
# the SM223 rules live - so on a site with an ACL store EVERY existing static
# arrives with REQUEST_URI only, percent-encoded, and the processor never
# decoded it. Turning on the first ACL entry therefore 404'd every asset whose
# filename contains a space, `+`, `&` or a non-ASCII character, site-wide. It
# reads as "SM223 broke my site" rather than as an encoding bug, which is why it
# is worth a test rather than a note.
subtest 'a static whose URL needs percent-encoding is served on the ACL route' => sub {
    write_acls( {} );
    open my $fh, '>', "$docroot/public/my file.pdf" or die $!;
    print {$fh} 'SPACEFILE';
    close $fh;

    # No REDIRECT_URL, encoded REQUEST_URI: the SM223 Apache route exactly.
    my $out = run_processor(
        $docroot, undef,
        REDIRECT_URL => undef,
        REQUEST_URI  => '/public/my%20file.pdf',
    );
    like( $out, qr/SPACEFILE/, 'the file is served' );
    unlike( $out, qr/404/, 'not a 404' );

    # And decoding did not open a traversal: the decode happens BEFORE the
    # `..` rejection, so an encoded one is still caught.
    my $trav = run_processor(
        $docroot, undef,
        REDIRECT_URL => undef,
        REQUEST_URI  => '/public/%2e%2e%2f%2e%2e%2flazysite/auth/acls.json',
    );
    unlike( $trav, qr/Status:\s*200/, 'an encoded traversal is still refused' );
};

done_testing();

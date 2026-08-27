#!/usr/bin/perl
# SM651: a site-wide ACL protected the login page against itself.
#
# `acl-set path=/` succeeds, warns only that a site-wide rule moves no files,
# and says nothing about what it has just done: an anonymous visitor is
# redirected to the login page, the login page is anonymous, and it is refused
# and redirected to itself. Measured four redirects deep and still 302. The
# chrome stylesheet went with it, so even a reachable login page would have
# rendered unstyled.
#
# WORSE THAN AN ORDINARY MISCONFIGURATION: signing in is the only way to get an
# interactive session to undo it, so a site protected this way from the manager
# UI takes its operator's own access with it. The reporting instance recovered
# only because the rule had been set over a partner token, which still reaches
# acl-remove - a route a browser user does not have.
#
# check_auth has carried this carve-out for auth_default since it was written.
# The ACL path never had it, and the same question asked by a different caller
# was getting a different answer.
#
# WHAT IS ASSERTED
#   under a rule at `/`, the login page is reachable and does NOT redirect
#   the chrome assets that style it are reachable
#   the auth CGI that processes the form is reachable
#   ordinary content under the same rule is STILL refused - the carve-out is a
#     hole for the way in, not a hole in the rule
#   a named user allowed by the rule still gets their content
#   the carve-out follows auth_redirect, not the literal string /login
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
make_path("$docroot/assets");

sub conf {
    my ($extra) = @_;
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $extra // '' );
    close $cf;
    return;
}
conf();

# An ordinary page, the login page, and the chrome the login page needs.
for my $p ( [ 'index', 'Home' ], [ 'login', 'Sign in' ], [ 'secret', 'Secret' ] ) {
    open my $fh, '>', "$docroot/$p->[0].md" or die $!;
    print {$fh} "---\ntitle: $p->[1]\n---\n$p->[1] body.\n";
    close $fh;
}
open my $css, '>', "$docroot/assets/lazysite-chrome.css" or die $!;
print {$css} "body{}\n";
close $css;

sub write_acls {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}
sub get { return run_processor( $docroot, $_[0], @_[ 1 .. $#_ ] ) }

# THE RULE THAT CAUSED IT: site-wide, readable only by one account.
write_acls( { '' => { owner => 'sjm', read => ['sjm'] } } );

# --- the way in stays open -------------------------------------------------
my $login = get('/login');
unlike( $login, qr/^Status: 302/m,
    'the login page is not redirected under a site-wide rule' )
    or diag('this is the loop: /login -> /login -> /login');
like( $login, qr/Sign in/, 'and it actually renders' );

my $chrome = get('/assets/lazysite-chrome.css');
unlike( $chrome, qr/^Status: 302/m,
    'the chrome stylesheet is reachable, so the login page is not unstyled' );

# --- the rule still bites on everything else -------------------------------
# The carve-out is a hole for the way IN, not a hole in the rule. If this
# passes while the assertions above pass, the fix is a fix; if it 200s, the
# site-wide rule has been quietly disabled.
my $secret = get('/secret');
like( $secret, qr/^Status: 302/m,
    'ordinary content under the same rule is still refused' );
my $home = get('/index');
like( $home, qr/^Status: 302/m, 'and so is the home page' );

# --- the named user still gets in ------------------------------------------
my $as_user = get( '/secret',
    LAZYSITE_AUTH_TRUSTED => '1', HTTP_X_REMOTE_USER => 'sjm' );
unlike( $as_user, qr/^Status: 302/m,
    'the account named in the rule still reads the content' );

# --- the carve-out follows auth_redirect -----------------------------------
# Hard-coding '/login' would leave a site that renamed its login page in
# exactly the loop this closes.
conf("auth_redirect: /signin\n");
open my $si, '>', "$docroot/signin.md" or die $!;
print {$si} "---\ntitle: Sign in here\n---\nSign in here.\n";
close $si;

my $renamed = get('/signin');
unlike( $renamed, qr/^Status: 302/m,
    'a renamed login page is carved out too - the rule follows auth_redirect' );

# And the default name is no longer special once it is not the login page.
my $old_name = get('/login');
like( $old_name, qr/^Status: 302/m,
    '/login is refused once it is no longer the site\'s login page - the '
        . 'carve-out is the configured way in, not the string' );

done_testing();

#!/usr/bin/perl
# SM973: a pooled worker answers from the ACL store as it is now.
#
# $ACL_MAP_CACHE holds acls.json "parsed at most once per request", but nothing
# cleared it between requests. In a FastCGI worker (SM142) the first request to
# read the store fixed the map until the worker restarted, so a file protected
# after that was still served to anonymous visitors. Each request here goes
# through handle_one_request(), as the accept loop runs it, in one process.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir repo_root);

my $root    = repo_root();
my $docroot = site_tempdir();
setup_test_site($docroot);
my $acls = "$docroot/lazysite/auth/acls.json";
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }
mkdir "$docroot/lazysite/auth";
put( $acls,                 '{}' );
put( "$docroot/secret.pdf", "%PDF-1.4 SECRET-4471\n" );

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)};
local $ENV{DOCUMENT_ROOT}  = $docroot;
local $ENV{REQUEST_METHOD} = 'GET';
local $ENV{QUERY_STRING}   = '';
local $ENV{REDIRECT_URL}   = '/__load__';

# Runs $code with STDOUT and STDERR captured; returns STDOUT.
sub capture {
    my ($code) = @_;
    my $out = "$docroot/out.$$";
    open my $so, '>&', \*STDOUT    or die;
    open my $se, '>&', \*STDERR    or die;
    open STDOUT, '>',  $out        or die;
    open STDERR, '>',  '/dev/null' or die;
    $code->();
    open STDOUT, '>&', $so  or die;
    open STDERR, '>&', $se  or die;
    open my $fh, '<',  $out or die;
    local $/;
    return scalar(<$fh>) // '';
}

capture( sub { do "$root/lazysite-processor.pl"; die $@ if $@ } );
sub request { local $ENV{REDIRECT_URL} = $_[0]; capture( sub { main::handle_one_request() } ) }

my $open = request('/secret.pdf');
like( $open, qr/SECRET-4471/, 'unlisted, the file is served' );

put( $acls, '{"secret.pdf":{"read":["alice"]}}' );
my $closed = request('/secret.pdf');
unlike( $closed, qr/SECRET-4471/, 'protected later, the same worker no longer serves it' )
    or diag( substr( $closed, 0, 300 ) );
like( $closed, qr/^Status: 30[23]/m, 'and sends the visitor to log in' );

put( $acls, 'not json' );
my $broken = request('/secret.pdf');
unlike( $broken, qr/SECRET-4471/, 'an unreadable store still fails closed' );

put( $acls, '{}' );
my $again = request('/secret.pdf');
like( $again, qr/SECRET-4471/, 'and a failed load is not kept once the store is readable' );

done_testing();

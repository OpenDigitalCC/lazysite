#!/usr/bin/perl
# SM1068: the processor decodes acls.json once per CHANGE, not once per reader.
#
# It decoded the store on every request ($ACL_MAP_CACHE lasts one request), and
# _acl_is_draft decoded it again on every call of its own - once per page on a
# registry rebuild. Measured on a 1,779-rule store: 0.35 to 0.5 s a request.
# The store is now read through a process-wide copy keyed on the file's
# identity (path, mtime, size, inode, ctime), as Lazysite::Auth::Acl::load_acls
# keys its own. Each request here goes through handle_one_request(), as the
# FastCGI accept loop runs it, in one process.
use strict;
use warnings;

# THE CLOCK IS INJECTED, not waited on. A copy is kept only once the file's ctime
# is more than a second old, and utime cannot age a ctime - so "later" is made
# by moving the processor's clock forward rather than by sleeping. Installed
# before the processor is compiled, which is when the override binds.
our $SKEW;
BEGIN { $SKEW = 0; *CORE::GLOBAL::time = sub () { CORE::time() + $main::SKEW }; }
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir repo_root);

my $root    = repo_root();
my $docroot = site_tempdir();
setup_test_site($docroot);
my $acls = "$docroot/lazysite/auth/acls.json";
sub put { my ( $p, $c ) = @_; $SKEW = 0; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
mkdir "$docroot/lazysite/auth";
mkdir "$docroot/sec";
put( "$docroot/sec/doc.pdf", "%PDF-1.4 SECRET-1068\n" );

# Aged past the one-second guard, so the copy is kept: the guard exists because
# two writes inside one second can leave every part of the key equal.
sub aged_put { my ( $p, $c ) = @_; put( $p, $c ); utime CORE::time() - 30, CORE::time() - 30, $p; $SKEW = 30; return }

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)};
local $ENV{DOCUMENT_ROOT}  = $docroot;
local $ENV{REQUEST_METHOD} = 'GET';
local $ENV{QUERY_STRING}   = '';
local $ENV{REDIRECT_URL}   = '/__load__';

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

aged_put( $acls, '{}' );
capture( sub { do "$root/lazysite-processor.pl"; die $@ if $@ } );
sub request { local $ENV{REDIRECT_URL} = $_[0]; capture( sub { main::handle_one_request() } ) }

# Count the decodes of the store, and only those: the processor decodes other
# JSON on a request too.
my $decodes = 0;
{
    no warnings 'redefine';
    my $orig = \&JSON::PP::decode_json;
    *JSON::PP::decode_json = sub {
        $decodes++ if defined $_[0] && index( $_[0], 'SM1068-STORE' ) >= 0;
        goto &$orig;
    };
}
my $W = '{"_n":"SM1068-STORE","/":{"owner":"root","write":["@admins"]}';

subtest 'an unchanged store is decoded once across requests' => sub {
    aged_put( $acls, "$W}" );
    $decodes = 0;
    my @r = map { request('/sec/doc.pdf') } 1 .. 3;
    like( $_, qr/SECRET-1068/, 'served under a write-only rule' ) for @r;
    is( $decodes, 1, 'three requests, one decode' );
};

subtest 'a change is seen on the next request' => sub {
    aged_put( $acls, qq($W,"sec":{"read":["alice"]}}) );
    $decodes = 0;
    my $r = request('/sec/doc.pdf');
    unlike( $r, qr/SECRET-1068/, 'the new read rule refuses it at once' );
    is( $decodes, 1, 'by decoding the changed store' );
    request('/sec/doc.pdf');
    is( $decodes, 1, 'and that copy is kept in turn' );

    aged_put( $acls, "$W}" );
    like( request('/sec/doc.pdf'), qr/SECRET-1068/, 'and lifting the rule serves it again' );
};

subtest 'a store rewritten within the second is never answered from the old copy' => sub {
    put( $acls, qq($W,"sec":{"read":["alice"]}}) );    # fresh mtime
    unlike( request('/sec/doc.pdf'), qr/SECRET-1068/, 'refused by the fresh rule' );
    put( $acls, "$W," . '"sec":{"read":["bobby"]}}' );   # same size, same second
    unlike( request('/sec/doc.pdf'), qr/SECRET-1068/, 'and the rewrite is read, not a kept copy' );
    put( $acls, "$W}" );
    like( request('/sec/doc.pdf'), qr/SECRET-1068/, 'nor kept when the rule is lifted' );
};

subtest 'an UNDECODABLE store is kept as a failure, closed - never as {}' => sub {
    aged_put( $acls, '{"_n":"SM1068-STORE",' );
    $decodes = 0;
    my @r = map { request('/sec/doc.pdf') } 1 .. 3;
    unlike( $_, qr/SECRET-1068/, 'refused' ) for @r;
    is( $decodes, 1, 'decoded once, and the failure kept' );
    aged_put( $acls, '{}' );
    like( request('/sec/doc.pdf'), qr/SECRET-1068/, 'and repairing the store is seen' );
};

SKIP: {
    skip 'running as root: chmod 000 does not refuse root', 1 if $> == 0;
    subtest 'a chmod that makes a KEPT store unreadable fails closed' => sub {
        aged_put( $acls, "$W}" );
        like( request('/sec/doc.pdf'), qr/SECRET-1068/, 'kept and served' );

        # In service a copy is kept only once the file is two seconds old, so a
        # later chmod always moves ctime past the kept key. The injected clock
        # skips that wait, so the real clock is let past the write's second.
        my $written = ( stat $acls )[10];
        select( undef, undef, undef, 0.1 ) while CORE::time() <= $written;
        chmod 0, $acls;    # mtime and size unchanged; ctime moves
        my $r = request('/sec/doc.pdf');
        chmod 0644, $acls;
        unlike( $r, qr/SECRET-1068/, 'refused, not answered from the kept copy' );
    };
}

done_testing();

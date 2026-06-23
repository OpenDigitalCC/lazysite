#!/usr/bin/perl
# SM074: per-file ACLs over WebDAV. Ownership + read/write allowlists live
# in the central store lazysite/auth/acls.json (not sidecars); the dav reads
# it to narrow access within a shared scope. The store itself is not
# writable over WebDAV - it lives in the denied lazysite/ tree.
use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav dav_users_tool);

my $s     = setup_dav_site();        # user 'deploy' = our "alice"
my $alice = $s->{auth};
dav_users_tool( $s->{docroot}, 'add', 'bob', 'pw' );
dav_users_tool( $s->{docroot}, 'set', 'bob', 'webdav', 'on' );
my $bob = 'Basic ' . encode_base64( 'bob:pw', '' );

sub set_acls {
    open my $f, '>', "$s->{docroot}/lazysite/auth/acls.json" or die $!;
    print $f $_[0];
    close $f;
}
sub put { run_dav( $s->{docroot}, 'PUT', $_[0], body => $_[1], HTTP_AUTHORIZATION => $_[2] ) }
sub get { run_dav( $s->{docroot}, 'GET', $_[0], HTTP_AUTHORIZATION => $_[1] ) }

# --- baseline: no ACL store, both writers share the scope ---------------
is( put( '/content/page.md', 'v1', $alice )->{code}, 201, 'alice creates page' );
my $b0 = put( '/content/page.md', 'b0', $bob );
ok( $b0->{code} == 204 || $b0->{code} == 201, 'no acl: bob may write (scope only)' );

# --- write-restrict the page to its owner -------------------------------
set_acls('{"content/page.md":{"owner":"deploy","write":["deploy"]}}');
is( put( '/content/page.md', 'b1', $bob )->{code},   403, 'write-acl: non-owner bob denied' );
is( put( '/content/page.md', 'v2', $alice )->{code}, 204, 'owner alice may still write' );
is( get( '/content/page.md', $bob )->{code},         200, 'no read list: bob may still read' );

# --- add a read list: hide the source from other authors ----------------
set_acls('{"content/page.md":{"owner":"deploy","read":["deploy"],"write":["deploy"]}}');
is( get( '/content/page.md', $bob )->{code},   403, 'read-acl: non-owner denied GET' );
is( get( '/content/page.md', $alice )->{code}, 200, 'owner may read the page' );

# --- granting bob write lets him in -------------------------------------
set_acls('{"content/page.md":{"owner":"deploy","write":["deploy","bob"]}}');
is( put( '/content/page.md', 'b3', $bob )->{code}, 204, 'write-acl: listed user bob may write' );

# --- a file with no ACL entry is unaffected -----------------------------
is( put( '/content/other.md', 'x', $bob )->{code}, 201, 'files with no acl entry are open' );

# --- the central store is NOT writable over WebDAV ----------------------
my $w = run_dav( $s->{docroot}, 'PUT', '/lazysite/auth/acls.json',
    body => '{}', HTTP_AUTHORIZATION => $bob );
is( $w->{code}, 403, 'the ACL store cannot be rewritten over WebDAV' );

done_testing();

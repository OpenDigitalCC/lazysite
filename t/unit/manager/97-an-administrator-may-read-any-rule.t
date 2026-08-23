#!/usr/bin/perl
# SM464: reading a rule is the audit half, split from the right to modify.
#
# The filing measured "Not the owner of this file" for every token caller,
# lazysite-admins member or not - because _is_operator refuses every token by
# design, and ownership was checked with no read-side override. The remedy is
# the filing's own sketch: manage_users may READ any rule; modifying stays
# owner-only for everyone. The token override keys on the token's OWN grant
# (what the operator explicitly wrote for that partner), never on group
# membership, so SM127's manager-groups-off-remote-channels stands.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Files qw(action_acl_set action_acl_get);
use Lazysite::Auth::Acl      ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/intranet");
open my $fh, '>', "$docroot/intranet/note.md" or die $!;
print {$fh} "x\n";
close $fh;
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
# A group that grants manager, so the site is NOT unsecured/dev (where every
# authenticated user is an operator and the read question never arises).
open my $gf, '>', "$docroot/lazysite/auth/groups" or die $!;
print {$gf} "admins: root-user\n";
close $gf;
open my $gs, '>', "$docroot/lazysite/auth/groups-settings.json" or die $!;
print {$gs} '{"admins":{"manage_users":true}}';
close $gs;

$Lazysite::Manager::Files::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT      = $docroot;

sub as_token {
    my (%caps) = @_;
    $Lazysite::Auth::Acl::token_auth = 1;
    %Lazysite::Auth::Acl::token_caps = %caps;
}

# The owner writes a rule, as themselves, over a cookie session.
$Lazysite::Auth::Acl::token_auth = 0;
%Lazysite::Auth::Acl::token_caps = ();
$Lazysite::Auth::Acl::auth_user  = 'alice';
my $set = action_acl_set( '/intranet/note.md', 'alice', 'alice', 'alice' );
ok( $set->{ok}, 'the owner sets a rule on their file' ) or diag explain $set;

subtest 'A TOKEN GRANT CARRYING manage_users MAY READ THE RULE' => sub {
    $Lazysite::Auth::Acl::auth_user = 'auditor';
    as_token( manage_users => 1, webdav => 1 );
    my $r = action_acl_get( '/intranet/note.md', 'auditor' );
    ok( $r->{ok}, 'the read is allowed' ) or diag explain $r;
    is( $r->{acl}{owner}, 'alice', 'and returns the rule, owner intact' );
};

subtest 'a token grant WITHOUT manage_users is still refused' => sub {
    $Lazysite::Auth::Acl::auth_user = 'partner';
    as_token( webdav => 1, manage_content => 1 );
    my $r = action_acl_get( '/intranet/note.md', 'partner' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/Not the owner/, 'with the ownership answer' );
};

subtest 'READING is the whole override: the auditor still cannot MODIFY' => sub {
    $Lazysite::Auth::Acl::auth_user = 'auditor';
    as_token( manage_users => 1, webdav => 1 );
    my $r = action_acl_set( '/intranet/note.md', 'auditor', 'auditor', 'auditor' );
    ok( !$r->{ok}, 'acl-set on somebody else\'s rule is refused, manage_users or not' )
        or diag( 'If this passed, the read split widened into write - the '
            . 'exact thing the filing said NOT to do.' );
};

subtest 'the site-root rule is readable the same way (SM310 parity)' => sub {
    $Lazysite::Auth::Acl::token_auth = 0;
    %Lazysite::Auth::Acl::token_caps = ();
    $Lazysite::Auth::Acl::auth_user  = 'alice';
    my $root_set = action_acl_set( '/', 'alice', 'alice', 'alice' );
    ok( $root_set->{ok}, 'owner sets a site-wide rule' ) or diag explain $root_set;
    $Lazysite::Auth::Acl::auth_user = 'auditor';
    as_token( manage_users => 1 );
    my $r = action_acl_get( '/', 'auditor' );
    ok( $r->{ok}, 'the auditor reads the root rule too' ) or diag explain $r;
    is( $r->{acl}{owner}, 'alice', 'both acl-get branches carry the override' );
};

done_testing();

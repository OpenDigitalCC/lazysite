#!/usr/bin/perl
# Regression tests for the 2026-06-23 security-review fixes:
#  F1 - a token (control-API) client is NEVER an operator, so per-file ACL
#       ownership applies to it even on an unsecured (no manager_groups) site.
#  F3 - the acl-* actions and action_read enforce the full deny-set: a blocked
#       path (e.g. forms/smtp.conf) is refused for both reads and ACL ops.
#  F4 - account-create / add cannot clobber an existing passwordless account.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth"); make_path("$d/content"); make_path("$d/lazysite/forms");
# Deliberately UNSECURED: no manager_groups - this is the case where the bug
# made every token client an "operator".
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!; print $cf "webdav_enabled: yes\n"; close $cf;
open my $sm, '>', "$d/lazysite/forms/smtp.conf" or die $!; print $sm "password: hunter2\n"; close $sm;
open my $af, '>', "$d/lazysite/auth/acls.json" or die $!;
print $af '{"content/x.md":{"owner":"alice","write":["alice"]}}'; close $af;

uapi( $d, { action => 'add', username => 'bob', password => 'x' } );
grant_caps( $d, 'bob', 'webdav' );
my $btok = uapi( $d, { action => 'token', username => 'bob' } )->{token};
ok( $btok && $btok =~ /^lzs_/, 'bob has a webdav token' );

# F1 - token client is not an operator even on an unsecured site.
my $set = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=acl-set&path=/content/x.md',
    HTTP_AUTHORIZATION => basic( 'bob', $btok ), body => encode_json( { write => ['bob'] } ) );
ok( !$set->{ok}, 'F1: token client cannot rewrite an ACL it does not own' );
my $get = mapi( $d, REQUEST_METHOD => 'GET',
    QUERY_STRING => 'action=acl-get&path=/content/x.md',
    HTTP_AUTHORIZATION => basic( 'bob', $btok ) );
ok( !$get->{ok}, 'F1: token client cannot read an ACL it does not own' );

# F3 - acl-set on a blocked path is refused before any owner logic.
my $bset = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=acl-set&path=/lazysite/forms/smtp.conf',
    HTTP_AUTHORIZATION => basic( 'bob', $btok ), body => encode_json( { write => ['bob'] } ) );
ok( !$bset->{ok} && ( $bset->{error} // '' ) =~ /block/i,
    'F3: acl-set on forms/smtp.conf is blocked' );

# F3 - a cookie operator's read of forms/smtp.conf is refused (no secret read).
my $rd = mapi( $d, REQUEST_METHOD => 'GET',
    QUERY_STRING => 'action=read&path=/lazysite/forms/smtp.conf',
    HTTP_X_REMOTE_USER => 'local' );
ok( !$rd->{ok} && ( $rd->{error} // '' ) =~ /block/i,
    'F3: manager read of forms/smtp.conf refused' );
unlike( encode_json($rd), qr/hunter2/, 'F3: the SMTP password is never returned' );

# F4 - cannot clobber an existing passwordless account.
uapi( $d, { action => 'add', username => 'tokenonly', password => '' } );
my $c1 = uapi( $d, { action => 'add', username => 'tokenonly', password => 'x' } );
ok( !$c1->{ok} && ( $c1->{error} // '' ) =~ /exist/i,
    'F4: add cannot clobber a passwordless account' );
my $c2 = uapi( $d, { action => 'account-create', username => 'tokenonly', password => 'x', created_by => 'bob' } );
ok( !$c2->{ok} && ( $c2->{error} // '' ) =~ /exist/i,
    'F4: account-create cannot clobber a passwordless account' );

done_testing();

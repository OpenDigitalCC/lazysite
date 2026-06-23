#!/usr/bin/perl
# A manager-group operator may manage ANY account (e.g. generate a setup
# link), not only ones it personally created - regression for "Not authorised
# to manage 'X'" when an operator clicked Generate setup link. A delegated
# sub-manager is still confined to its own managed_by sub-tree.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

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
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }
sub manage {
    my ( $d, $user, $groups, $body ) = @_;
    return mapi( $d,
        REQUEST_METHOD       => 'POST',
        HTTP_X_REMOTE_USER   => $user,
        HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN    => csrf($user),
        QUERY_STRING         => 'action=users',
        body                 => encode_json($body),
    );
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "manager_groups: managers\n"; close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf $secret; close $sf;

# CLI setup (unrestricted): boss owns sw; 'other' is an unrelated sub-manager.
uapi( $d, { action => 'add', username => 'boss', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'boss', key => 'create_sub_users', value => 'on' } );
uapi( $d, { action => 'account-create', username => 'sw', password => '', created_by => 'boss' } );
uapi( $d, { action => 'add', username => 'other', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'other', key => 'create_sub_users', value => 'on' } );

# Operator 'admin' (manager group) - did NOT create sw, but must manage it.
my $op = manage( $d, 'admin', 'managers', { action => 'claim-create', username => 'sw' } );
ok( $op->{ok}, 'operator may generate a setup link for an account it did not create' );
like( $op->{claim} // '', qr/^lzc_/, 'a claim token was minted' );

# Delegated sub-manager outside sw's tree is refused.
my $no = manage( $d, 'other', 'authors', { action => 'claim-create', username => 'sw' } );
ok( !$no->{ok}, 'a non-operator outside the sub-tree is refused' );
like( $no->{error} // '', qr/[Nn]ot authoris/, 'with the ancestry error' );

# sw's own sub-manager (boss, also not an operator) is still allowed.
my $bs = manage( $d, 'boss', 'authors', { action => 'claim-create', username => 'sw' } );
ok( $bs->{ok}, "sw's own sub-manager may still manage it" );

done_testing();

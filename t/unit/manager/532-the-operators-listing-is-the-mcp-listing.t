#!/usr/bin/perl
# n785 (T-113, the 0.16.8 edge results): the operator cookie's Files `list` of a
# folder under a rule naming address profile zz81-allow showed an entry
# `zz81-allow` beside the page; MCP `list_files` of the same folder did not.
#
# SM1404 had kept the permissions editor's profile choices on the manager API's
# listing alone (`pickers`), so the operator's door still answered with a list of
# `{ name }` beside `entries` - read as an entry named after the profile. Held
# here: the two doors give the same listing and no listing carries the choices;
# the Files page reads them with the other picker lists, from `principals`.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir grant_caps run_child);

my $root = repo_root();
my $d    = site_tempdir();
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'discard' )->{out};
    return eval { decode_json($out) } // {};
}

# The operator's door: the manager API as a signed-in manager reaches it.
sub op_get {
    my ($qs) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}        = $d;
    $ENV{REQUEST_METHOD}       = 'GET';
    $ENV{CONTENT_LENGTH}       = 0;
    $ENV{QUERY_STRING}         = $qs;
    $ENV{HTTP_X_REMOTE_USER}   = 'op';
    $ENV{HTTP_X_REMOTE_GROUPS} = 'managers';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    delete $ENV{LAZYSITE_API_LOAD_ONLY};    # set below, for the in-process load
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => '' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/zz81-addr" );
spit( "$d/lazysite/lazysite.conf", "manager_groups: managers\nsite_name: T\n" );
spit( "$d/lazysite/auth/.secret",  'sekret' x 6 );
uapi( { action => 'add', username => 'op', password => 'x-long-enough' } );
grant_caps( $d, 'op', 'manage_content' );
uapi( { action => 'group-add', username => 'op', group => 'managers' } );
spit( "$d/zz81-addr/page.md", "---\ntitle: P\n---\nhello\n" );
spit( "$d/lazysite/auth/address-profiles.json",
    encode_json( { 'zz81-allow' => { entries => [ { cidr => '192.0.2.0/24', note => 'office' } ] } } ) );
spit( "$d/lazysite/auth/acls.json", encode_json( { 'zz81-addr' => { owner => 'op', addresses => ['zz81-allow'] } } ) );

my $op = op_get('action=list&path=/zz81-addr');
ok( $op->{ok}, 'the operator\'s listing answers' ) or diag explain $op;
is_deeply( [ map { $_->{name} } @{ $op->{entries} || [] } ], ['page.md'], 'one entry, the page' );
unlike( encode_json($op), qr/zz81-allow/, 'nothing in it is named after the profile' );

# MCP list_files is Manager::Files::action_list, called as the tool calls it.
my $mcp = do {
    BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
    local $ENV{DOCUMENT_ROOT} = $d;
    {
        package main;
        do "$root/lazysite-manager-api.pl" or die "load failed: $@";
    }
    no warnings 'once';
    local $Lazysite::Manager::Common::auth_user = 'op';
    Lazysite::Manager::Files::action_list('/zz81-addr');
};
is_deeply( [ sort keys %$op ], [ sort keys %$mcp ], 'the two doors answer with the same fields' );
is_deeply( [ map { $_->{name} } @{ $op->{entries} } ], [ map { $_->{name} } @{ $mcp->{entries} } ],
    'and the same entries' );

my $pr = op_get('action=principals');
is_deeply( $pr->{address_profiles}, [ { name => 'zz81-allow' } ],
    'the profile choices come with the other picker lists' ) or diag explain $pr;

open my $fh, '<', "$root/starter/manager/files.md" or die $!;
my $page = do { local $/; <$fh> };
close $fh;
like( $page, qr/ADDRESS_PROFILES = d\.address_profiles/, 'the Files page reads them from principals' );
unlike( $page, qr/ADDRESS_PROFILES = data\.address_profiles/, 'and not from a listing' );

done_testing();

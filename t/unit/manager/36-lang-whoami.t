#!/usr/bin/perl
# SM179 P7: whoami exposes the language set to an agent. When the bound site is a
# language-set member, the response carries `language` = { lang, lang_group,
# siblings => [ { host, lang, content_root, source } ] } so the agent knows a
# translation counterpart exists and where its files live, without probing. A
# monolingual instance omits the block.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub whoami {
    my ( $d, $user, $groups ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'GET';
    $ENV{CONTENT_LENGTH}      = 0;
    $ENV{QUERY_STRING}        = 'action=whoami';
    $ENV{HTTP_X_REMOTE_USER}  = $user;
    $ENV{HTTP_X_REMOTE_GROUPS} = $groups;
    my ( $w, $r );
    my $e   = gensym;
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub setup {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf $secret;
    close $sf;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf $conf;
    close $cf;
    uapi( $d, { action => 'add', username => 'op', password => 'x' } );
    grant_caps( $d, 'op', 'manage_users', 'manage_domains' );
    return $d;
}

# --- a language set: whoami carries the language block -------------------------
my $set = setup( <<'CONF' );
site_name: T
lang: en
lang_group: providers
content_root: sites/en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.content_root: sites/de
CONF

my $r = whoami( $set, 'op', 'role-op' );
ok( $r->{ok}, 'whoami ok' ) or diag encode_json($r);
ok( $r->{language}, 'whoami carries a language block for a set' );
is( $r->{language}{lang_group}, 'providers', 'the group is reported' );
is( $r->{language}{lang},       'en', 'operator (unbound) sees the source language' );
is( scalar @{ $r->{language}{siblings} }, 2, 'both siblings listed' );
my %sib = map { $_->{lang} => $_ } @{ $r->{language}{siblings} };
ok( $sib{en}{source}, 'the en (base) sibling is flagged source' );
ok( !$sib{de}{source}, 'the de sibling is not the source' );
is( $sib{de}{content_root}, 'sites/de', 'a sibling reports its content root' );
is( $sib{de}{host},         'de.example', 'a sibling reports its host' );

# --- a monolingual instance: no language block --------------------------------
my $mono = setup("site_name: T\nlang: en\n");
my $r2   = whoami( $mono, 'op', 'role-op' );
ok( $r2->{ok}, 'whoami ok (mono)' );
ok( !$r2->{language}, 'a monolingual instance omits the language block' );

done_testing;

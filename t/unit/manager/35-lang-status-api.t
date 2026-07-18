#!/usr/bin/perl
# SM179 P6: the lang-status control-API action. Read-only, manage_domains-gated:
# it reports a language set's per-root translation coverage (current/stale/
# missing) so an operator or a translation agent sees what still needs doing.
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

sub mapi {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
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

sub get {
    my ( $d, $user, $groups, $qs ) = @_;
    return mapi( $d, REQUEST_METHOD => 'GET', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user, HTTP_X_REMOTE_GROUPS => $groups );
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/sites/en", "$d/sites/de" );
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf <<'CONF';
site_name: Agency
lang: en
lang_group: providers
content_root: sites/en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.content_root: sites/de
CONF
close $cf;

# en (source) has two pages; de has one (the other is missing).
for my $f (qw(index about)) {
    open my $fh, '>', "$d/sites/en/$f.md" or die $!;
    print $fh "---\ntitle: $f\n---\n\nen $f\n";
    close $fh;
}
open my $di, '>', "$d/sites/de/index.md" or die $!;
print $di "---\ntitle: index\n---\n\nde index\n";
close $di;

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users', 'manage_domains' );
uapi( $d, { action => 'add', username => 'ed', password => 'y' } );
grant_caps( $d, 'ed', 'manage_content' );

# --- operator reads the set coverage (group defaulted from lang_group) --------
{
    my $r = get( $d, 'op', 'role-op', 'action=lang-status' );
    ok( $r->{ok}, 'operator reads lang-status' ) or diag encode_json($r);
    is( $r->{members},        2,    'the set has two members' );
    is( $r->{group},          'providers', 'group defaulted from the conf' );
    is( $r->{source}{lang},   'en', 'source language is en' );
    is( scalar @{ $r->{roots} }, 1, 'one non-source root (de)' );
    my ($de) = @{ $r->{roots} };
    is( $de->{lang},    'de', 'the reported root is de' );
    is( $de->{current}, 1,    'de: index is current' );
    is( $de->{missing}, 1,    'de: about is missing' );
    is( $de->{total},   2,    'de: total matches the source page count' );
}

# --- a content editor CAN read the coverage report (manage_content-gated) -----
# lang-status is a read-only report a translation agent needs, so it is gated on
# manage_content (the cap a translating agent holds), not manage_domains.
{
    my $r = get( $d, 'ed', 'role-ed', 'action=lang-status' );
    ok( $r->{ok}, 'a content editor reads lang-status' ) or diag encode_json($r);
    is( $r->{members}, 2, 'the editor sees the set' );
}

# --- an account WITHOUT manage_content is forbidden ---------------------------
{
    uapi( $d, { action => 'add', username => 'nc', password => 'z' } );
    grant_caps( $d, 'nc', 'manage_themes' );
    my $r = get( $d, 'nc', 'role-nc', 'action=lang-status' );
    ok( !$r->{ok}, 'an account without manage_content cannot read lang-status' );
    is( $r->{kind}, 'forbidden', 'lang-status is forbidden without manage_content' );
}

done_testing;

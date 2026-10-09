#!/usr/bin/perl
# SM944 S24 (b)-(c), ruled 2026-10-09 ("Yes, (a)-(d)"): the preview verbs act
# for an account. Inside a request the dispatcher has authenticated a manager
# before either runs, so their answer there is unchanged (t/unit/manager/09,
# 84). Reached outside one - the request context as its reset leaves it,
# nobody - preview-grant minted a signed preview cookie for account '' and, on
# a site with no auth secret, created one, and preview shelled the processor
# for any path it was given (tmp/sm944-s24-refusal-probe.out). Now both refuse,
# and nothing is minted, created or run.
#
# The handlers still live in the manager API here, so it is loaded the way the
# unit tests load it (LAZYSITE_API_LOAD_ONLY: compiled, no request run), and
# the context is reset as any process that never sets one leaves it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir();
make_path( "$d/lazysite/layouts/plain", "$d/cgi" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/layouts/plain/layout.tt", "x\n" );
spit( "$d/lazysite/lazysite.conf",           "site_name: T\n" );
# A stand-in processor that leaves a mark when it is run.
spit( "$d/cgi/lazysite-processor.pl", "open my \$m, '>', '$d/ran' or die; close \$m;\n"
        . "print qq(Status: 200 OK\\r\\nContent-Type: text/html\\r\\n\\r\\nRENDERED);\n" );
local $ENV{LAZYSITE_PROCESSOR}           = "$d/cgi/lazysite-processor.pl";
local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
my $api = repo_root() . '/lazysite-manager-api.pl';
{
    local $ENV{DOCUMENT_ROOT} = $d;
    package main;
    do $api or die "load failed: $@";
}
Lazysite::Manager::Common::reset_request_context();

# What a call prints, as the CGI would send it.
sub printed {
    my ($code) = @_;
    my $buf = '';
    open my $save, '>&', \*STDOUT or die $!;
    close STDOUT;
    open STDOUT, '>', \$buf or die $!;
    $code->();
    close STDOUT;
    open STDOUT, '>&', $save or die $!;
    return $buf;
}

subtest 'preview-grant, outside a request, mints nothing' => sub {
    ok( !-e "$d/lazysite/auth/.secret", 'the site has no auth secret' );
    my $out = printed( sub { main::action_preview_grant( { layout => 'plain', theme => '' } ) } );
    like( $out, qr/^Status: 403 Forbidden/, 'refused, 403' );
    like( $out, qr/no account is asking/,   '...saying why' );
    unlike( $out, qr/Set-Cookie/, 'no cookie is minted' );
    ok( !-e "$d/lazysite/auth/.secret", 'and no auth secret is created' );

    # The same call for an account mints - so it is the empty account that is
    # refused, not the fixture.
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user = 'boss';
    $out = printed( sub { main::action_preview_grant( { layout => 'plain', theme => '' } ) } );
    like( $out, qr/Set-Cookie: lzs_preview=v1:\d+:plain::boss:/, 'for an account it mints, naming the account' );
    Lazysite::Manager::Common::reset_request_context();
    $out = printed( sub { main::action_preview_grant( { layout => 'plain', theme => '' } ) } );
    unlike( $out, qr/Set-Cookie/, 'reset: refused again' );
};

done_testing();

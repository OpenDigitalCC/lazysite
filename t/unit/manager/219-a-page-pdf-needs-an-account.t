#!/usr/bin/perl
# SM944 S29, the established fail-closed pattern (ruled 2026-10-10, "(a) load
# in main"): page-pdf renders a page for an account. Inside a request the
# dispatcher has refused an empty $auth_user and required `manage_content`
# before it runs, so its answer there is unchanged (t/unit/plugins/42 and
# t/integration/122, 123 drive it through requests). Reached outside one - the
# request context as its reset leaves it, nobody - action_page_pdf loaded the
# pandoc plugin and converted a public page (tmp/sm944-s29-s30-refusal-probe.out).
# Now it refuses before the plugin is loaded.
#
# The same call for an account renders and streams the page: md-to-pdf is a
# stand-in on PATH (no network). That half also holds the S29 move: the plugin
# declares no package and is found as main->can('convert'), so it must be loaded
# in package main wherever action_page_pdf lives.
#
# Loaded the way the unit tests load the script (LAZYSITE_API_LOAD_ONLY:
# compiled, no request run).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';

my $d = site_tempdir( plugins => 1 );
( my $t = $d ) =~ s{/site/public_html\z}{};
make_path( "$d/lazysite", "$d/docs", "$t/bin" );
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/docs/page.md",           "---\ntitle: Page\n---\n\nBody\n" );
spit( "$t/bin/md-to-pdf", "#!/bin/sh\necho ran >> '$t/ran'\nprintf '%%PDF-1.4 stand-in' > out.pdf\nexit 0\n" );
chmod 0755, "$t/bin/md-to-pdf";
local $ENV{PATH}                         = "$t/bin:$ENV{PATH}";
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

# The action, with STDOUT captured: (result, bytes printed).
sub pdf {
    my $out = "$t/stdout";
    open my $save, '>&', \*STDOUT or die;
    open STDOUT,   '>',  $out     or die;
    my $r = main::action_page_pdf('docs/page.md');
    open STDOUT, '>&', $save or die;
    return ( $r, slurp($out) );
}

subtest 'page-pdf, outside a request, loads nothing and converts nothing' => sub {
    is( do { no warnings 'once'; $Lazysite::Manager::Common::auth_user }, '', 'nobody is asking' );
    my ( $r, $printed ) = pdf();
    is( $r->{kind} // '', 'forbidden', 'refused' ) or diag explain $r;
    ok( !$r->{ok}, '...not ok' );
    like( $r->{error} // '', qr/no account is asking/, '...saying why' );
    is( $printed, '', '...nothing printed' );
    ok( !-e "$t/ran",          '...md-to-pdf did not run' );
    ok( !main->can('convert'), '...and the plugin was not loaded' );
};

subtest 'for an account the page is rendered, the converter found in package main' => sub {
    no warnings 'once';
    $Lazysite::Manager::Common::auth_user      = 'boss';
    @Lazysite::Manager::Common::REQUEST_SCOPES = ();       # an unbound cookie manager
    my ( $r, $printed ) = pdf();
    ok( $r->{ok} && $r->{streamed}, 'streamed' ) or diag explain $r;
    like( $printed, qr{^Content-Type: application/pdf\r$}m, '...a PDF' );
    like( $printed, qr/\r\n\r\n%PDF-1\.4 stand-in\z/, '...its bytes, and nothing after them' );
    ok( -e "$t/ran",          '...converted by md-to-pdf' );
    ok( main->can('convert'), 'the plugin was loaded into package main, where it is looked for' );

    Lazysite::Manager::Common::reset_request_context();
    unlink "$t/ran";
    ( $r, $printed ) = pdf();
    is( $r->{kind} // '', 'forbidden', 'reset: refused again' );
    is( $printed,         '',          '...printing nothing' );
};

done_testing();

#!/usr/bin/perl
# P8 (WORK-PLAN-0154): the development server routes a form post.
#
# A native form posts to /cgi-bin/form-handler.pl. tools/lazysite-server.pl
# routed only /cgi-bin/lazysite-*.pl, so the post fell through to the processor
# and answered 404 ("Could not send: Server returned 404", reported from a
# staged site shown on a LAN). Installed sites link plugins/form-handler.pl into
# cgi-bin (install.pl post_install_steps) and serve it as a plain CGI, not
# behind the auth wrapper (SM402) - so the dev server now does the same.
#
# The server is a modulino; cgi_target_for is its pure routing decision.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $server = "$root/tools/lazysite-server.pl";
require $server;

can_ok( 'main', 'cgi_target_for' ) or BAIL_OUT('no routing function');
my $proc = "$root/lazysite-processor.pl";

sub route { my @r = main::cgi_target_for( $_[0], "$root/tools", $proc ); return \@r }

subtest 'a form post reaches the form handler, as on an installed site' => sub {
    my ( $t, $rel, $direct ) = @{ route('/cgi-bin/form-handler.pl') };
    is( $t, "$root/plugins/form-handler.pl", 'the plugin is the target' );
    is( $rel, 'form-handler.pl', 'named as the installed link is' ); # bare-name-on-purpose: the cgi-bin name
    ok( $direct, 'and it runs directly, not behind the auth wrapper (SM402)' );
};

subtest 'the lazysite-* scripts route as before' => sub {
    my ( $t, $rel, $direct ) = @{ route('/cgi-bin/lazysite-manager-api.pl') };
    is( $t,   "$root/lazysite-manager-api.pl", 'the manager API' );
    is( $rel, 'lazysite-manager-api.pl',       'by name' );
    ok( !$direct, 'behind the auth wrapper, as before' );
};

subtest 'nothing else is reached by name' => sub {
    for my $u ( '/cgi-bin/payment-demo.pl', '/cgi-bin/form-smtp.pl', '/cgi-bin/../install.pl',
        '/cgi-bin/form-handler.pl.bak', '/page' )
    {
        my ( $t, $rel ) = @{ route($u) };
        is( $t, $proc, "$u: the processor" );
        ok( !defined $rel, "$u: no script named" );
    }
};

done_testing;

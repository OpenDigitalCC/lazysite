#!/usr/bin/perl
# SM944 S24 (b)-(c), ruled 2026-10-09 ("Yes, (a)-(d)"): the preview verbs act
# for an account, and refuse when no account is asking. Reached outside a
# request - the request context as its reset leaves it, nobody - preview-grant
# minted a signed preview cookie for account '' and, on a site with no auth
# secret, created one, and preview shelled the processor for any path it was
# given (tmp/sm944-s24-refusal-probe.out). That half is proved where every
# moved handler's is, in t/unit/manager/205, on Lazysite::Manager::Preview
# loaded in a plain process.
#
# This file holds the other half: inside a request the dispatcher has
# authenticated a manager before either verb runs, so the answer there is the
# one it always was. preview-grant is held to that by t/unit/manager/09;
# nothing else drove `preview` through a request, so this does. It passes on
# the manager API before (b) and (c) as after (tmp/sm944-s24-t213-on.sh).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use ManagerSession;

my $d = site_tempdir();
make_path("$d/cgi");
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
# A stand-in processor that leaves a mark when it is run.
spit( "$d/cgi/lazysite-processor.pl", "open my \$m, '>', '$d/ran' or die; close \$m;\n"
        . "print qq(Status: 200 OK\\r\\nContent-Type: text/html\\r\\n\\r\\nRENDERED);\n" );
local $ENV{LAZYSITE_PROCESSOR}           = "$d/cgi/lazysite-processor.pl";
local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';

subtest 'inside a request, preview answers as before' => sub {
    my $s = ManagerSession::new_site( root => repo_root() );
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', [qw(ui manage_content)], [qw(ui manage_content)] );
    my $r = $s->call( 'boss', 'preview', query => 'action=preview&path=/index.md' );
    ok( $r->{ok}, 'a manager\'s preview answers' ) or diag explain $r;
    is( $r->{html} // '', 'RENDERED', '...with the processor\'s render' );
    ok( -e "$d/ran", '...which it ran' );
};

done_testing();

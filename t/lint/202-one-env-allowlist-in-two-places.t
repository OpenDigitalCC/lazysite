#!/usr/bin/perl
# SM926: `site_url` holds `${REQUEST_SCHEME}://${SERVER_NAME}` on every site
# install.pl or TestHelper creates, and THREE pieces of the engine read that key.
# The processor expanded it against a reviewed allowlist; tools/lazysite-users.pl
# hand-rolled two of the same variables with a comment explaining why it had to;
# Lazysite::Notify returned the raw line - so the first XMPP notification to reach
# a live site carried the literal template text as its link.
#
# The allowlist now lives in Lazysite::Util and the processor keeps its OWN copy,
# because the render path is module-free (ADR 0001) and cannot require it. Two
# copies of a security decision drift, which is exactly what produced this defect,
# so this gate pins them identical - the arrangement lint 198 makes for
# `_cannot_read`.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::Util ();

my $root = repo_root();

# The processor's copy, read from its source rather than by running it - the
# render path is a CGI and this is a lint.
open my $fh, '<', "$root/lazysite-processor.pl" or BAIL_OUT("processor: $!");
my $src = do { local $/; <$fh> };
close $fh;

my ($block) = $src =~ /our \s+ %ENV_ALLOWLIST \s* = \s* map \s* \{[^}]*\} \s* qw\( ([^)]*) \)/xs;
ok( defined $block, 'the processor still carries its own %ENV_ALLOWLIST' )
    or BAIL_OUT('the processor copy could not be found - this lint is now blind');

my @processor = sort grep { length } split /\s+/, $block;
my @util      = Lazysite::Util::env_allowlist();

cmp_ok( scalar @util, '>=', 5, 'the shared allowlist is populated (' . scalar(@util) . ')' );
is_deeply( \@processor, \@util,
    'the processor copy and Lazysite::Util agree, variable for variable' )
    or diag( "  processor: @processor\n  util:      @util\n"
        . "  Two copies of ONE security decision. A variable added to one and not\n"
        . "  the other means a page and a notification disagree about what may be\n"
        . "  interpolated into a URL - which is the shape SM926 is about.\n" );

# HTTP_HOST is excluded from BOTH, and these two assertions are a RECORD OF THE
# PRESENT STATE rather than a guarantee - which is the opposite of what the
# processor's comment claims, so read this before changing either.
#
# The comment says HTTP_HOST is excluded because it is request-supplied and
# SERVER_NAME should be used instead. On a default Apache SERVER_NAME is ALSO
# request-supplied: `UseCanonicalName` defaults to Off, under which it is taken
# from the Host header, and none of the four shipped vhost examples
# (installers/apache/vhost*.conf.example) sets it On. And `_request_host()` in the
# processor reads HTTP_HOST directly to decide which alias host's config a request
# gets, on the main render path.
#
# RULED 2026-10-01 (SM926): THE PRESENTED HOST IS THE HOST. It is a division of
# responsibility, not a trust level - the engine uses the hostname it was given,
# restricting what may be presented is the front end's job, and a site that wants
# it fixed pins it (a literal site_url, which interpolation leaves alone). The
# consequence not yet built is ONE definition of the request host, shared by alias
# selection and interpolation, so the answer stops depending on a vhost setting
# nobody sets. `UseCanonicalName On` was declined: it would fix SERVER_NAME to the
# primary ServerName and put the primary host into an alias host's own links.
#
# So when that lands, these two assertions change WITH it, deliberately. They are
# not the boundary; SM110's whitelist of what a Host header may select is.
ok( !( grep { $_ eq 'HTTP_HOST' } @util ),
    'HTTP_HOST is not interpolable TODAY - see the ruling above' );
ok( ( grep { $_ eq 'SERVER_NAME' } @util ), 'SERVER_NAME is' );

# And Notify must not grow a fourth copy: it may read the allowlist, never define
# one. The defect was a private reader; a private allowlist would be the same
# mistake one level down.
open my $nf, '<', "$root/lib/Lazysite/Notify.pm" or BAIL_OUT("Notify: $!");
my $nsrc = do { local $/; <$nf> };
close $nf;
unlike( $nsrc, qr/%ENV_ALLOWLIST\s*=/,
    'Lazysite::Notify defines no allowlist of its own' );
like( $nsrc, qr/interpolate_env/,
    'and it DOES interpolate - the defect was that it did not' );

done_testing();

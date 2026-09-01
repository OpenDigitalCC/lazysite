#!/usr/bin/perl
# SM709: the auth_* stash variables are escaped where they enter the render, and
# the admin bar - which is string concatenation, not a template - is escaped at
# its sink.
#
# BOTH HALVES MATTER AND THE SECOND IS THE ONE THAT BITES. %AUTH_CONTEXT is also
# the input to access control: the ACL identity and its groups, _is_manager, the
# manager request gate, the editor flag. Escaping it AT THE AUTH BOUNDARY - the
# obvious place - would compare an escaped value against an unescaped users file.
# That fails CLOSED, so it presents as a lockout rather than a leak, and it is
# invisible to any test whose fixture user has no character needing escaping.
# That is SM702's shape exactly, which is why the fixture user here is called
# o'brien: the apostrophe is a character the escaper touches, so if the escaping
# ever leaks into the decision path this file fails rather than the fleet.
#
# The admin bar renders only for a manager. With no groups file, no group grants
# manager access and any authenticated user is one (the dev fallback in
# _is_manager). So THE BAR APPEARING AT ALL is the authorisation assertion, and
# the escaping of the name inside it is the sink assertion, in one render.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $conf "site_name: Test\nmanager: enabled\n";
close $conf;

# A page that interpolates the viewer WITHOUT a filter, which is what the
# shipped example in docs/auth.md does and what an author copying it will do.
open my $pg, '>', "$docroot/who.md" or die $!;
print $pg <<'MD';
---
title: Who
---
Signed in as [% auth_user %] / [% auth_name %] / [% auth_email %]
MD
close $pg;

my $NAME  = q{O'Brien</span><script>alert(1)</script>};
my $EMAIL = q{o'brien"@example.com};

my $out = run_processor(
    $docroot, '/who',
    LAZYSITE_AUTH_TRUSTED => 1,
    HTTP_X_REMOTE_USER    => q{o.brien},
    HTTP_X_REMOTE_NAME    => $NAME,
    HTTP_X_REMOTE_EMAIL   => $EMAIL,
    HTTP_X_REMOTE_GROUPS  => 'editors',
);

ok( length $out, 'page rendered' );

subtest 'the stash escapes what a page interpolates unfiltered' => sub {
    unlike( $out, qr/<script>alert\(1\)/, 'no raw script from the display name' );
    like( $out, qr/&lt;script&gt;alert\(1\)/, 'the display name rendered, escaped' );
    like( $out, qr/O&#39;Brien/,   q{the apostrophe is escaped, not dropped} );
    like( $out, qr/o&#39;brien/,   'the email is escaped too' );
    unlike( $out, qr/o'brien"\@example\.com/, 'no raw quote from the email' );
};

subtest 'the admin bar escapes at its sink, and still decided who may see it' => sub {
    # The bar is injected only for a manager. If the escaping had leaked into
    # %AUTH_CONTEXT, _is_manager would have run against escaped values and this
    # would be absent - the lockout, not the leak.
    like( $out, qr/lazysite-auth\.pl\?action=logout/,
        'the admin bar rendered, so authorisation resolved for this viewer' );
    unlike( $out, qr/<span style="margin-left:auto;">O'Brien<\/span>/,
        'the bar does not emit the name raw' );
    unlike( $out, qr{<span style="margin-left:auto;">[^<]*</span><script>},
        'no breakout out of the bar span' );
};

subtest 'the escaping is applied once, not twice' => sub {
    # The accepted cost of escaping at the stash is that a page ALSO writing
    # `| html` double-escapes. What must not happen is the engine doing it twice
    # on its own: &amp;#39; where &#39; was meant.
    unlike( $out, qr/&amp;#39;/, 'no double-escaped apostrophe from the engine' );
    unlike( $out, qr/&amp;lt;/,  'no double-escaped angle bracket' );
};

done_testing();
